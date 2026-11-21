// Local workerd qualification only. All Google responses are in-process fixtures.
import test, {after, before} from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {mkdtemp, readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
import {Miniflare, createFetchMock} from 'miniflare';

// Bundled into a test-only Worker. All assertions here execute inside workerd.
async function scenario(name) {
  if (name === 'profile-request') {
    assert.ok(profileRequest, 'profile fixture not prepared');
    const run = profileRequest;
    profileRequest = undefined;
    return run();
  }
  if (name === 'egress') {
    const marked = await fetch('https://inventory-egress.invalid/');
    assert.equal(marked.status, 599);
    assert.equal(await marked.text(), 'OFFLINE_EGRESS_DENIED');
    let blocked;
    try {
      blocked = (await fetch('https://inventory-unregistered.invalid/')).status >= 500;
    } catch {
      blocked = true;
    }
    assert.equal(blocked, true);
    return {blocked};
  }

  const projectId = 'velora-spark-test';
  const databaseId = '(default)';
  let time = Date.UTC(2026, 10, 20);
  const now = () => time;
  const identity = syntheticIdentity(now);
  const state = {'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1},
    'cafes/cafe/inventory/item': {cafeId: 'cafe', name: 'Rice', category: 'Dry',
      quantity: 5, unit: 'kg', version: 1, schemaVersion: 1,
      expiryDate: new Date('2030-01-02T00:00:00Z')}};
  const accounts = {};
  for (const uid of ['owner', 'staff', 'outsider']) {
    accounts[uid] = {localId: uid, email: `${uid}@example.test`, emailVerified: true,
      disabled: false, validSince: '0'};
    if (uid === 'outsider') continue;
    const link = {uid, cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: 7};
    state[`user_cafe_memberships/${uid}`] = link;
    state[`cafes/cafe/members/${uid}`] = {...link, role: uid};
  }
  const fake = restModule.createRestFake(state);
  const trace = [];
  let signCalls = 0, beforeRpc;
  const accountUrl = `https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`;
  const transport = async (url, options) => {
    assert.equal(options.redirect, 'error');
    if (url === CERTIFICATE_URL) {
      trace.push('certificate');
      return Response.json({synthetic: identity.certificate}, {headers: {'cache-control': 'max-age=3600'}});
    }
    if (url === OAUTH_URL) {
      trace.push('oauth');
      identity.verifyAssertion(options.body);
      return Response.json({access_token: 'synthetic-access', token_type: 'Bearer', expires_in: 3600});
    }
    if (url === accountUrl) {
      trace.push('account');
      assert.equal(options.headers.authorization, 'Bearer synthetic-access');
      const [uid] = JSON.parse(options.body).localId;
      return Response.json({users: accounts[uid] ? [accounts[uid]] : []});
    }
    const base = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/${databaseId}/documents:`;
    assert.ok(url.startsWith(base));
    const rpc = url.slice(base.length);
    assert.ok(['beginTransaction', 'batchGet', 'commit', 'rollback'].includes(rpc));
    trace.push(rpc);
    if (beforeRpc) return beforeRpc(rpc, options.signal, () => fake.transport(url, options));
    return fake.transport(url, options);
  };
  const config = {projectId, databaseId, transport, now,
    sign(bytes) { signCalls++; return identity.sign(bytes); }};
  const worker = createInventoryWorker(config);
  const scope = {expectedCafeId: 'cafe', expectedMembershipGeneration: 7};
  const stock = {...scope, idempotencyKey: 'stock-request-0001', itemId: 'item',
    expectedVersion: 1, direction: 'in', quantity: 2, reason: 'Delivery'};
  const create = {...scope, idempotencyKey: 'create-request-0001', name: 'Rice', category: 'Dry',
    quantity: 2, unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'};
  const update = {...scope, idempotencyKey: 'update-request-0001', itemId: 'item',
    expectedVersion: 1, name: 'New rice'};
  const lifecycle = {...scope, idempotencyKey: 'archive-request-0001', itemId: 'item',
    expectedVersion: 1, action: 'archive'};
  const unknown = {status: 503, body: {error: 'unavailable', outcomeUnknown: true}};
  const commits = () => fake.calls.filter(call => call.method === 'commit');
  const count = kind => trace.filter(value => value === kind).length;
  const item = () => fake.snapshot()['cafes/cafe/inventory/item'];
  const request = (operation, data = stock, {method = 'POST', uid = 'owner', claims,
    token = identity.token(uid, claims), origin = inventoryWebOrigin, url, headers} = {}) =>
    new Request(url ?? `${inventoryOrigin}/inventory/${operation}`, {
      method, headers: {'content-type': 'application/json', origin, authorization: `Bearer ${token}`, ...headers},
      ...(method === 'POST' ? {body: JSON.stringify(data)} : {}),
    });
  const dispatch = async req => {
    const response = await worker.fetch(req);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return {status: response.status, body: response.status === 204 ? null : await response.json()};
  };
  const call = (...args) => dispatch(request(...args));
  const metrics = {};

  if (name === 'profile-prepare') {
    const token = identity.token();
    profileRequest = async () => {
      // Request body streams belong to the workerd invocation that creates them.
      assert.equal((await call('adjust-stock', stock, {token})).status, 200);
      return {ok: true, subrequests: trace.length};
    };
  } else if (name === 'configuration') {
    assert.throws(() => createInventoryWorker(), /invalid-configuration/);
    for (const override of [
      {projectId: 'velora-73222'}, {databaseId: 'other'}, {databaseId: undefined},
      {transport: undefined}, {transport: globalThis.fetch}, {sign: undefined}, {now: undefined},
    ]) assert.throws(() => createInventoryWorker({...config, ...override}), /invalid-configuration/);
    assert.deepEqual(trace, []);
    assert.equal(signCalls, 0);
  } else if (name === 'admission') {
    for (const path of ['/workspace/create', '/staff/list', '/staff/redeem', '/menu/list',
      '/ai/generate', '/recipes/list', '/inventory/update/extra', '/inventory/%75pdate',
      '/inventory/update?extra=true']) {
      for (const method of ['POST', 'OPTIONS']) {
        assert.equal((await call('', stock, {method, url: inventoryOrigin + path})).status, 404);
      }
    }
    for (const operation of ['create', 'update', 'adjust-stock', 'lifecycle', 'reconcile']) {
      const response = await worker.fetch(request(operation, stock, {method: 'OPTIONS',
        headers: {'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization, content-type'}}));
      assert.equal(response.status, 204);
      assert.equal(response.headers.get('access-control-allow-origin'), inventoryWebOrigin);
    }
    assert.equal((await call('create', stock, {method: 'GET'})).status, 405);
    assert.equal((await call('create', stock, {method: 'OPTIONS'})).status, 403);
    assert.equal((await call('create', create, {origin: 'https://foreign.invalid'})).status, 403);
    assert.equal((await call('create', create, {url: 'https://foreign.invalid/inventory/create'})).status, 404);
    assert.deepEqual(trace, []);
  } else if (name === 'identity') {
    for (const options of [
      {token: 'forged'}, {claims: {aud: 'velora-73222'}},
      {claims: {email_verified: false}}, {claims: {email_verified: 'true'}},
      {claims: {exp: time / 1000 - 1}},
    ]) assert.equal((await call('adjust-stock', stock, options)).status, 401);
    assert.deepEqual(trace, []);
    const [header, claims, signature] = identity.token().split('.');
    const tampered = (signature[0] === 'A' ? 'B' : 'A') + signature.slice(1);
    assert.equal((await call('adjust-stock', stock, {token: [header, claims, tampered].join('.')})).status, 401);
    assert.deepEqual(trace, ['certificate']);
    for (const change of [{disabled: true}, {emailVerified: false}, {validSince: String(time / 1000 + 1)}]) {
      const original = accounts.owner;
      accounts.owner = {...original, ...change};
      assert.equal((await call('adjust-stock')).status, 401);
      accounts.owner = original;
    }
    assert.equal(count('account'), 3, 'warm certificate does not cache account authority');
    assert.equal(count('beginTransaction'), 0);
  } else if (name === 'workspace') {
    for (const data of [{...stock, expectedCafeId: 'different'},
      {...stock, expectedMembershipGeneration: 6}]) {
      assert.deepEqual(await call('adjust-stock', data, {uid: 'staff'}),
        {status: 409, body: {error: 'aborted'}});
    }
    assert.equal((await call('adjust-stock', stock, {uid: 'outsider'})).status, 403);
    const staffPath = 'user_cafe_memberships/staff';
    fake.replace(staffPath, {...state[staffPath], status: 'revoked'});
    assert.equal((await call('adjust-stock', stock, {uid: 'staff'})).status, 403);
    fake.replace(staffPath, state[staffPath]);
    assert.equal(commits().length, 0);
    assert.deepEqual(fake.snapshot(), state);
  } else if (name === 'mutations') {
    for (const [operation, input, uid] of [
      ['create', create, 'staff'], ['update', update, 'owner'],
      ['adjust-stock', {...stock, expectedVersion: 2}, 'staff'],
      ['lifecycle', {...lifecycle, expectedVersion: 3}, 'owner'],
    ]) assert.equal((await call(operation, input, {uid})).status, 200);
    const writes = commits().map(commit => commit.body.writes);
    assert.deepEqual(writes.map(batch => batch.length), [3, 2, 3, 2]);
    for (const batch of [writes[0], writes[2]]) {
      for (const collection of ['inventory', 'inventory_movements', 'activities']) {
        assert.equal(batch.filter(write => write.update.name.includes(`/${collection}/`)).length, 1);
      }
    }
    assert.equal(item().quantity, 7);
    assert.equal(item().name, 'New rice');
    assert.equal(item().lifecycleState, 'archived');
  } else if (name === 'replay-and-budget') {
    const cold = request('adjust-stock'), replay = request('adjust-stock');
    const warm = request('adjust-stock', {...stock, expectedVersion: 2,
      idempotencyKey: 'stock-request-0002'});
    const measure = async req => {
      const start = performance.now();
      const offset = trace.length;
      const signing = signCalls;
      const response = await dispatch(req);
      const calls = trace.slice(offset);
      return {response, wallMs: performance.now() - start, calls, signs: signCalls - signing};
    };
    metrics.cold = await measure(cold);
    const committed = fake.snapshot();
    metrics.warmReplay = await measure(replay);
    assert.equal(metrics.cold.response.status, 200);
    assert.deepEqual(metrics.warmReplay.response, {
      status: 200, body: {...metrics.cold.response.body, adjusted: false},
    });
    assert.deepEqual(fake.snapshot(), committed);
    assert.equal(commits()[1].body.writes.length, 0);
    metrics.warmMutation = await measure(warm);
    assert.equal(metrics.warmMutation.response.status, 200);
    assert.equal(item().quantity, 9);
    assert.equal(metrics.cold.signs, 1);
    assert.equal(metrics.warmReplay.signs, 0);
    for (const sample of Object.values(metrics)) {
      assert.equal(sample.calls.filter(kind => kind === 'account').length, 2);
      assert.ok(sample.calls.length < 50);
    }
  } else if (name === 'definite-abort') {
    fake.commitModes.push('abort');
    assert.equal((await call('adjust-stock')).status, 200);
    assert.equal(count('beginTransaction'), 2);
    assert.equal(count('rollback'), 1);
    assert.equal(commits().length, 2);
    assert.equal(item().quantity, 7);
    metrics.subrequests = trace.length;
    metrics.retries = 1;
  } else if (name === 'lost-commit') {
    fake.commitModes.push('applied-lost');
    assert.deepEqual(await call('adjust-stock'), unknown);
    assert.equal(commits().length, 1);
    assert.equal(count('beginTransaction'), 1);
    const committed = fake.snapshot();
    const observed = await call('reconcile', {operation: 'adjust-stock', request: stock});
    assert.equal(observed.status, 200);
    assert.equal(observed.body.state, 'committed');
    assert.equal(observed.body.result.resultingQuantity, 7);
    assert.deepEqual(commits()[1].body.writes, []);
    assert.deepEqual(fake.snapshot(), committed);
  } else if (name === 'precommit-deadline' || name === 'commit-deadline') {
    const target = name === 'precommit-deadline' ? 'batchGet' : 'commit';
    const start = performance.now();
    let resume, lateFinished, aborted = false;
    beforeRpc = async (rpc, signal, respond) => {
      if (rpc !== target) return respond();
      const response = await respond();
      lateFinished = new Promise(resolve => {
        resume = () => resolve(response);
      });
      signal.addEventListener('abort', () => { aborted = true; }, {once: true});
      return lateFinished;
    };
    try {
      assert.deepEqual(await call('adjust-stock'), unknown);
      metrics.wallMs = performance.now() - start;
      assert.ok(metrics.wallMs < 12000, 'offline qualification target');
      assert.equal(aborted, true);
      assert.equal(count('beginTransaction'), 1);
    } finally {
      resume?.();
      await lateFinished;
    }
    await new Promise(resolve => setTimeout(resolve, 0)); // Drain late response continuations.
    assert.equal(count('commit'), target === 'commit' ? 1 : 0);
    assert.equal(item().quantity, target === 'commit' ? 7 : 5);
    metrics.subrequests = trace.length;
  } else {
    throw Error('Unknown offline scenario');
  }
  return {ok: true, metrics};
}

let runtime, originalCwd, cacheBefore;
const cache = new URL('../../../../.wrangler/cache/cf.json', import.meta.url);
const readCache = () => readFile(cache).catch(error => {
  if (error.code === 'ENOENT') return null;
  throw error;
});
const controlOrigin = 'https://inventory-control.invalid';

async function run(name) {
  const start = performance.now();
  const response = await runtime.dispatchFetch(controlOrigin, {
    method: 'POST', headers: {'content-type': 'application/json'},
    body: JSON.stringify({name}),
  });
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  return {result, loopbackMs: performance.now() - start};
}

before(async () => {
  originalCwd = process.cwd();
  cacheBefore = await readCache();
  const directory = await mkdtemp(join(tmpdir(), 'velora-inventory-workerd-'));
  const sourceDirectory = dirname(fileURLToPath(import.meta.url));
  const bundle = await build({
    absWorkingDir: sourceDirectory,
    stdin: {resolveDir: sourceDirectory, contents: `
      import assert from 'node:assert/strict';
      import {createInventoryWorker, inventoryOrigin, inventoryWebOrigin} from './inventory-entry.mjs';
      import {syntheticIdentity} from '../integration/synthetic-identity.mjs';
      import restModule from '../../../test/helpers/shared-firestore-rest-fake.cjs';
      import {CERTIFICATE_URL, OAUTH_URL} from '../../../backend/google-http.mjs';
      let profileRequest;
      const scenario = ${scenario.toString()};
      export default {async fetch(request) {
        try { return Response.json(await scenario((await request.json()).name)); }
        catch (error) { return Response.json({error: String(error.message)}, {status: 500}); }
      }};
    `},
    bundle: true, write: false, format: 'esm', platform: 'browser', external: ['node:*'],
    banner: {js: `import * as cryptoModule from 'node:crypto';
      import assertModule from 'node:assert/strict';
      const require = name => {
        if (name === 'node:crypto') return cryptoModule;
        if (name === 'node:assert/strict') return assertModule;
        throw Error('Unexpected module');
      };`},
  });
  process.chdir(directory);
  const fetchMock = createFetchMock();
  fetchMock.disableNetConnect();
  fetchMock.get('https://inventory-egress.invalid').intercept({path: '/', method: 'GET'})
    .reply(599, 'OFFLINE_EGRESS_DENIED');
  runtime = new Miniflare({rootPath: directory, host: '127.0.0.1', cf: false,
    inspectorHost: '127.0.0.1', inspectorPort: 0,
    cachePersist: false, modules: true, script: bundle.outputFiles[0].text,
    compatibilityDate: '2026-06-11', compatibilityFlags: ['nodejs_compat'], fetchMock});
  await runtime.ready;
  assert.equal((await run('egress')).result.blocked, true);
});

after(async () => {
  try {
    await runtime?.dispose();
    assert.deepEqual(await readCache(), cacheBefore);
  } finally {
    if (originalCwd) process.chdir(originalCwd);
  }
});

for (const name of ['configuration', 'admission', 'identity', 'workspace', 'mutations',
  'replay-and-budget', 'definite-abort', 'lost-commit', 'precommit-deadline', 'commit-deadline']) {
  test(`offline workerd inventory: ${name}`, {timeout: 30000}, async t => {
    const {result, loopbackMs} = await run(name);
    assert.equal(result.ok, true);
    if (Object.keys(result.metrics).length) t.diagnostic(JSON.stringify({loopbackMs, ...result.metrics}));
  });
}

test('offline workerd inventory: bounded inspector sample', {timeout: 25000}, async t => {
  let socket;
  const observations = {};
  try {
    const url = new URL(await runtime.getInspectorURL());
    assert.equal(url.hostname, '127.0.0.1');
    const targets = await fetch(new URL(`http://${url.host}/json/list`), {
      signal: AbortSignal.timeout(3000), redirect: 'error',
    }).then(response => response.json());
    const inspect = new URL(targets[0].webSocketDebuggerUrl);
    assert.equal(inspect.host, url.host);
    assert.equal(inspect.protocol, 'ws:');
    socket = new WebSocket(inspect);
    await once(socket, 'open', {signal: AbortSignal.timeout(3000)});
    let nextId = 0;
    async function cdp(method) {
      const id = ++nextId;
      const signal = AbortSignal.timeout(3000);
      socket.send(JSON.stringify({id, method, params: {}}));
      while (true) {
        const [event] = await once(socket, 'message', {signal});
        const message = JSON.parse(event.data);
        if (message.id !== id) continue;
        if (message.error) throw Error(method);
        return message.result;
      }
    }
    assert.equal((await run('profile-prepare')).result.ok, true);
    try { observations.heapBefore = await cdp('Runtime.getHeapUsage'); } catch { observations.heapBefore = 'UNKNOWN'; }
    let profiling = false;
    try {
      await cdp('Profiler.enable');
      await cdp('Profiler.start');
      profiling = true;
    } catch { observations.cpu = 'UNKNOWN'; }
    assert.equal((await run('profile-request')).result.ok, true);
    if (profiling) {
      try {
        const {profile} = await cdp('Profiler.stop');
        observations.cpu = {samples: profile.samples.length,
          intervalUs: profile.endTime - profile.startTime};
      } catch { observations.cpu = 'UNKNOWN'; }
    }
    try { observations.heapAfter = await cdp('Runtime.getHeapUsage'); } catch { observations.heapAfter = 'UNKNOWN'; }
  } catch (error) {
    if (error instanceof assert.AssertionError) throw error;
    observations.unavailable = error.name;
  } finally { socket?.close(); }
  t.diagnostic(JSON.stringify(observations));
});
