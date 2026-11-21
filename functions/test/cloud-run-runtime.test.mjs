import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {EventEmitter, once} from 'node:events';
import {request} from 'node:http';
import {createServer} from 'node:net';
import test, {after, before} from 'node:test';
import {fileURLToPath} from 'node:url';
import {CERTIFICATE_URL, OAUTH_URL} from '../backend/google-http.mjs';
import {syntheticIdentity} from '../feasibility/shared-backend/integration/synthetic-identity.mjs';
import {startCloudRun} from '../runtime/cloud-run-entry.mjs';
import firestore from './helpers/shared-firestore-rest-fake.cjs';

const projectId = 'velora-spark-test';
const origin = 'https://api.example.test';
const entry = fileURLToPath(new URL('../runtime/cloud-run-entry.mjs', import.meta.url));
const timeout = {timeout: 8000};
let externalCalls = 0;
const nativeFetch = globalThis.fetch;
before(() => {
  globalThis.fetch = () => { externalCalls++; throw new Error('External network forbidden.'); };
});
after(() => {
  globalThis.fetch = nativeFetch;
  assert.equal(externalCalls, 0);
});

function environment(port) {
  return {PORT: String(port), VELORA_CANONICAL_ORIGIN: origin, VELORA_FIREBASE_PROJECT: projectId};
}

async function reservePort() {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return server;
}

async function availablePort() {
  const server = await reservePort();
  const {port} = server.address();
  await new Promise(resolve => server.close(resolve));
  return port;
}

function send(port, path, {headers, method = 'POST', chunks = []} = {}) {
  return new Promise((resolve, reject) => {
    const req = request({host: '127.0.0.1', port, path, method, headers, agent: false}, res => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', chunk => { body += chunk; });
      res.once('error', reject);
      res.once('end', () => resolve({status: res.statusCode, headers: res.headers, body}));
    });
    req.once('error', reject);
    for (const chunk of chunks) req.write(chunk);
    req.end();
  });
}

function fixture() {
  const identity = syntheticIdentity(Date.now);
  const seed = {'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1}};
  const link = {uid: 'owner', cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: 0,
    createdAt: new Date(), updatedAt: new Date()};
  seed['user_cafe_memberships/owner'] = link;
  seed['cafes/cafe/members/owner'] = {...link, role: 'owner'};
  const store = firestore.createRestFake(seed);
  const calls = [];
  let signs = 0;
  const dependencies = {
    credential: {projectId, email: 'synthetic@velora-spark-test.iam.gserviceaccount.com',
      sign: async bytes => { signs++; return identity.sign(bytes); }},
    transport: async (url, options) => {
      calls.push(url);
      if (url === CERTIFICATE_URL) {
        return Response.json({synthetic: identity.certificate}, {headers: {'cache-control': 'max-age=60'}});
      }
      if (url === OAUTH_URL) {
        identity.verifyAssertion(options.body);
        return Response.json({access_token: 'synthetic-access', token_type: 'Bearer', expires_in: 3600});
      }
      assert.equal(options.headers.authorization, 'Bearer synthetic-access');
      if (url === `https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`) {
        return Response.json({users: [{localId: 'owner', email: 'owner@example.test',
          emailVerified: true, disabled: false, validSince: '0'}]});
      }
      assert.match(url, /^https:\/\/firestore\.googleapis\.com\/v1\/projects\/velora-spark-test\//);
      return store.transport(url, options);
    },
  };
  return {dependencies, identity, calls, store, signCount: () => signs};
}

async function start(t, options = {}) {
  const port = await availablePort();
  const signals = new EventEmitter();
  const logs = [];
  const service = await startCloudRun({
    env: environment(port), signals, log: event => logs.push(event), ...options,
  });
  t.after(() => service.close());
  return {port, signals, logs, ...service};
}

test('import is inert and direct startup failure reports nonzero with redacted output', timeout, () => {
  const imported = spawnSync(process.execPath, ['--input-type=module', '-e',
    `await import(${JSON.stringify(new URL('../runtime/cloud-run-entry.mjs', import.meta.url).href)})`],
  {encoding: 'utf8', timeout: 3000});
  assert.equal(imported.status, 0);
  assert.equal(imported.stdout + imported.stderr, '');
  const invalid = spawnSync(process.execPath, [entry], {
    env: {...process.env, ...environment('private-env-sentinel')}, encoding: 'utf8', timeout: 3000,
  });
  assert.equal(invalid.status, 1);
  assert.deepEqual(JSON.parse(invalid.stdout), {event: 'startup-failed', category: 'invalid-configuration'});
  assert.equal(invalid.stderr, '');
});

test('rejects missing, malformed and out-of-range ports and invalid origin and project', timeout, async () => {
  const valid = environment(8080);
  for (const patch of [
    {PORT: undefined}, {PORT: '1.2'}, {PORT: ' 80'}, {PORT: '0'}, {PORT: '-1'}, {PORT: '65536'},
    {VELORA_CANONICAL_ORIGIN: undefined}, {VELORA_CANONICAL_ORIGIN: 'http://api.example.test'},
    {VELORA_CANONICAL_ORIGIN: origin + '/other'}, {VELORA_FIREBASE_PROJECT: undefined},
    {VELORA_FIREBASE_PROJECT: 'velora-73222'},
  ]) {
    const signals = new EventEmitter();
    await assert.rejects(startCloudRun({env: {...valid, ...patch}, signals, log: () => {}}), /startup failed/);
    assert.equal(signals.listenerCount('SIGTERM'), 0);
  }
  const {dependencies} = fixture();
  dependencies.credential.projectId = 'foreign-project';
  await assert.rejects(startCloudRun({env: valid, dependencies, log: () => {}}), /startup failed/);
});

test('occupied port fails startup and detaches the SIGTERM listener', timeout, async t => {
  const occupied = await reservePort();
  t.after(() => occupied.close());
  const signals = new EventEmitter(), logs = [];
  await assert.rejects(startCloudRun({
    env: environment(occupied.address().port), signals, log: event => logs.push(event),
  }), /startup failed/);
  assert.equal(signals.listenerCount('SIGTERM'), 0);
  assert.deepEqual(logs, [{event: 'startup-failed', category: 'listener-failure'}]);
});

test('health uses the configured port without dispatch, signing or transport', timeout, async t => {
  const f = fixture();
  const {port, logs} = await start(t, {dependencies: f.dependencies});
  const result = await send(port, '/healthz', {method: 'GET'});
  assert.equal(result.status, 200);
  assert.deepEqual(JSON.parse(result.body), {status: 'ok'});
  assert.equal(f.calls.length, 0);
  assert.equal(f.signCount(), 0);
  assert.deepEqual(logs, [{event: 'startup-complete'}]);
});

test('direct synthetic defaults reject business requests and ignore credential selectors', timeout, async t => {
  const port = await availablePort(), logs = [];
  const f = fixture();
  const service = await startCloudRun({env: {...environment(port),
    GOOGLE_APPLICATION_CREDENTIALS: 'private-path-sentinel',
    GCE_METADATA_HOST: 'metadata-sentinel',
    VELORA_SERVICE_ACCOUNT_KEY: 'private-key-sentinel'},
  signals: new EventEmitter(), log: event => logs.push(event)});
  t.after(() => service.close());
  const result = await send(port, '/staff/redeem', {headers: {'content-type': 'application/json',
    authorization: `Bearer ${f.identity.token()}`}, chunks: ['{"code":"invitation-sentinel"}']});
  assert.equal(result.status, 401);
  assert.deepEqual(JSON.parse(result.body), {error: 'unauthenticated'});
  assert.deepEqual(logs, [{event: 'startup-complete'}]);
});

test('chunked upload reaches the canonical invitation operation with synthetic dependencies', timeout, async t => {
  const f = fixture();
  const {port, logs} = await start(t, {dependencies: f.dependencies});
  const headers = {'content-type': 'application/json', authorization: `Bearer ${f.identity.token()}`,
    host: 'untrusted.example.test', forwarded: 'proto=http;host=untrusted.example.test',
    'x-forwarded-host': 'untrusted.example.test', origin};
  const denied = await send(port, '/staff/create', {headers: {...headers, origin: 'https://wrong.example.test'}});
  assert.equal(denied.status, 403);
  assert.equal(f.calls.length, 0);
  const result = await send(port, '/staff/create', {headers, chunks: [
    '{"email":"joiner@example.test","requestId":"request_123456789",',
    '"expectedCafeId":"cafe","expectedMembershipGeneration":0}',
  ]});
  assert.equal(result.status, 200, result.body);
  assert.equal(result.headers['access-control-allow-origin'], origin);
  const invitation = JSON.parse(result.body);
  assert.ok(invitation.code);
  assert.equal(f.store.calls.filter(call => call.method === 'commit').length, 1);
  assert.equal(f.signCount(), 1);
  assert.deepEqual(logs, [{event: 'startup-complete'}]);
});

test('launcher retains adapter and route request limits', timeout, async t => {
  const f = fixture();
  const {port} = await start(t, {dependencies: f.dependencies});
  const headers = {'content-type': 'application/json', authorization: `Bearer ${f.identity.token()}`};
  const oversized = await send(port, '/staff/create', {headers: {...headers, 'content-length': '65537'}});
  assert.equal(oversized.status, 413);
  assert.equal(f.calls.length, 0);
  const routeLimit = await send(port, '/staff/create', {headers, chunks: ['x'.repeat(2049)]});
  assert.equal(routeLimit.status, 413);
  assert.deepEqual(JSON.parse(routeLimit.body), {error: 'too-large'});
  assert.equal(f.store.calls.length, 0);
});

test('admission and deadline preserve uncertainty without redispatch', timeout, async t => {
  const f = fixture();
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  let upstreamCalls = 0;
  f.dependencies.transport = async () => {
    upstreamCalls++; entered.resolve(); await release.promise;
    throw new Error('private exception sentinel');
  };
  const {port, logs} = await start(t, {dependencies: f.dependencies,
    runtimeOptions: {maxConcurrent: 1, requestTimeoutMs: 300}});
  const headers = {'content-type': 'application/json', authorization: `Bearer ${f.identity.token()}`};
  const first = send(port, '/staff/create', {headers, chunks: ['{}']});
  try {
    await entered.promise;
    assert.equal((await send(port, '/staff/create', {headers})).status, 429);
    const result = await first;
    assert.equal(result.status, 504);
    assert.deepEqual(JSON.parse(result.body), {error: 'deadline-exceeded', outcomeUnknown: true});
    assert.equal(upstreamCalls, 1);
    assert.equal(f.signCount(), 0);
    assert.deepEqual(logs, [{event: 'startup-complete'}]);
  } finally { release.resolve(); }
});

for (const force of [false, true]) {
  test(`SIGTERM is idempotent and ${force ? 'force-closes after the drain deadline' : 'drains admitted work'}`,
    {timeout: 10000}, async t => {
      const f = fixture();
      const entered = Promise.withResolvers(), release = Promise.withResolvers();
      let calls = 0;
      f.dependencies.transport = async () => {
        calls++; entered.resolve(); await release.promise;
        throw new Error('private exception sentinel');
      };
      const {port, signals, close, logs} = await start(t, {dependencies: f.dependencies,
        runtimeOptions: {shutdownTimeoutMs: force ? 75 : 500}});
      assert.equal(signals.listenerCount('SIGTERM'), 1);
      const headers = {'content-type': 'application/json', authorization: `Bearer ${f.identity.token()}`};
      const active = send(port, '/staff/create', {headers, chunks: ['{}']});
      const outcome = force ? assert.rejects(active) : active;
      try {
        await entered.promise;
        signals.emit('SIGTERM');
        signals.emit('SIGTERM');
        const stopping = close();
        assert.equal(close(), stopping);
        await assert.rejects(send(port, '/healthz', {method: 'GET'}));
        if (!force) release.resolve();
        const result = await outcome;
        if (!force) assert.deepEqual(JSON.parse(result.body), {error: 'unauthenticated'});
        await stopping;
        assert.equal(signals.listenerCount('SIGTERM'), 0);
        assert.equal(calls, 1);
        assert.deepEqual(logs, [{event: 'startup-complete'}, {event: 'shutdown-started'}, {event: 'shutdown-complete'}]);
      } finally { release.resolve(); }
    });
}
