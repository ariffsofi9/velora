import assert from 'node:assert/strict';
import {generateKeyPairSync, randomUUID} from 'node:crypto';
import {registerHooks} from 'node:module';
import {DatabaseSync} from 'node:sqlite';
import {afterEach, beforeEach, test} from 'node:test';
import {createAdmissionTelemetry} from '../backend/admission-telemetry.mjs';
import {createPreAuthSettlement} from '../backend/pre-auth-settlement.mjs';
import {createRealWorkerAccess, REAL_PROJECT_ID} from '../backend/backend-errors.mjs';
import {createHttpPolicy} from '../backend/http-policy.mjs';
import {createAuthenticatedJsonHttp} from '../https/authenticated-json-http.mjs';
import {createOAuthLedger, runSyntheticTokenSource} from './helpers/durable-oauth-prototype.mjs';
import {syntheticIdentity} from '../feasibility/shared-backend/integration/synthetic-identity.mjs';
import {CERTIFICATE_URL} from '../backend/google-http.mjs';

// Load the real coordinator against native in-memory SQLite without a Worker
// emulator or production bindings. Only the Cloudflare base class is stubbed.
const hook = registerHooks({
  resolve(specifier, context, next) {
    if (specifier === 'cloudflare:workers') {
      return {url: 'data:text/javascript,export class DurableObject {} export class WorkerEntrypoint {}',
        shortCircuit: true};
    }
    return next(specifier, context);
  },
});
const {AdmissionCoordinator, createWorkerAdmission, createWorkerApplication} =
  await import('../runtime/worker-entry.mjs');
const {GoogleTokenSource, acquireGoogleToken, default: tokenSourceDefault} =
  await import('../runtime/google-token-source.mjs');
hook.deregister();

const projectId = REAL_PROJECT_ID;
const originalLog = console.log;
const uidKey = 'a'.repeat(64);
let events;
beforeEach(() => {
  events = [];
  console.log = event => events.push(event);
});
afterEach(() => { console.log = originalLog; });

function fixture(t, limits = {}) {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  let coordinator;
  const io = {kvGets: 0, kvPuts: 0, sqlRowsRead: 0};
  const env = {
    VELORA_ENVIRONMENT: 'real', VELORA_FIREBASE_PROJECT: projectId,
    ADMISSION: {idFromName: name => name, get: () => coordinator},
    ...limits,
  };
  db.exec('CREATE TABLE fixture_kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  const context = {id: env.VELORA_FIREBASE_PROJECT, storage: {
    kv: {
      get(key) {
        io.kvGets++;
        const row = db.prepare('SELECT value FROM fixture_kv WHERE key = ?').get(key);
        return row && JSON.parse(row.value);
      },
      put(key, value) {
        io.kvPuts++;
        db.prepare('INSERT OR REPLACE INTO fixture_kv VALUES (?, ?)').run(key, JSON.stringify(value));
      },
    },
    transactionSync(action) {
      db.exec('BEGIN');
      try {
        const result = action();
        db.exec('COMMIT');
        return result;
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      }
    },
    sql: {exec(sql, ...args) {
      const rows = db.prepare(sql).all(...args);
      if (/^SELECT/i.test(sql)) io.sqlRowsRead += rows.length;
      return {one: () => rows[0], toArray: () => rows};
    }},
  }};
  const restart = () => (coordinator = new AdmissionCoordinator(context, env));
  restart();
  function reserve() {
    const attempt = randomUUID();
    return [attempt, coordinator.reserve(attempt, Date.now() + 30000)];
  }
  function running(key) {
    const pair = reserve();
    assert.equal(coordinator.claim(...pair), true);
    if (key) assert.equal(coordinator.attribute(...pair, key), true);
    return pair;
  }
  return {db, env, io, get coordinator() { return coordinator; }, reserve, running, restart,
    oauth: () => createOAuthLedger(context.storage, () => coordinator.admissionDrainStatus())};
}

function event(stage, counts = {}) {
  assert.deepEqual(events, [{event: 'admission', stage, ...counts}]);
}

test('Worker-local limit keeps its public 429 and skips shared admission', async () => {
  const blocked = Promise.withResolvers(), entered = Promise.withResolvers();
  const admission = {projectId, acquire: async () => {
    entered.resolve();
    await blocked.promise;
    return null;
  }};
  const realWorker = createRealWorkerAccess({
    projectId, admission, acquire: Object.assign(async () => {}, {projectId}),
  });
  const origin = 'https://offline.invalid', route = '/staff/list';
  const fetch = createHttpPolicy({projectId, realWorker, publicOrigin: origin,
    allowedOrigins: [origin], routes: [route], admission, maxConcurrent: 1,
    handler: () => assert.fail('A rejected request must not reach the handler')});
  const request = () => new Request(origin + route, {method: 'POST'});
  const first = fetch(request());
  await entered.promise;
  try {
    const response = await fetch(request());
    assert.equal(response.status, 429);
    assert.deepEqual(await response.json(), {error: 'resource-exhausted'});
    event('worker-local-limit', {active: 1, limit: 1});
  } finally { blocked.resolve(); await first; }
});

const empty = {project: 0, preAuth: 0, reserved: 0, running: 0, closed: 0,
  runningUnattributed: 0, runningPastReplay: 0, runningPastReplayOneMinute: 0};

test('shared project limit reports only aggregate counts', t => {
  const f = fixture(t, {ADMISSION_PROJECT_LIMIT: '2'});
  f.running(uidKey);
  f.running('b'.repeat(64));
  assert.equal(f.reserve()[1], null);
  event('shared-project-limit', {...empty, project: 2, running: 2});
});

test('shared pre-auth limit counts old running permits without expiring them', t => {
  const f = fixture(t);
  const pair = f.running();
  f.db.prepare('UPDATE permits SET replay_until = ? WHERE attempt = ?')
    .run(Date.now() - 65000, pair[0]);
  assert.ok(f.reserve()[1]);
  assert.equal(f.reserve()[1], null);
  event('shared-pre-auth-limit', {...empty, project: 2, preAuth: 2, reserved: 1,
    running: 1, runningUnattributed: 1, runningPastReplay: 1,
    runningPastReplayOneMinute: 1});
});

test('stored-record limit still counts closed replay protection records', t => {
  const f = fixture(t, {ADMISSION_PROJECT_LIMIT: '2', ADMISSION_RECORD_LIMIT: '2'});
  for (let i = 0; i < 2; i++) assert.equal(f.coordinator.finish(...f.running()), true);
  assert.equal(f.reserve()[1], null);
  event('shared-record-limit', {...empty, closed: 2});
});

test('per-UID limit does not log the UID key or its matching permit records', t => {
  const f = fixture(t, {ADMISSION_UID_LIMIT: '1'});
  f.running(uidKey);
  const pair = f.running();
  assert.equal(f.coordinator.attribute(...pair, uidKey), false);
  event('per-uid-limit', {...empty, project: 2, preAuth: 1, running: 2,
    runningUnattributed: 1});
});

test('release logs acknowledgement after retrying only the original pair', async t => {
  const f = fixture(t);
  const calls = [];
  const originalGet = f.env.ADMISSION.get;
  f.env.ADMISSION.get = () => {
    const coordinator = originalGet();
    return {reserve: (...args) => coordinator.reserve(...args),
      claim: (...args) => coordinator.claim(...args),
      finish(...args) {
        calls.push(args);
        const result = coordinator.finish(...args);
        if (calls.length === 1) throw Error('Synthetic acknowledgement loss');
        return result;
      }};
  };
  const permit = await createWorkerAdmission(f.env).acquire();
  assert.equal(await permit.finish(), true);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], calls[1]);
  event('release-acknowledged');
});

test('failed release remains a failure after both attempts even if telemetry throws', async t => {
  const f = fixture(t);
  const originalGet = f.env.ADMISSION.get;
  const failure = Error('Synthetic private failure');
  let calls = 0;
  f.env.ADMISSION.get = () => {
    const coordinator = originalGet();
    return {reserve: (...args) => coordinator.reserve(...args),
      claim: (...args) => coordinator.claim(...args),
      finish() { calls++; throw failure; }};
  };
  console.log = value => { events.push(value); throw Error('Synthetic logger failure'); };
  const permit = await createWorkerAdmission(f.env).acquire();
  await assert.rejects(permit.finish(), error => error === failure);
  assert.equal(calls, 2);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS total FROM permits WHERE state = 'running'").get().total, 1);
  event('release-unconfirmed');
});

test('telemetry bounds volume, strips unknown data and tolerates failed counters', () => {
  let now = 0;
  const log = createAdmissionTelemetry({now: () => now, log: value => events.push(value)});
  log('shared-project-limit', () => ({project: 8, token: 'private', uid: uidKey, running: 'private'}));
  log('shared-project-limit', () => assert.fail('Sampled-out event queried storage'));
  log('private-stage', () => assert.fail('Unexpected stage queried storage'));
  now += 60000;
  log('shared-project-limit', () => { throw Error('private storage detail'); });
  assert.deepEqual(events, [
    {event: 'admission', stage: 'shared-project-limit', project: 8},
    {event: 'admission', stage: 'shared-project-limit'},
  ]);
});

test('repeated preparation blocks matching candidates without evidence or state changes', t => {
  const f = fixture(t);
  f.running();
  f.running();
  const before = f.db.prepare('SELECT * FROM permits').all();
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.deepEqual(f.coordinator.preparePreAuthRecovery(2), {
      state: 'blocked', reason: 'termination-proof-unavailable', candidateCount: 2,
    });
  }
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), before);
  assert.deepEqual(events, []);
  assert.equal(f.reserve()[1], null);
});

test('attribution, reservation, or legitimate finish before preparation excludes that row', t => {
  const f = fixture(t);
  const attributed = f.running();
  assert.equal(f.coordinator.attribute(...attributed, uidKey), true);
  const closed = f.running();
  assert.equal(f.coordinator.finish(...closed), true);
  assert.ok(f.reserve()[1]);
  const before = f.db.prepare('SELECT * FROM permits').all();
  assert.deepEqual(f.coordinator.preparePreAuthRecovery(2), {
    state: 'blocked', reason: 'candidate-count-mismatch', candidateCount: 0,
  });
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), before);
  assert.equal(f.coordinator.finish(...closed), true);
  assert.throws(() => f.coordinator.attribute(...closed, uidKey), /admission unavailable/);
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), before);
});

test('preparation rejects invalid counts and caller-supplied proof objects', t => {
  const f = fixture(t);
  for (const input of [0, 3, 1.5, '2', {expectedCount: 2, terminated: true}]) {
    assert.throws(() => f.coordinator.preparePreAuthRecovery(input), /admission unavailable/);
  }
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), []);
  const testFixture = fixture(t, {
    VELORA_ENVIRONMENT: 'test', VELORA_FIREBASE_PROJECT: 'velora-spark-test',
  });
  assert.throws(() => testFixture.coordinator.preparePreAuthRecovery(1), /admission unavailable/);
});

test('REAL application has no HTTP route to recovery preparation', async t => {
  const f = fixture(t);
  const origin = 'https://offline.example';
  const application = createWorkerApplication({...f.env, VELORA_PUBLIC_ORIGIN: origin,
    VELORA_GOOGLE_TOKEN_SOURCE: {acquire: () => assert.fail('Unexpected live dependency')}});
  for (const route of ['/admission/prepare-pre-auth-recovery', '/admission/drain']) {
    const response = await application.fetch(new Request(origin + route, {
      method: 'POST', headers: {'content-type': 'application/json'}, body: '{"expectedCount":2}',
    }));
    assert.equal(response.status, 404);
  }
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), []);
});

test('normally completed dependency is settled only after dispatch is sealed', async () => {
  const holder = createPreAuthSettlement();
  assert.equal(await holder.dispatch(async () => 'verified', {observable: true}), 'verified');
  assert.equal(holder.status(), 'open');
  holder.seal();
  assert.equal(holder.status(), 'settled');
  assert.throws(() => holder.dispatch(() => assert.fail('Late dispatch ran')), /sealed/);
});

test('caller timeout and abort do not settle a pending underlying verifier', async () => {
  const holder = createPreAuthSettlement();
  const work = Promise.withResolvers(), deadline = Promise.withResolvers();
  const abort = new AbortController();
  const dependency = holder.dispatch(() => work.promise, {observable: true});
  const response = Promise.race([dependency, deadline.promise]);
  deadline.resolve('timed-out');
  assert.equal(await response, 'timed-out');
  abort.abort();
  holder.seal();
  assert.equal(abort.signal.aborted, true);
  assert.equal(holder.status(), 'pending');
  work.resolve('late result');
  await dependency;
  assert.equal(holder.status(), 'settled');
  assert.throws(() => holder.dispatch(() => assert.fail('Late result unsealed holder')), /sealed/);
});

test('settlement remains unproven for opaque work across nested cancellation', async () => {
  const holder = createPreAuthSettlement();
  await holder.dispatch(async () => 'caller-wrapper-complete');
  holder.seal();
  assert.equal(holder.status(), 'unproven');
});

test('sealing prevents a scheduled dependency from starting', async () => {
  const holder = createPreAuthSettlement();
  const work = holder.dispatch(() => assert.fail('Dependency started after seal'), {observable: true});
  holder.seal();
  await assert.rejects(work, /sealed/);
  assert.equal(holder.status(), 'settled');
});

test('each claimed pair owns independent local evidence across coordinator restart', async t => {
  const f = fixture(t);
  const admission = createWorkerAdmission(f.env);
  const first = await admission.acquire(), second = await admission.acquire();
  assert.notEqual(first.preAuth, second.preAuth);
  const a = Promise.withResolvers(), b = Promise.withResolvers(), started = Promise.withResolvers();
  first.preAuth.dispatch(() => { started.resolve(); return a.promise; }, {observable: true});
  first.preAuth.dispatch(() => b.promise, {observable: true});
  await started.promise;
  first.preAuth.seal();
  second.preAuth.seal();
  assert.equal(await second.preAuth.completion(), 'settled');
  f.restart();
  assert.equal(f.coordinator.preparePreAuthRecovery(2).reason, 'termination-proof-unavailable');
  a.resolve();
  await a.promise;
  assert.equal(first.preAuth.status(), 'pending');
  b.resolve();
  assert.equal(await first.preAuth.completion(), 'settled');
  assert.equal(f.coordinator.preparePreAuthRecovery(2).reason, 'termination-proof-unavailable');
  assert.equal(await first.finish(), true);
  assert.equal(f.coordinator.preparePreAuthRecovery(1).reason, 'termination-proof-unavailable');
});

test('durable drain blocks both new reserves and claims from prior reservations', t => {
  const f = fixture(t);
  const reserved = f.reserve();
  assert.deepEqual(f.coordinator.admissionDrainStatus(), {generation: 0, draining: false});
  assert.deepEqual(f.coordinator.updateAdmissionDrain(0, true), {generation: 1, draining: true});
  const before = f.db.prepare('SELECT * FROM permits').all();
  assert.throws(() => f.reserve(), /admission unavailable/);
  assert.equal(f.coordinator.claim(...reserved), false);
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), before);
  assert.throws(() => f.coordinator.updateAdmissionDrain(0, false), /admission unavailable/);
  assert.deepEqual(f.coordinator.updateAdmissionDrain(1, false), {generation: 2, draining: false});
  assert.ok(f.reserve()[1]);
  assert.deepEqual(events, []);
});

test('attribution before drain retains its permit; attribution after drain is fenced', t => {
  const f = fixture(t);
  const attributed = f.running(uidKey), waiting = f.running();
  f.coordinator.updateAdmissionDrain(0, true);
  const before = f.db.prepare('SELECT * FROM permits').all();
  assert.throws(() => f.coordinator.attribute(...waiting, uidKey), /admission unavailable/);
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), before);
  assert.equal(f.coordinator.finish(...attributed), true);
  assert.equal(f.coordinator.preparePreAuthRecovery(2).reason, 'candidate-count-mismatch');
  assert.equal(f.coordinator.preparePreAuthRecovery(1).reason, 'termination-proof-unavailable');
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM permits WHERE state = 'running'").get().n, 1);
});

test('coordinator restart restores the drain and leaves unsettled permits held', t => {
  const f = fixture(t);
  const unresolved = f.running();
  f.coordinator.updateAdmissionDrain(0, true);
  const before = f.db.prepare('SELECT * FROM permits').all();
  f.restart();
  assert.deepEqual(f.coordinator.admissionDrainStatus(), {generation: 1, draining: true});
  assert.throws(() => f.reserve(), /admission unavailable/);
  assert.throws(() => f.coordinator.attribute(...unresolved, uidKey), /admission unavailable/);
  assert.equal(f.coordinator.preparePreAuthRecovery(1).reason, 'termination-proof-unavailable');
  assert.deepEqual(f.db.prepare('SELECT * FROM permits').all(), before);
});

test('an active verifier keeps its permit and preparation never acts as a fence', async t => {
  const f = fixture(t);
  const pair = f.running();
  const verification = Promise.withResolvers();
  const entered = Promise.withResolvers();
  let dispatched = 0;
  const route = '/staff/list';
  const request = new Request('https://offline.invalid' + route, {method: 'POST',
    headers: {'content-type': 'application/json', authorization: 'Bearer synthetic'}, body: '{}'});
  const handler = createAuthenticatedJsonHttp({projectId, storeProjectId: projectId,
    verifyIdentity: () => { entered.resolve(); return verification.promise; },
    routes: new Map([[route, () => { dispatched++; return {members: []}; }]]),
    domainErrorTypes: [class FixtureError extends Error {}]});
  const response = handler({url: request.url, method: request.method, headers: request.headers,
    body: request.body, signal: request.signal, admission: {
      attribute: () => f.coordinator.attribute(...pair, uidKey),
      track: work => work,
    }});
  await entered.promise;
  assert.deepEqual(f.coordinator.preparePreAuthRecovery(1), {
    state: 'blocked', reason: 'termination-proof-unavailable', candidateCount: 1,
  });
  assert.equal(dispatched, 0);
  verification.resolve({uid: 'synthetic', token: {sub: 'synthetic', aud: projectId,
    iss: 'https://securetoken.google.com/' + projectId, email_verified: true}});
  assert.equal((await response).status, 200);
  assert.equal(dispatched, 1);
  assert.equal(f.coordinator.preparePreAuthRecovery(1).candidateCount, 0);
  assert.equal(f.coordinator.finish(...pair), true);
});

for (const fence of ['closed', 'draining']) {
test(`${fence} permits cannot attribute or reach protected HTTP dispatch`, async t => {
  const f = fixture(t);
  const pair = f.running();
  const preAuth = createPreAuthSettlement();
  const route = '/staff/list';
  const request = new Request('https://offline.invalid' + route, {method: 'POST',
    headers: {'content-type': 'application/json', authorization: 'Bearer synthetic'}, body: '{}'});
  const handler = createAuthenticatedJsonHttp({projectId, storeProjectId: projectId,
    verifyIdentity: () => preAuth.dispatch(async () => {
      if (fence === 'closed') assert.equal(f.coordinator.finish(...pair), true);
      else f.coordinator.updateAdmissionDrain(0, true);
      return {uid: 'synthetic', token: {sub: 'synthetic', aud: projectId,
        iss: 'https://securetoken.google.com/' + projectId, email_verified: true}};
    }, {observable: true}),
    routes: new Map([[route, () => assert.fail('Closed permit reached domain dispatch')]]),
    domainErrorTypes: [class FixtureError extends Error {}]});
  const response = await handler({url: request.url, method: request.method, headers: request.headers,
    body: request.body, signal: request.signal, admission: {
      preAuth,
      attribute: () => {
        assert.equal(preAuth.status(), 'settled');
        return f.coordinator.attribute(...pair, uidKey);
      },
      track: work => work,
    }});
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {error: 'unavailable'});
});
}

const oauthDenied = /OAuth operation unavailable/;
const syntheticTransport = {
  cached: () => undefined,
  sign: async () => 'synthetic-assertion',
  fetch: async () => ({read: async () => 'synthetic-access-token', cleanup: async () => {}}),
};

test('OAuth competing starts allow one execution and reject retries after a lost grant', async t => {
  const f = fixture(t), owner = f.running();
  const {permit, source} = f.oauth();
  const id = permit.register(...owner);
  assert.equal(permit.register(...owner), id);
  const results = await Promise.allSettled([source, f.oauth().source].map(caller =>
    Promise.resolve().then(() => { caller.start(id); throw new Error('lost grant'); })));
  assert.deepEqual(results.map(result => result.reason.message).sort(),
    ['OAuth operation unavailable.', 'lost grant']);
  let dispatches = 0;
  await assert.rejects(runSyntheticTokenSource(source, id, {
    ...syntheticTransport, sign: () => { dispatches++; },
  }), oauthDenied);
  assert.equal(dispatches, 0);
  assert.equal(permit.status(id, ...owner), 'started');
});

for (const startWins of [true, false]) {
  test(`OAuth start and seal serialize when ${startWins ? 'start' : 'seal'} wins`, async t => {
    const f = fixture(t), owner = f.running();
    const {permit, source} = f.oauth();
    const id = permit.register(...owner);
    const operations = [() => source.start(id), () => permit.seal(id, ...owner)];
    if (!startWins) operations.reverse();
    const results = await Promise.allSettled(operations.map(op => Promise.resolve().then(op)));
    assert.deepEqual(results.map(result => result.status), ['fulfilled', 'rejected']);
    assert.equal(permit.status(id, ...owner), startWins ? 'started' : 'sealed-before-start');
    if (!startWins) assert.equal(permit.seal(id, ...owner), 'sealed-before-start');
  });
}

test('OAuth lost completion reply survives restart and matching acknowledgements replay', async t => {
  const f = fixture(t), owner = f.running();
  const {permit, source} = f.oauth();
  const id = permit.register(...owner);
  let capturedGrant;
  await assert.rejects(runSyntheticTokenSource({...source, acknowledge(op, grant) {
    capturedGrant = grant;
    assert.equal(source.acknowledge(op, grant), 'settled');
    throw new Error('lost receipt');
  }}, id, syntheticTransport), /lost receipt/);
  f.restart();
  const restarted = f.oauth();
  assert.equal(restarted.permit.status(id, ...owner), 'settled');
  assert.equal(restarted.source.acknowledge(id, capturedGrant), 'settled');
  assert.throws(() => restarted.source.acknowledge(id, randomUUID()), oauthDenied);
  assert.throws(() => restarted.source.start(id), oauthDenied);
  const persisted = JSON.stringify(f.db.prepare('SELECT value FROM fixture_kv').all());
  for (const secret of [capturedGrant, owner[1], 'synthetic-access-token', 'synthetic-assertion']) {
    assert.equal(persisted.includes(secret), false);
  }
  assert.equal(f.coordinator.preparePreAuthRecovery(1).reason, 'termination-proof-unavailable');
});

test('OAuth late fetch, body, and cleanup remain pending through abort and coordinator restart', async t => {
  const f = fixture(t), owner = f.running();
  const {permit, source} = f.oauth();
  const id = permit.register(...owner);
  const fetch = Promise.withResolvers(), read = Promise.withResolvers(), cleanup = Promise.withResolvers();
  const entered = Promise.withResolvers(), reading = Promise.withResolvers(), cleaning = Promise.withResolvers();
  const abort = new AbortController();
  const work = runSyntheticTokenSource(source, id, {...syntheticTransport,
    fetch() { entered.resolve(); return fetch.promise; },
  }, abort.signal);
  const rejected = assert.rejects(work, {name: 'AbortError'});
  await entered.promise;
  abort.abort();
  f.restart();
  const restarted = f.oauth();
  assert.equal(restarted.permit.status(id, ...owner), 'started');
  assert.throws(() => restarted.source.start(id), oauthDenied);
  fetch.resolve({
    read() { reading.resolve(); return read.promise; },
    cleanup() { cleaning.resolve(); return cleanup.promise; },
  });
  await reading.promise;
  assert.equal(permit.status(id, ...owner), 'started');
  read.resolve('synthetic-access-token');
  await cleaning.promise;
  assert.equal(permit.status(id, ...owner), 'started');
  cleanup.resolve();
  await rejected;
  assert.equal(restarted.permit.status(id, ...owner), 'settled');
});

test('OAuth abort without a response boundary and failed cleanup leave settlement unresolved', async t => {
  const f = fixture(t), first = f.running(), second = f.running();
  const {permit, source} = f.oauth();
  for (const [owner, fetch] of [
    [first, async () => { throw new DOMException('aborted', 'AbortError'); }],
    [second, async () => ({read: async () => 'synthetic', cleanup: async () => { throw Error('cleanup failed'); }})],
  ]) {
    const id = permit.register(...owner);
    await assert.rejects(runSyntheticTokenSource(source, id, {...syntheticTransport, fetch}));
    assert.equal(permit.status(id, ...owner), 'started');
  }
});

test('OAuth cache hits give separate permit receipts and cannot expose status across permits', async t => {
  const f = fixture(t), first = f.running(), second = f.running();
  const {permit, source} = f.oauth();
  const a = permit.register(...first), b = permit.register(...second);
  assert.notEqual(a, b);
  const cache = {...syntheticTransport, cached: () => 'synthetic-access-token',
    sign: () => assert.fail('Cache hit signed an assertion')};
  await runSyntheticTokenSource(source, a, cache);
  assert.equal(permit.status(a, ...first), 'settled');
  assert.equal(permit.status(b, ...second), 'registered');
  assert.throws(() => permit.status(a, ...second), oauthDenied);
  assert.throws(() => permit.status(a, first[0], second[1]), oauthDenied);
  await runSyntheticTokenSource(source, b, cache);
  assert.equal(permit.status(b, ...second), 'settled');
});

test('OAuth missing, malformed, and wrong-version records fail closed', t => {
  const f = fixture(t), owner = f.running();
  const {permit, source} = f.oauth();
  const missing = randomUUID();
  assert.throws(() => source.start(missing), oauthDenied);
  assert.throws(() => permit.status(missing, ...owner), oauthDenied);
  assert.throws(() => permit.seal(missing, ...owner), oauthDenied);
  const id = permit.register(...owner);
  const rowKey = 'oauth-operation:v1:' + id;
  const write = f.db.prepare('UPDATE fixture_kv SET value = ? WHERE key = ?');
  const original = JSON.parse(f.db.prepare('SELECT value FROM fixture_kv WHERE key = ?').get(rowKey).value);
  for (const malformed of ['{', JSON.stringify({...original, version: 2}),
    JSON.stringify({...original, state: 'settled'})]) {
    write.run(malformed, rowKey);
    assert.throws(() => source.start(id), oauthDenied);
    assert.throws(() => permit.status(id, ...owner), oauthDenied);
    assert.throws(() => source.acknowledge(id, randomUUID()), oauthDenied);
    assert.throws(() => permit.register(...owner), oauthDenied);
  }
});

for (const startWins of [true, false]) {
  test(`OAuth drain race when ${startWins ? 'start' : 'drain'} wins`, async t => {
    const f = fixture(t), owner = f.running();
    const {permit, source} = f.oauth();
    const id = permit.register(...owner);
    const operations = [() => source.start(id), () => f.coordinator.updateAdmissionDrain(0, true)];
    if (!startWins) operations.reverse();
    const [first, second] = await Promise.allSettled(operations.map(op => Promise.resolve().then(op)));
    assert.equal(first.status, 'fulfilled');
    assert.equal(second.status, startWins ? 'fulfilled' : 'rejected');
    assert.equal(permit.status(id, ...owner), startWins ? 'started' : 'registered');
    assert.throws(() => f.coordinator.attribute(...owner, uidKey), /admission unavailable/);
    if (startWins) assert.equal(source.acknowledge(id, first.value), 'settled');
    else assert.equal(permit.seal(id, ...owner), 'sealed-before-start');
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM permits WHERE state = 'running'").get().n, 1);
  });
}

test('OAuth protocol exposes only narrow fixture methods and no public route', async t => {
  const f = fixture(t), owner = f.running();
  const {permit, source} = f.oauth();
  const id = permit.register(...owner);
  assert.deepEqual(Object.keys(source), ['start', 'acknowledge']);
  assert.deepEqual(Object.keys(permit), ['register', 'status', 'seal']);
  const origin = 'https://offline.example.com';
  const app = createWorkerApplication({...f.env, VELORA_PUBLIC_ORIGIN: origin,
    VELORA_GOOGLE_TOKEN_SOURCE: {acquire: () => assert.fail('Public route reached the Token Source')}});
  for (const route of ['start', 'acknowledge', 'status', 'seal']) {
    const response = await app.fetch(new Request(origin + '/oauth/' + route, {method: 'POST'}));
    assert.equal(response.status, 404);
    assert.deepEqual(await response.json(), {error: 'not-found'});
  }
  assert.equal(permit.status(id, ...owner), 'registered');
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM permits WHERE state = 'running'").get().n, 1);
});

test('actual coordinator disables registration by default and retains legacy finish', async t => {
  const f = fixture(t);
  const pair = f.running();
  assert.throws(() => f.coordinator.registerOAuth(...pair), /admission unavailable/);
  const permit = await createWorkerAdmission(f.env).acquire();
  assert.equal(permit.acquireOAuth, undefined);
  assert.equal(await permit.finish(), true);
  assert.equal(f.coordinator.finish(...pair), true);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM fixture_kv WHERE key LIKE 'oauth-operation%'").get().n, 0);
});

test('tracked permit rejects an old or incompatible Token Source without legacy fallback', async t => {
  let legacy = 0;
  const source = {acquire() { legacy++; }};
  const f = fixture(t, {VELORA_DURABLE_OAUTH: 'true', VELORA_GOOGLE_TOKEN_SOURCE: source});
  const admission = createWorkerAdmission(f.env);
  for (const version of [undefined, 2]) {
    source.trackedOAuthVersion = version === undefined ? undefined : async () => version;
    const holder = await admission.acquire();
    await assert.rejects(holder.acquireOAuth(new AbortController().signal));
    assert.equal(await holder.finish(), true);
  }
  assert.equal(legacy, 0);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM fixture_kv WHERE key LIKE 'oauth-operation%'").get().n, 0);
});

test('actual tracked holder retains permit after cancellation and lost grant before late acknowledgement', async t => {
  const f = fixture(t, {VELORA_DURABLE_OAUTH: 'true'});
  const started = Promise.withResolvers(), reply = Promise.withResolvers();
  f.env.VELORA_GOOGLE_TOKEN_SOURCE = {
    trackedOAuthVersion: async () => 1,
    acquire: () => assert.fail('Legacy acquisition was called'),
    acquireTracked(project, version, id) {
      assert.equal(project, projectId);
      assert.equal(version, 1);
      started.resolve({id, grant: f.coordinator.startOAuth(id)});
      return reply.promise;
    },
  };
  const holder = await createWorkerAdmission(f.env).acquire();
  const abort = new AbortController();
  const failed = assert.rejects(holder.acquireOAuth(abort.signal));
  const {id, grant} = await started.promise;
  abort.abort();
  reply.reject(Error('lost reply'));
  await failed;
  assert.equal(await holder.finish(), false);
  f.env.VELORA_DURABLE_OAUTH = 'false';
  f.restart();
  assert.equal(await holder.finish(), false);
  assert.equal(f.coordinator.acknowledgeOAuth(id, grant), 'settled');
  assert.equal(await holder.finish(), true);
});

test('actual coordinator fails closed on corrupt or missing tracked records', t => {
  const f = fixture(t, {VELORA_DURABLE_OAUTH: 'true'}), pair = f.running();
  const id = f.coordinator.registerOAuth(...pair);
  const key = 'oauth-operation:v1:' + id;
  f.db.prepare('UPDATE fixture_kv SET value = ? WHERE key = ?').run('{', key);
  assert.throws(() => f.coordinator.finish(...pair), oauthDenied);
  f.db.prepare('DELETE FROM fixture_kv WHERE key = ?').run(key);
  assert.throws(() => f.coordinator.finish(...pair), oauthDenied);
  f.db.prepare('DELETE FROM fixture_kv WHERE key = ?').run('oauth-operation-owner:v1:' + pair[0]);
  assert.equal(f.coordinator.finish(...pair, true), false);
  assert.equal(f.db.prepare('SELECT state FROM permits WHERE attempt = ?').get(pair[0]).state, 'running');
});

test('REAL HTTP verification uses tracked acquisition only when explicitly enabled', async t => {
  const identity = syntheticIdentity(Date.now);
  const origin = 'https://offline.example.com';
  const auth = identity.token('owner', {aud: projectId, iss: 'https://securetoken.google.com/' + projectId});
  let lookups = 0;
  t.mock.method(globalThis, 'fetch', async url => {
    if (url === CERTIFICATE_URL) {
      return Response.json({synthetic: identity.certificate}, {headers: {'cache-control': 'max-age=300'}});
    }
    if (url === 'https://identitytoolkit.googleapis.com/v1/projects/' + projectId + '/accounts:lookup') {
      lookups++;
      return Response.json({users: [{localId: 'owner', emailVerified: true, disabled: false,
        email: 'owner@example.test', validSince: '1'}]});
    }
    // No Firestore fixture or mutation is needed to exercise the admission boundary.
    throw Error('Offline fixture stops at Firestore');
  });
  for (const enabled of [false, true]) {
    const f = fixture(t, {VELORA_PUBLIC_ORIGIN: origin, ...(enabled ? {VELORA_DURABLE_OAUTH: 'true'} : {})});
    let legacy = 0, tracked = 0;
    const token = {projectId, access_token: 'synthetic-access-token', token_type: 'Bearer', expires_in: 300};
    f.env.VELORA_GOOGLE_TOKEN_SOURCE = {
      acquire() { legacy++; return token; },
      trackedOAuthVersion: () => 1,
      acquireTracked(project, version, id) {
        assert.equal(project, projectId);
        assert.equal(version, 1);
        tracked++;
        const grant = f.coordinator.startOAuth(id);
        f.coordinator.acknowledgeOAuth(id, grant);
        return token;
      },
    };
    const app = createWorkerApplication(f.env);
    const result = await app.fetch(new Request(origin + '/staff/list', {method: 'POST',
      body: JSON.stringify({expectedCafeId: 'synthetic-cafe', expectedMembershipGeneration: 0}),
      headers: {'content-type': 'application/json', authorization: 'Bearer ' + auth}}));
    assert.equal(result.status, 503);
    assert.deepEqual([legacy, tracked], enabled ? [0, 1] : [1, 0]);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM permits WHERE state = 'closed'").get().n, 1);
  }
  assert.ok(lookups >= 2);
});

test('OAuth cancellation during signing waits for the signer and fences fetch', async t => {
  const f = fixture(t), owner = f.running();
  const {permit, source} = f.oauth();
  const id = permit.register(...owner);
  const signing = Promise.withResolvers(), entered = Promise.withResolvers();
  const abort = new AbortController();
  const work = runSyntheticTokenSource(source, id, {...syntheticTransport,
    sign() { entered.resolve(); return signing.promise; },
    fetch() { assert.fail('Cancelled signer dispatched OAuth'); },
  }, abort.signal);
  const rejected = assert.rejects(work, {name: 'AbortError'});
  await entered.promise;
  abort.abort();
  assert.equal(permit.status(id, ...owner), 'started');
  signing.resolve('synthetic-assertion');
  await rejected;
  assert.equal(permit.status(id, ...owner), 'settled');
});

const qualificationKey = generateKeyPairSync('rsa', {modulusLength: 2048}).privateKey
  .export({type: 'pkcs8', format: 'pem'});
const oauthEndpoint = 'https://oauth2.googleapis.com/token';
const oauthValue = {access_token: 'synthetic-qualification-token', token_type: 'Bearer', expires_in: 300};

function qualification(t) {
  const f = fixture(t), owner = f.running(), {permit, source} = f.oauth();
  const worker = new GoogleTokenSource();
  worker.env = {VELORA_GOOGLE_SERVICE_ACCOUNT_KEY: JSON.stringify({
    type: 'service_account', project_id: projectId, private_key: qualificationKey,
    client_email: `offline-${randomUUID()}@${projectId}.iam.gserviceaccount.com`,
  })};
  const id = permit.register(...owner);
  // This adapter models an operation-aware binding without adding any RPC to
  // the actual Worker. Both paths call the same OAuth implementation.
  const binding = {async acquire(project, operationId, ledger = source) {
    const grant = await ledger.start(operationId);
    let completion;
    try {
      return await acquireGoogleToken(worker.env, project, work => { completion = work; });
    } finally {
      // The acknowledgement can finish after the emulated caller stops waiting.
      const acknowledge = async () => {
        if (completion === undefined || await completion) await ledger.acknowledge(operationId, grant);
      };
      binding.receipt = acknowledge();
      void binding.receipt.catch(() => {});
    }
  }};
  return {f, owner, permit, source, worker, id, binding};
}

function oauthResponse(body = Response.json(oauthValue).body) {
  return Object.defineProperty(new Response(body), 'url', {value: oauthEndpoint});
}

function controlOAuthDeadline(t) {
  const registered = Promise.withResolvers();
  const schedule = globalThis.setTimeout;
  t.mock.method(globalThis, 'setTimeout', (fn, ms, ...args) => {
    if (ms !== 3000) return schedule(fn, ms, ...args);
    registered.resolve(() => fn(...args));
    return schedule(fn, 30000, ...args);
  });
  return registered.promise;
}

test('named Token Source and offline operation binding share real signing, fetch and cache', async t => {
  const q = qualification(t), another = q.f.running();
  const second = q.permit.register(...another);
  const fetch = t.mock.method(globalThis, 'fetch', async url => {
    assert.equal(url, oauthEndpoint);
    return oauthResponse();
  });
  assert.equal(tokenSourceDefault.fetch, undefined);
  assert.deepEqual(Object.getOwnPropertyNames(GoogleTokenSource.prototype),
    ['constructor', 'acquire', 'trackedOAuthVersion', 'acquireTracked']);
  const result = await q.binding.acquire(projectId, q.id);
  await q.binding.receipt;
  assert.equal(result.access_token, oauthValue.access_token);
  assert.equal((await q.worker.acquire(projectId)).access_token, oauthValue.access_token);
  await q.binding.acquire(projectId, second);
  await q.binding.receipt;
  assert.equal(fetch.mock.callCount(), 1);
  assert.equal(q.permit.status(q.id, ...q.owner), 'settled');
  assert.equal(q.permit.status(second, ...another), 'settled');
  const stored = JSON.stringify(q.f.db.prepare('SELECT value FROM fixture_kv').all());
  assert.doesNotMatch(stored, /PRIVATE KEY|synthetic-qualification-token|iam\.gserviceaccount/);
});

test('actual OAuth exchange cannot replay a lost grant and keeps committed evidence after a lost receipt', async t => {
  const q = qualification(t), secondOwner = q.f.running();
  const second = q.permit.register(...secondOwner);
  const fetch = t.mock.method(globalThis, 'fetch', async () => oauthResponse());
  await assert.rejects(q.binding.acquire(projectId, q.id, {...q.source, start(op) {
    q.source.start(op);
    throw Error('lost start reply');
  }}), /lost start reply/);
  q.f.restart();
  await assert.rejects(q.binding.acquire(projectId, q.id), oauthDenied);
  assert.equal(q.permit.status(q.id, ...q.owner), 'started');
  assert.equal(fetch.mock.callCount(), 0);
  await q.binding.acquire(projectId, second, {...q.source, acknowledge(op, grant) {
    q.source.acknowledge(op, grant);
    throw Error('lost acknowledgement');
  }});
  await assert.rejects(q.binding.receipt, /lost acknowledgement/);
  q.f.restart();
  assert.equal(q.f.oauth().permit.status(second, ...secondOwner), 'settled');
  assert.equal(fetch.mock.callCount(), 1);
});

test('actual signer completion is required after deadline and late signing cannot fetch', async t => {
  const q = qualification(t), deadline = controlOAuthDeadline(t);
  const signing = Promise.withResolvers(), entered = Promise.withResolvers();
  t.mock.method(crypto.subtle, 'sign', () => { entered.resolve(); return signing.promise; });
  const fetch = t.mock.method(globalThis, 'fetch', () => assert.fail('late signer fetched'));
  const failure = assert.rejects(q.binding.acquire(projectId, q.id), /unavailable/);
  await entered.promise;
  (await deadline)();
  await failure;
  assert.equal(q.permit.status(q.id, ...q.owner), 'started');
  signing.resolve(new Uint8Array([1]).buffer);
  await q.binding.receipt;
  assert.equal(q.permit.status(q.id, ...q.owner), 'settled');
  assert.equal(fetch.mock.callCount(), 0);
});

for (const phase of ['fetch', 'body']) {
  test(`actual OAuth deadline during ${phase} leaves ambiguous cleanup pending across restart`, async t => {
    const q = qualification(t), deadline = controlOAuthDeadline(t);
    const entered = Promise.withResolvers(), reading = Promise.withResolvers(), cleaning = Promise.withResolvers();
    const fetched = Promise.withResolvers(), read = Promise.withResolvers(), cleanup = Promise.withResolvers();
    const response = {status: 200, url: oauthEndpoint, body: {getReader: () => ({
      read() { reading.resolve(); return read.promise; },
      cancel() { cleaning.resolve(); return cleanup.promise; },
      releaseLock() {},
    })}};
    t.mock.method(globalThis, 'fetch', (_url, {signal}) => {
      entered.resolve(signal);
      return phase === 'fetch' ? fetched.promise : response;
    });
    const failure = assert.rejects(q.binding.acquire(projectId, q.id), /unavailable/);
    const signal = await entered.promise;
    if (phase === 'body') await reading.promise;
    (await deadline)();
    await failure;
    assert.equal(signal.aborted, true);
    q.f.restart();
    assert.equal(q.permit.status(q.id, ...q.owner), 'started');
    if (phase === 'fetch') fetched.resolve(response);
    else read.resolve({done: true});
    await cleaning.promise;
    assert.equal(q.permit.status(q.id, ...q.owner), 'started');
    cleanup.resolve();
    await q.binding.receipt;
    assert.equal(q.permit.status(q.id, ...q.owner), 'started');
  });
}

test('actual OAuth stream cleanup rejection cannot acknowledge settlement', async t => {
  const q = qualification(t);
  let released = false;
  t.mock.method(globalThis, 'fetch', async () => ({
    status: 200, url: oauthEndpoint, body: {getReader: () => ({
      read: async () => ({done: true}),
      cancel: async () => { throw Error('synthetic-secret-detail'); },
      releaseLock() { released = true; },
    })},
  }));
  await assert.rejects(q.binding.acquire(projectId, q.id), {message: 'unavailable'});
  await q.binding.receipt;
  assert.equal(released, true);
  assert.equal(q.permit.status(q.id, ...q.owner), 'started');
});

test('actual OAuth EOF before deadline can settle once pending cleanup completes', async t => {
  const q = qualification(t), deadline = controlOAuthDeadline(t);
  const cleaning = Promise.withResolvers(), cleanup = Promise.withResolvers();
  let reads = 0;
  t.mock.method(globalThis, 'fetch', async () => ({
    status: 200, url: oauthEndpoint, body: {getReader: () => ({
      async read() {
        return reads++ === 0
          ? {done: false, value: new TextEncoder().encode(JSON.stringify(oauthValue))}
          : {done: true};
      },
      cancel() { cleaning.resolve(); return cleanup.promise; },
      releaseLock() {},
    })},
  }));
  const failure = assert.rejects(q.binding.acquire(projectId, q.id), /unavailable/);
  await cleaning.promise;
  (await deadline)();
  await failure;
  assert.equal(q.permit.status(q.id, ...q.owner), 'started');
  cleanup.resolve();
  await q.binding.receipt;
  assert.equal(q.permit.status(q.id, ...q.owner), 'settled');
});

test('durable OAuth resource samples count actual ledger operations and synthetic boundary calls', async t => {
  const worker = new GoogleTokenSource();
  let active;
  const fetch = t.mock.method(globalThis, 'fetch', async () => oauthResponse());
  const credential = email => JSON.stringify({type: 'service_account', project_id: projectId,
    client_email: email + '@velora-73222.iam.gserviceaccount.com', private_key: qualificationKey});
  const ack = {
    start(version, id) {
      active.reverse++;
      return active.f.coordinator.startOAuth(active.path === 'failed-start' ? randomUUID() : id);
    },
    acknowledge(version, id, grant) {
      active.reverse++;
      const result = active.f.coordinator.acknowledgeOAuth(id, grant);
      if (active.path === 'lost-ack') throw Error('Fixture drops acknowledgement reply after commit');
      return result;
    },
  };
  worker.env = {OAUTH_ACK: ack, VELORA_GOOGLE_SERVICE_ACCOUNT_KEY: credential('resource-sample')};
  for (const path of ['cold', 'cache-hit', 'failed-start', 'lost-ack']) {
    const f = fixture(t, {VELORA_DURABLE_OAUTH: 'true'});
    const forward = {calls: 0};
    active = {f, path, reverse: 0};
    if (path === 'lost-ack') worker.env.VELORA_GOOGLE_SERVICE_ACCOUNT_KEY = credential('resource-cold-again');
    f.env.VELORA_GOOGLE_TOKEN_SOURCE = {
      trackedOAuthVersion() { forward.calls++; return worker.trackedOAuthVersion(); },
      acquireTracked(...args) { forward.calls++; return worker.acquireTracked(...args); },
    };
    const holder = await createWorkerAdmission(f.env).acquire();
    const before = {...f.io}, startFetch = fetch.mock.callCount(), cpu = process.cpuUsage(), start = performance.now();
    if (path === 'cold' || path === 'cache-hit') await holder.acquireOAuth(new AbortController().signal);
    else await assert.rejects(holder.acquireOAuth(new AbortController().signal), /unavailable/);
    assert.equal(await holder.finish(), true);
    const usage = process.cpuUsage(cpu);
    const sample = {path, forward: forward.calls, reverse: active.reverse, coordinatorCalls: 2 + active.reverse,
      reads: f.io.kvGets - before.kvGets + f.io.sqlRowsRead - before.sqlRowsRead,
      writes: f.io.kvPuts - before.kvPuts, oauthPosts: fetch.mock.callCount() - startFetch,
      payloadBytes: f.db.prepare("SELECT SUM(length(key) + length(value)) AS bytes FROM fixture_kv WHERE key LIKE 'oauth-operation%'").get().bytes,
      nodeCpuMs: Math.round((usage.user + usage.system) / 100) / 10,
      wallMs: Math.round((performance.now() - start) * 10) / 10};
    assert.equal(sample.forward, 2);
    assert.equal(sample.reverse, path === 'failed-start' ? 1 : 2);
    assert.equal(sample.writes, path === 'failed-start' ? 3 : 4);
    assert.equal(sample.oauthPosts, ['cold', 'lost-ack'].includes(path) ? 1 : 0);
    t.diagnostic(JSON.stringify(sample));
  }
});
