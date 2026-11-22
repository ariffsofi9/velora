import {DurableObject} from 'cloudflare:workers';
import {createApplication} from '../backend/application.mjs';
import {createRealWorkerAccess, REAL_PROJECT_ID} from '../backend/backend-errors.mjs';
import {exactHttpsOrigin} from '../backend/http-policy.mjs';
import {createWorkloadAccessToken} from '../backend/workload-access-token.mjs';

const projects = new Map([['test', 'velora-spark-test'], ['real', REAL_PROJECT_ID]]);
const attemptWindowMs = 30000;
const clockSkewMs = 5000;
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
const unavailable = () => new Error('Shared admission unavailable.');
const unavailableResponse = () => Response.json({error: 'unavailable'}, {status: 503,
  headers: {'cache-control': 'no-store', 'x-content-type-options': 'nosniff'}});

function projectFor(env) {
  const project = projects.get(env?.VELORA_ENVIRONMENT);
  if (!project || env.VELORA_FIREBASE_PROJECT !== project) throw unavailable();
  return project;
}

function integer(value, fallback, max) {
  if (value === undefined) return fallback;
  if ((typeof value !== 'string' && typeof value !== 'number') || !/^[1-9]\d*$/.test(String(value)) ||
      !Number.isSafeInteger(Number(value)) || Number(value) > max) throw unavailable();
  return Number(value);
}

function namespaceFor(env) {
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

  constructor(ctx, env) {
    super(ctx, env);
    const projectId = projectFor(env);
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

  reserve(attempt, replayUntil) {
    const now = Date.now();
    if (!uuid(attempt) || !Number.isSafeInteger(replayUntil) || replayUntil <= now ||
        replayUntil > now + attemptWindowMs + clockSkewMs) throw unavailable();
    const token = crypto.randomUUID();
    return this.#storage.transactionSync(() => {
      this.#sql.exec("UPDATE permits SET state = 'closed' WHERE state = 'reserved' AND claim_until <= ?", now);
      this.#sql.exec("DELETE FROM permits WHERE state = 'closed' AND replay_until <= ?", now);
      if (this.#sql.exec('SELECT 1 FROM permits WHERE attempt = ?', attempt).toArray().length) throw unavailable();
      const occupancy = this.#sql.exec(`SELECT COUNT(*) AS project, COUNT(*) - COUNT(uid_key) AS pre_auth
        FROM permits WHERE state != 'closed'`).one();
      if (occupancy.project >= this.#projectLimit || occupancy.pre_auth >= this.#preAuthLimit ||
          this.#sql.exec('SELECT COUNT(*) AS total FROM permits').one().total >= this.#recordLimit) return null;
      this.#sql.exec("INSERT INTO permits VALUES (?, ?, 'reserved', ?, ?, NULL)",
        attempt, token, Math.min(replayUntil, now + this.#reservationMs), replayUntil);
      return token;
    });
  }

  claim(attempt, token) {
    if (!uuid(attempt) || !uuid(token)) throw unavailable();
    return this.#storage.transactionSync(() => this.#sql.exec(`UPDATE permits SET state = 'running'
      WHERE attempt = ? AND token = ? AND state = 'reserved' AND claim_until > ? RETURNING 1`,
    attempt, token, Date.now()).toArray().length === 1);
  }

  attribute(attempt, token, uidKey) {
    if (!uuid(attempt) || !uuid(token) || typeof uidKey !== 'string' || !/^[0-9a-f]{64}$/.test(uidKey)) {
      throw unavailable();
    }
    return this.#storage.transactionSync(() => {
      const matched = this.#sql.exec(`SELECT 1 FROM permits WHERE attempt = ? AND token = ?
        AND state = 'running' AND uid_key IS NULL`, attempt, token).toArray();
      if (!matched.length) throw unavailable();
      const {total} = this.#sql.exec(`SELECT COUNT(*) AS total FROM permits
        WHERE state != 'closed' AND uid_key = ?`, uidKey).one();
      if (total >= this.#uidLimit) return false;
      this.#sql.exec('UPDATE permits SET uid_key = ? WHERE attempt = ?', uidKey, attempt);
      return true;
    });
  }

  finish(attempt, token) {
    if (!uuid(attempt) || !uuid(token)) throw unavailable();
    // A matching holder calls this only after it has stopped or never started.
    // Running slots never expire, including after Worker or object restart.
    this.#storage.transactionSync(() => this.#sql.exec(`UPDATE permits SET state = 'closed', uid_key = NULL
      WHERE attempt = ? AND token = ? AND state != 'closed'`, attempt, token));
    return true;
  }
}

async function rpc(action, timeoutMs, signal) {
  if (signal?.aborted) throw unavailable();
  let timer, onAbort;
  try {
    return await Promise.race([new Promise((_, reject) => {
      onAbort = () => reject(unavailable());
      timer = setTimeout(onAbort, timeoutMs);
      signal?.addEventListener('abort', onAbort, {once: true});
    }), Promise.resolve().then(() => {
      if (signal?.aborted) throw unavailable();
      return action();
    })]);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
  }
}

export function createWorkerAdmission(env) {
  const projectId = projectFor(env);
  const namespace = namespaceFor(env);
  const objectId = namespace.idFromName(projectId);
  const timeoutMs = integer(env.ADMISSION_RPC_TIMEOUT_MS, 1000, 5000);
  return Object.freeze({projectId, async acquire(signal) {
    const attempt = crypto.randomUUID();
    const replayUntil = Date.now() + attemptWindowMs;
    const stub = namespace.get(objectId);
    const token = await rpc(() => stub.reserve(attempt, replayUntil), timeoutMs, signal);
    if (token === null) return null;
    if (!uuid(token)) throw unavailable();
    // Use a fresh stub for release: an ambiguous claim can invalidate its stub.
    const finish = () => rpc(() => namespace.get(objectId).finish(attempt, token), timeoutMs);
    try {
      if (await rpc(() => stub.claim(attempt, token), timeoutMs, signal) !== true || signal?.aborted) throw unavailable();
    } catch {
      // This invocation never dispatched work. Closing the exact token is safe
      // whether claim ran, is still pending, or never reached the coordinator.
      try { await finish(); } catch { /* No dispatch, and no unsafe slot reuse. */ }
      throw unavailable();
    }
    return Object.freeze({finish, async attribute(uid, requestSignal) {
      if (typeof uid !== 'string' || !uid.length || uid.length > 128 || requestSignal?.aborted) throw unavailable();
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${projectId}\0${uid}`));
      const uidKey = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
      return rpc(() => stub.attribute(attempt, token, uidKey), timeoutMs, requestSignal);
    }});
  }});
}

const denyDependency = async () => { throw unavailable(); };
export function createWorkerApplication(env, testDependencies) {
  const projectId = projectFor(env);
  const publicOrigin = env.VELORA_PUBLIC_ORIGIN;
  const admission = createWorkerAdmission(env);
  if (projectId === REAL_PROJECT_ID) {
    const source = env.VELORA_GOOGLE_TOKEN_SOURCE;
    if (testDependencies !== undefined || !exactHttpsOrigin(publicOrigin) || typeof source?.acquire !== 'function') {
      throw unavailable();
    }
    const {hostname, port} = new URL(publicOrigin);
    if (port || !/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/.test(hostname) ||
        hostname.endsWith('.invalid') || hostname.endsWith('.localhost')) throw unavailable();

    // This private binding is explicitly provisioned by the operator. Never
    // pass request data, discover ambient credentials or accept a static token.
    const acquire = Object.assign(async ({signal}) => {
      signal.throwIfAborted();
      const response = await source.acquire(projectId);
      signal.throwIfAborted();
      if (response?.projectId !== projectId) throw unavailable();
      return response;
    }, {projectId});
    const realWorker = createRealWorkerAccess({projectId, acquire, admission});
    return createApplication({projectId, realWorker, publicOrigin, allowedOrigins: [publicOrigin], admission,
      enableLocalFrontend: env.VELORA_ENABLE_LOCAL_FRONTEND === 'true',
      createRealAccessToken: createWorkloadAccessToken,
      // Workers support manual redirects. The Google adapter rejects every 3xx
      // and unexpected response URL without replaying the original request.
      transport: (url, init) => fetch(url, {...init, redirect: 'manual'})});
  }
  const {transport = denyDependency, accessToken} = testDependencies ?? {};
  return createApplication({projectId, publicOrigin, allowedOrigins: [publicOrigin], transport,
    accessToken: accessToken ?? Object.assign(() => denyDependency(), {projectId}),
    admission});
}

let application, bindingSnapshot;
export default {async fetch(request, env, ctx) {
  try {
    // Isolates can survive a bindings-only release. Do not retain the previous
    // origin, coordinator or credential binding after the new values arrive.
    const bindings = [env.VELORA_ENVIRONMENT, env.VELORA_FIREBASE_PROJECT, env.VELORA_PUBLIC_ORIGIN,
      env.VELORA_ENABLE_LOCAL_FRONTEND, env.ADMISSION, env.ADMISSION_RPC_TIMEOUT_MS,
      env.VELORA_GOOGLE_TOKEN_SOURCE];
    if (!bindingSnapshot || bindings.some((value, index) => value !== bindingSnapshot[index])) {
      application = createWorkerApplication(env);
      bindingSnapshot = bindings;
    }
    return await application.fetch(request, work => ctx.waitUntil(work));
  } catch { return unavailableResponse(); }
}};
