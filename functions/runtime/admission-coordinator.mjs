import {DurableObject, WorkerEntrypoint} from 'cloudflare:workers';
import {REAL_PROJECT_ID} from '../backend/backend-errors.mjs';
import {recordAdmission} from '../backend/admission-telemetry.mjs';
import {OAUTH_PROTOCOL_VERSION} from '../backend/pre-auth-settlement.mjs';
import {createOAuthLedger} from '../backend/durable-oauth.mjs';

const projects = new Map([['test', 'velora-spark-test'], ['real', REAL_PROJECT_ID]]);
export const attemptWindowMs = 30000;
const clockSkewMs = 5000;
const drainKey = 'admission-drain-v1';
export const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
export const unavailable = () => new Error('Shared admission unavailable.');
export const unavailableResponse = () => Response.json({error: 'unavailable'}, {status: 503,
  headers: {'cache-control': 'no-store', 'x-content-type-options': 'nosniff'}});

export function projectFor(env) {
  const project = projects.get(env?.VELORA_ENVIRONMENT);
  if (!project || env.VELORA_FIREBASE_PROJECT !== project) throw unavailable();
  return project;
}

export function integer(value, fallback, max) {
  if (value === undefined) return fallback;
  if ((typeof value !== 'string' && typeof value !== 'number') || !/^[1-9]\d*$/.test(String(value)) ||
      !Number.isSafeInteger(Number(value)) || Number(value) > max) throw unavailable();
  return Number(value);
}

export function namespaceFor(env) {
  const namespace = env?.ADMISSION;
  if (typeof namespace?.idFromName !== 'function' || typeof namespace?.get !== 'function') throw unavailable();
  return namespace;
}

export class AdmissionCoordinator extends DurableObject {
  #storage;
  #sql;
  #projectLimit;
  #preAuthLimit;
  #uidLimit;
  #reservationMs;
  #recordLimit;
  #real;
  #oauth;
  #oauthRegistrationEnabled;

  constructor(ctx, env) {
    super(ctx, env);
    const projectId = projectFor(env);
    this.#real = projectId === REAL_PROJECT_ID;
    this.#oauthRegistrationEnabled = this.#real && env.VELORA_DURABLE_OAUTH === 'true';
    if (ctx.id.toString() !== namespaceFor(env).idFromName(projectId).toString()) throw unavailable();
    this.#projectLimit = integer(env.ADMISSION_PROJECT_LIMIT, 8, 100);
    this.#preAuthLimit = integer(env.ADMISSION_PRE_AUTH_LIMIT, 2, 100);
    this.#uidLimit = integer(env.ADMISSION_UID_LIMIT, 2, 100);
    this.#reservationMs = integer(env.ADMISSION_RESERVATION_MS, 5000, attemptWindowMs);
    this.#recordLimit = integer(env.ADMISSION_RECORD_LIMIT, 512, 4096);
    if (Math.max(this.#preAuthLimit, this.#uidLimit) > this.#projectLimit || this.#recordLimit < this.#projectLimit) {
      throw unavailable();
    }
    this.#storage = ctx.storage;
    this.#sql = ctx.storage.sql;
    if (this.#real) this.#oauth = createOAuthLedger(this.#storage, () => this.#drainState());
    this.#storage.transactionSync(() => {
      this.#sql.exec(`CREATE TABLE IF NOT EXISTS permits (
        attempt TEXT PRIMARY KEY, token TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('reserved', 'running', 'closed')),
        claim_until INTEGER NOT NULL, replay_until INTEGER NOT NULL, uid_key TEXT
      )`);
      this.#sql.exec("CREATE INDEX IF NOT EXISTS permit_active ON permits(uid_key) WHERE state != 'closed'");
      this.#sql.exec("CREATE INDEX IF NOT EXISTS permit_expiry ON permits(replay_until) WHERE state = 'closed'");
    });
  }

  #recordRejection(stage, now) {
    if (!this.#real) return;
    recordAdmission(stage, () => this.#sql.exec(`SELECT
      COUNT(*) FILTER (WHERE state != 'closed') AS project,
      COUNT(*) FILTER (WHERE state != 'closed' AND uid_key IS NULL) AS preAuth,
      COUNT(*) FILTER (WHERE state = 'reserved') AS reserved,
      COUNT(*) FILTER (WHERE state = 'running') AS running,
      COUNT(*) FILTER (WHERE state = 'closed') AS closed,
      COUNT(*) FILTER (WHERE state = 'running' AND uid_key IS NULL) AS runningUnattributed,
      COUNT(*) FILTER (WHERE state = 'running' AND replay_until <= ?) AS runningPastReplay,
      COUNT(*) FILTER (WHERE state = 'running' AND replay_until <= ?) AS runningPastReplayOneMinute
      FROM permits`, now, now - 60000).one());
  }

  #drainState() {
    const state = this.#storage.kv.get(drainKey);
    if (state === undefined) return {generation: 0, draining: false};
    if (!Number.isSafeInteger(state?.generation) || state.generation < 1 ||
        typeof state.draining !== 'boolean') throw unavailable();
    return state;
  }

  // Private DO RPCs only. A drain controls future dispatch, not recovery or
  // holder settlement. Persist it in this SQLite object's existing KV storage.
  admissionDrainStatus() {
    if (!this.#real) throw unavailable();
    return this.#drainState();
  }

  updateAdmissionDrain(expectedGeneration, draining) {
    if (!this.#real || !Number.isSafeInteger(expectedGeneration) ||
        expectedGeneration < 0 || typeof draining !== 'boolean') throw unavailable();
    return this.#storage.transactionSync(() => {
      const current = this.#drainState();
      if (current.generation !== expectedGeneration) throw unavailable();
      if (current.draining === draining) return current;
      const generation = current.generation + 1;
      if (!Number.isSafeInteger(generation)) throw unavailable();
      const next = {generation, draining};
      this.#storage.kv.put(drainKey, next);
      return next;
    });
  }

  reserve(attempt, replayUntil) {
    const now = Date.now();
    if (!uuid(attempt) || !Number.isSafeInteger(replayUntil) || replayUntil <= now ||
        replayUntil > now + attemptWindowMs + clockSkewMs) throw unavailable();
    const token = crypto.randomUUID();
    let rejection;
    const result = this.#storage.transactionSync(() => {
      if (this.#real && this.#drainState().draining) throw unavailable();
      this.#sql.exec("UPDATE permits SET state = 'closed' WHERE state = 'reserved' AND claim_until <= ?", now);
      this.#sql.exec("DELETE FROM permits WHERE state = 'closed' AND replay_until <= ?", now);
      if (this.#sql.exec('SELECT 1 FROM permits WHERE attempt = ?', attempt).toArray().length) throw unavailable();
      const occupancy = this.#sql.exec(`SELECT COUNT(*) AS project, COUNT(*) - COUNT(uid_key) AS pre_auth
        FROM permits WHERE state != 'closed'`).one();
      if (occupancy.project >= this.#projectLimit) rejection = 'shared-project-limit';
      else if (occupancy.pre_auth >= this.#preAuthLimit) rejection = 'shared-pre-auth-limit';
      else if (this.#sql.exec('SELECT COUNT(*) AS total FROM permits').one().total >= this.#recordLimit) {
        rejection = 'shared-record-limit';
      }
      if (rejection) return null;
      this.#sql.exec("INSERT INTO permits VALUES (?, ?, 'reserved', ?, ?, NULL)",
        attempt, token, Math.min(replayUntil, now + this.#reservationMs), replayUntil);
      return token;
    });
    if (rejection) this.#recordRejection(rejection, now);
    return result;
  }

  claim(attempt, token) {
    if (!uuid(attempt) || !uuid(token)) throw unavailable();
    return this.#storage.transactionSync(() => {
      if (this.#real && this.#drainState().draining) return false;
      return this.#sql.exec(`UPDATE permits SET state = 'running'
      WHERE attempt = ? AND token = ? AND state = 'reserved' AND claim_until > ? RETURNING 1`,
      attempt, token, Date.now()).toArray().length === 1;
    });
  }

  attribute(attempt, token, uidKey) {
    if (!uuid(attempt) || !uuid(token) || typeof uidKey !== 'string' || !/^[0-9a-f]{64}$/.test(uidKey)) {
      throw unavailable();
    }
    const result = this.#storage.transactionSync(() => {
      const matched = this.#sql.exec(`SELECT 1 FROM permits WHERE attempt = ? AND token = ?
        AND state = 'running' AND uid_key IS NULL`, attempt, token).toArray();
      if (!matched.length) throw unavailable();
      if (this.#real && this.#drainState().draining) throw unavailable();
      const {total} = this.#sql.exec(`SELECT COUNT(*) AS total FROM permits
        WHERE state != 'closed' AND uid_key = ?`, uidKey).one();
      if (total >= this.#uidLimit) return false;
      this.#sql.exec('UPDATE permits SET uid_key = ? WHERE attempt = ?', uidKey, attempt);
      return true;
    });
    if (result === false) this.#recordRejection('per-uid-limit', Date.now());
    return result;
  }

  // Private Durable Object RPC. An occupancy match is only a planning signal.
  // Current storage cannot prove that a holder's pre-auth work has stopped.
  preparePreAuthRecovery(expectedCount) {
    if (!this.#real || !Number.isInteger(expectedCount) ||
        expectedCount < 1 || expectedCount > this.#preAuthLimit) throw unavailable();
    const {candidateCount} = this.#storage.transactionSync(() => this.#sql.exec(
      "SELECT COUNT(*) AS candidateCount FROM permits WHERE state = 'running' AND uid_key IS NULL",
    ).one());
    return {
      state: 'blocked',
      reason: candidateCount === expectedCount ? 'termination-proof-unavailable' : 'candidate-count-mismatch',
      candidateCount,
    };
  }

  registerOAuth(attempt, token) {
    if (!this.#oauthRegistrationEnabled) throw unavailable();
    return this.#oauth.permit.register(attempt, token);
  }

  statusOAuth(id, attempt, token) {
    if (!this.#oauth) throw unavailable();
    return this.#oauth.permit.status(id, attempt, token);
  }

  startOAuth(id) {
    if (!this.#oauth) throw unavailable();
    return this.#oauth.source.start(id);
  }

  acknowledgeOAuth(id, grant) {
    if (!this.#oauth) throw unavailable();
    return this.#oauth.source.acknowledge(id, grant);
  }

  finish(attempt, token, expectedTracked = false) {
    if (!uuid(attempt) || !uuid(token)) throw unavailable();
    // A matching holder calls this only after it has stopped or never started.
    // Running slots never expire, including after Worker or object restart.
    return this.#storage.transactionSync(() => {
      if (this.#oauth && !this.#oauth.mayFinish(attempt, token, expectedTracked)) return false;
      this.#sql.exec(`UPDATE permits SET state = 'closed', uid_key = NULL
        WHERE attempt = ? AND token = ? AND state != 'closed'`, attempt, token);
      return true;
    });
  }
}

export class OAuthAcknowledgement extends WorkerEntrypoint {
  #coordinator(version) {
    const projectId = projectFor(this.env);
    if (projectId !== REAL_PROJECT_ID || version !== OAUTH_PROTOCOL_VERSION) throw unavailable();
    const namespace = namespaceFor(this.env);
    return namespace.get(namespace.idFromName(projectId));
  }
  start(version, id) { return this.#coordinator(version).startOAuth(id); }
  acknowledge(version, id, grant) { return this.#coordinator(version).acknowledgeOAuth(id, grant); }
}

