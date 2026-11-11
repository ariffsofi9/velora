import test from 'node:test';
import assert from 'node:assert/strict';
import {createInvitationHttp, createInvitationAccountResolver} from '../https/invitation-http.mjs';
import {createGoogleHttp} from '../backend/google-http.mjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';

const context = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const payload = {...context, email: 'joiner@example.test', requestId: 'request_123456789'};
const bindAccount = fn => Object.assign(fn, {projectId: 'velora-spark-test'});

test('trusted rejoin defaults disabled and client flags cannot enable account resolution', async () => {
  let lookups = 0;
  const f = setup({resolveAccount: bindAccount(async () => { lookups++; return null; })});
  assert.equal((await f.call('/staff/create')).status, 200); assert.equal(lookups, 0);
  for (const field of ['allowRejoin', 'resolveAccount', 'targetGeneration', 'targetUid']) {
    assert.deepEqual(await f.call('/staff/create', {...payload, [field]: true}),
      {status: 400, body: {error: 'invalid-argument'}});
  }
  assert.equal(lookups, 0);
});

test('rejoin factory requires explicit project-bound resolver and valid finite budget', () => {
  for (const options of [{allowRejoin: 'true'}, {allowRejoin: true},
    {allowRejoin: true, resolveAccount: async () => null},
    {allowRejoin: true, resolveAccount: Object.assign(async () => null, {projectId: 'velora-73222'})},
    {accountTimeoutMs: 0}]) assert.throws(() => setup(options));
});

test('trusted resolver executes before transaction callbacks; canonical fresh first join remains possible', async () => {
  let resolving = false, lookups = 0;
  const f = setup({allowRejoin: true, resolveAccount: bindAccount(async email => {
    resolving = true; lookups++; assert.equal(email, payload.email); return f.accounts.joiner;
  })});
  const original = f.store.runTransaction.bind(f.store);
  f.store.runTransaction = action => { assert.equal(resolving, true); return original(action); };
  assert.equal((await f.call('/staff/create')).status, 200); assert.equal(lookups, 1);
});

test('resolver timeout bounds response, retains safe envelope and cannot dispatch after late completion', async () => {
  const pending = deferred();
  const f = setup({allowRejoin: true, accountTimeoutMs: 15, resolveAccount: bindAccount(() => pending.promise)});
  const before = f.store.snapshot();
  assert.deepEqual(await f.call('/staff/create'), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  pending.resolve(f.accounts.joiner); await flush();
  assert.deepEqual(f.store.snapshot(), before);
});

function resolverFixture(overrides = {}) {
  const projectId = 'velora-spark-test', calls = [], profiles = [];
  const http = createGoogleHttp({projectId, transport: async (url, options) => {
    calls.push({url, options});
    return Response.json({users: [{localId: 'joiner', PRIVATE: 'SECRET'}]});
  }});
  const options = {projectId, http, accessToken: bindAccount(async () => 'synthetic-access'),
    getAccount: bindAccount(async uid => { profiles.push(uid); return {uid, disabled: false, emailVerified: true,
      email: 'joiner@example.test'}; }), ...overrides};
  return {calls, profiles, options, resolve: createInvitationAccountResolver(options)};
}

test('email lookup is private, project pinned, bounded and revalidated through exact UID lookup', async () => {
  const f = resolverFixture(); assert.equal(f.calls.length, 0);
  const account = await f.resolve('joiner@example.test');
  assert.equal(account.uid, 'joiner'); assert.deepEqual(f.profiles, ['joiner']);
  assert.equal(f.calls[0].url, 'https://identitytoolkit.googleapis.com/v1/projects/velora-spark-test/accounts:lookup');
  assert.deepEqual(JSON.parse(f.calls[0].options.body), {email: ['joiner@example.test']});
  assert.equal(f.calls[0].options.headers.authorization, 'Bearer synthetic-access');
  assert.equal(JSON.stringify(account).includes('SECRET'), false);
  assert.equal((await setup().call('/staff/accounts', {})).status, 404);
});

for (const patch of [{projectId: 'velora-73222'}, {http: async () => {}}, {accessToken: async () => {}},
  {getAccount: Object.assign(async () => {}, {projectId: 'other'})}, {timeoutMs: 0}]) {
  test(`email resolver rejects cross-bound/missing dependency ${Object.keys(patch)[0]}`, () => {
    const f = resolverFixture(); assert.throws(() => createInvitationAccountResolver({...f.options, ...patch}));
  });
}

for (const email of ['invalid', 'Joiner@example.test', ' joiner@example.test', 'joiner@example.test\n', 'join\u0001er@example.test']) {
  test(`internal email resolver rejects malformed/noncanonical input ${JSON.stringify(email)}`, async () => {
    const f = resolverFixture(); await assert.rejects(f.resolve(email), {kind: 'account'});
    assert.equal(f.calls.length, 0);
  });
}

for (const users of [null, {}, [null], [{localId: '../joiner'}], [{localId: 'joiner'}, {localId: 'other'}]]) {
  test(`malformed account response ${JSON.stringify(users)} cannot select an identity`, async () => {
    const f = resolverFixture({http: bindAccount(async () => ({status: 200, data: {users}}))});
    await assert.rejects(f.resolve('joiner@example.test'), {kind: 'account', code: 'unavailable'});
    assert.equal(f.profiles.length, 0);
  });
}

for (const account of [null, {uid: 'other'}, {uid: 'joiner', disabled: true},
  {uid: 'joiner', disabled: false, emailVerified: true, email: 'other@example.test'}]) {
  test(`fresh UID response ${JSON.stringify(account)} cannot bind wrong rejoin identity`, async () => {
    const f = resolverFixture({getAccount: bindAccount(async () => account)});
    await assert.rejects(f.resolve('joiner@example.test'), {kind: 'account', code: 'unavailable'});
  });
}

test('missing email candidate is null, never a fabricated UID', async () => {
  const f = resolverFixture({http: bindAccount(async () => ({status: 200, data: {users: []}}))});
  assert.equal(await f.resolve('joiner@example.test'), null); assert.equal(f.profiles.length, 0);
});

test('late privileged credential cannot start email lookup after deadline', async () => {
  const pending = deferred();
  const f = resolverFixture({timeoutMs: 15, accessToken: bindAccount(() => pending.promise)});
  await assert.rejects(f.resolve('joiner@example.test'), {kind: 'account'});
  pending.resolve('synthetic-access'); await flush(); assert.equal(f.calls.length, 0);
});
function setup(options = {}) {
  const f = fakes.fixture();
  const dependencies = {projectId: 'velora-spark-test', storeProjectId: 'velora-spark-test',
    verifyIdentity: createIdentity(f.identity), store: f.store, now: () => new Date(f.now()), ...options};
  const handler = createInvitationHttp(dependencies);
  const call = async (path, data = payload, {uid = 'owner', token, method = 'POST', raw, headers = {}} = {}) => {
    const response = await handler(new Request('https://offline.invalid' + path, {
      method, headers: {'content-type': 'application/json', authorization: `Bearer ${token ?? f.token(uid)}`, ...headers},
      ...(method === 'GET' ? {} : {body: raw ?? JSON.stringify(data)}),
    }));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return {status: response.status, body: await response.json()};
  };
  return {...f, handler, call, dependencies};
}
const rows = f => Object.entries(f.store.snapshot()).filter(([p]) => p.startsWith('workspace_invitations/'));
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => {resolve = yes; reject = no;}); return {promise, resolve, reject}; };
function manualTimers() {
  const pending = [];
  return {scheduleTimeout(callback, ms) {
    const timer = {callback, ms, active: true}; pending.push(timer);
    return () => {timer.active = false;};
  }, fire(ms) {
    const timer = pending.find(t => t.active && t.ms === ms);
    assert.ok(timer, 'expected deadline scheduled'); timer.active = false; timer.callback();
  }, active: () => pending.filter(t => t.active).length};
}

test('valid JWT syntax and claims with a corrupt RSA signature is rejected before transactions', async () => {
  const f = setup(); const parts = f.token().split('.');
  assert.equal(JSON.parse(Buffer.from(parts[0], 'base64url')).alg, 'RS256');
  assert.equal(JSON.parse(Buffer.from(parts[1], 'base64url')).aud, 'velora-spark-test');
  const signature = Buffer.from(parts[2], 'base64url'); signature[0] ^= 1;
  const forged = [parts[0], parts[1], signature.toString('base64url')].join('.');
  let transactions = 0; const original = f.store.runTransaction.bind(f.store);
  f.store.runTransaction = action => {transactions++; return original(action);};
  assert.equal((await f.call('/staff/create', payload, {token: forged})).status, 401);
  assert.equal(transactions, 0);
  assert.equal((await f.call('/staff/create')).status, 200, 'unaltered signed control succeeds');
  assert.equal(transactions, 1);
});

for (const lateFailure of [false, true]) test(`verification deadline prevents late dispatch, late rejection=${lateFailure}`, async () => {
  const timers = manualTimers(), pending = deferred(), entered = deferred();
  const f = setup({...timers, verificationTimeoutMs: 17,
    verifyIdentity: () => {entered.resolve(); return pending.promise;}});
  let transactions = 0; f.store.runTransaction = async () => {transactions++; throw Error('must not dispatch');};
  const response = f.call('/staff/create'); await entered.promise; timers.fire(17);
  assert.deepEqual(await response, {status: 408, body: {error: 'deadline-exceeded'}});
  if (lateFailure) pending.reject(Error('SENSITIVE_ERROR'));
  else pending.resolve({uid: 'owner', token: f.claims('owner')});
  await flush(); assert.equal(transactions, 0); assert.equal(timers.active(), 0);
});

for (const cancellation of ['complete', 'stall', 'throw']) test(`body deadline prevents mutation with ${cancellation} cancellation`, async () => {
  const timers = manualTimers(), read = deferred(), entered = deferred(), cancelled = deferred();
  const f = setup({...timers, bodyTimeoutMs: 23, cleanupTimeoutMs: 11});
  let transactions = 0, cancels = 0;
  f.store.runTransaction = async () => {transactions++; throw Error('must not dispatch');};
  // Deliberately uncancellable reader dependency: late completion must be inert.
  const request = {url: 'https://offline.invalid/staff/create', method: 'POST',
    headers: new Headers({'content-type': 'application/json', authorization: `Bearer ${f.token()}`}),
    body: {getReader: () => ({read: () => {entered.resolve(); return read.promise;}, cancel: () => {
      cancels++; cancelled.resolve();
      if (cancellation === 'stall') return new Promise(() => {});
      if (cancellation === 'throw') throw Error('SENSITIVE_ERROR');
    }})}};
  const result = f.handler(request); await entered.promise; timers.fire(23); await cancelled.promise;
  await flush(); if (cancellation === 'stall') timers.fire(11);
  const response = await result;
  assert.equal(response.status, 408); assert.deepEqual(await response.json(), {error: 'deadline-exceeded'});
  read.resolve({value: new TextEncoder().encode(JSON.stringify(payload)), done: false});
  await flush(); assert.equal(transactions, 0); assert.equal(cancels, 1); assert.equal(timers.active(), 0);
});

test('successful body with stalled cancellation never reaches domain', async () => {
  const timers = manualTimers(), cancelled = deferred();
  const f = setup({...timers, cleanupTimeoutMs: 13}); let transactions = 0;
  f.store.runTransaction = async () => {transactions++; throw Error('must not dispatch');};
  let read = false;
  const response = f.handler({url: 'https://offline.invalid/staff/create', method: 'POST',
    headers: new Headers({'content-type': 'application/json', authorization: `Bearer ${f.token()}`}),
    body: {getReader: () => ({read: async () => {
      if (read) return {done: true}; read = true;
      return {done: false, value: new TextEncoder().encode(JSON.stringify(payload))};
    }, cancel: () => {cancelled.resolve(); return new Promise(() => {});}})}});
  await cancelled.promise; timers.fire(13);
  assert.equal((await response).status, 408); assert.equal(transactions, 0);
});

test('invalid deadline configuration fails closed', () => {
  const f = setup();
  for (const value of [0, -1, 1.5, 30001]) {
    assert.throws(() => createInvitationHttp({...f.dependencies, bodyTimeoutMs: value}));
  }
});

test('explicit dependencies and matching store environment required', () => {
  assert.throws(() => createInvitationHttp({}));
  assert.throws(() => createInvitationHttp({projectId: 'velora-spark-test', storeProjectId: 'velora-73222',
    verifyIdentity() {}, store: {runTransaction() {}}, now: () => new Date()}));
});

test('shared extraction preserves invitation route isolation and its 2048-byte ceiling', async () => {
  const f = setup(); const before = f.store.snapshot();
  for (const path of ['/inventory/create', '/inventory/update', '/inventory/adjust-stock', '/inventory/lifecycle']) {
    assert.deepEqual(await f.call(path), {status: 404, body: {error: 'not-found'}});
  }
  for (const method of ['GET', 'PUT', 'DELETE', 'OPTIONS']) {
    assert.deepEqual(await f.call('/staff/create', payload, {method}), {status: 405, body: {error: 'method-not-allowed'}});
  }
  assert.deepEqual(await f.call('/staff/create', payload, {raw: 'x'.repeat(2049)}),
    {status: 413, body: {error: 'too-large'}});
  assert.deepEqual(f.store.snapshot(), before);
});

test('shared extraction preserves uncertain store-error normalization without leaking messages', async () => {
  const f = setup(); let attempts = 0;
  f.store.runTransaction = async () => { attempts++; throw Object.assign(Error('PRIVATE_STORE_PATH'), {code: 'permission-denied'}); };
  assert.deepEqual(await f.call('/staff/create'), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(attempts, 1);
});

test('create/redeem/revoke use canonical domain, issuer binding and code-only redemption', async () => {
  const f = setup();
  const created = await f.call('/staff/create');
  assert.equal(created.status, 200);
  assert.equal(rows(f)[0][1].issuerBindingVersion, 1);
  assert.equal(rows(f)[0][1].issuerMembershipGeneration, 0);
  assert.equal(JSON.stringify(f.store.snapshot()).includes(created.body.code), false);
  const joined = await f.call('/staff/redeem', {code: created.body.code}, {uid: 'joiner'});
  assert.deepEqual(joined, {status: 200, body: {joined: true, cafeId: 'cafe'}});
  assert.equal((await f.call('/staff/redeem', {code: created.body.code}, {uid: 'joiner'})).status, 409);
  const next = await f.call('/staff/create', {...payload, requestId: 'request_987654321'});
  assert.deepEqual(await f.call('/staff/revoke', {...context, invitationId: next.body.invitationId}),
    {status: 200, body: {revoked: true}});
});

for (const path of ['/staff/list', '/staff/remove', '/ai/issue', '/inventory', '/staff/create?x=1']) {
  test(`route allowlist rejects ${path}`, async () => assert.equal((await setup().call(path)).status, 404));
}
test('method content type body bounds and strict JSON validation', async () => {
  const f = setup();
  assert.equal((await f.call('/staff/create', payload, {method: 'GET'})).status, 405);
  assert.equal((await f.call('/staff/create', payload, {headers: {'content-type': 'text/plain'}})).status, 400);
  for (const raw of ['{', '[]', 'null', '"text"']) assert.equal((await f.call('/staff/create', payload, {raw})).status, 400);
  assert.equal((await f.call('/staff/create', payload, {raw: 'x'.repeat(2049)})).status, 413);
  assert.equal((await f.call('/staff/create', {...payload, ownerUid: 'owner'})).status, 400);
  assert.equal(rows(f).length, 0);
});

for (const kind of ['missing', 'forged', 'wrong-project', 'expired', 'revoked', 'disabled']) {
  test(`identity rejects ${kind} without mutation`, async () => {
    const f = setup();
    if (kind === 'revoked') f.accounts.owner.tokensValidAfterTime = '2099-01-01T00:00:00Z';
    if (kind === 'disabled') f.accounts.owner.disabled = true;
    const token = kind === 'forged' ? 'forged.jwt.value' : f.token('owner',
      kind === 'wrong-project' ? {aud: 'velora-73222'} : kind === 'expired' ? {exp: 1} : {});
    const r = await f.call('/staff/create', payload, {token, headers: kind === 'missing' ? {authorization: ''} : {}});
    assert.equal(r.status, 401); assert.equal(rows(f).length, 0);
  });
}
test('verified dependency result must still match configured project and subject', async () => {
  for (const token of [{sub: 'other'}, {aud: 'velora-73222'}, {iss: 'wrong'}, {email_verified: false}]) {
    const f = setup({verifyIdentity: async () => ({uid: 'owner', token: {
      sub: 'owner', aud: 'velora-spark-test', iss: 'https://securetoken.google.com/velora-spark-test', email_verified: true, ...token}})});
    assert.equal((await f.call('/staff/create')).status, 401);
  }
});

for (const [label, data, status] of [
  ['stale', {...payload, expectedMembershipGeneration: 1}, 409],
  ['cross-workspace', {...payload, expectedCafeId: 'other'}, 409],
  ['missing', {email: payload.email, requestId: payload.requestId}, 400],
  ['malformed', {...payload, expectedMembershipGeneration: '0'}, 400],
]) test(`${label} expectations reject before business operations`, async () => {
  const f = setup(); const original = f.store.runTransaction.bind(f.store); const accesses = [];
  f.store.runTransaction = action => original(tx => action(new Proxy(tx, {get(target, method) {
    return (...args) => { accesses.push(args[0]); return target[method](...args); };
  }})));
  const before = f.store.snapshot();
  assert.equal((await f.call('/staff/create', data)).status, status);
  assert.deepEqual(f.store.snapshot(), before);
  assert.equal(accesses.some(p => /^workspace_invite|^workspace_invitations/.test(p)), false);
});
test('Staff cannot forge Owner authority', async () => {
  const f = setup(); assert.equal((await f.call('/staff/create', payload, {uid: 'staff'})).status, 403);
});
test('duplicate request cannot create another invitation or increment counters', async () => {
  const f = setup(); assert.equal((await f.call('/staff/create')).status, 200);
  const before = f.store.snapshot();
  assert.equal((await f.call('/staff/create')).status, 409);
  assert.deepEqual(f.store.snapshot(), before);
});

for (const changeGeneration of [false, true]) test(`transaction retry retains capture, changed generation=${changeGeneration}`, async () => {
  const f = setup(); const original = f.store.runTransaction.bind(f.store);
  let attempts = 0; const ids = []; const conflict = new Error('synthetic conflict');
  f.store.runTransaction = async action => {
    try {
      return await original(async tx => {
        attempts++;
        const result = await action(new Proxy(tx, {get(target, method) {
          if (method !== 'create') return target[method];
          return (path, value) => { if (path.startsWith('workspace_invitations/')) ids.push(path); target.create(path, value); };
        }}));
        throw conflict; // Discard first draft, then retry the same domain callback.
      });
    } catch (error) {
      if (error !== conflict) throw error;
      if (changeGeneration) await original(async tx => {
        tx.update('user_cafe_memberships/owner', {membershipGeneration: 7});
        tx.update('cafes/cafe/members/owner', {membershipGeneration: 7});
      });
      attempts++;
      return original(action);
    }
  };
  const r = await f.call('/staff/create');
  assert.equal(attempts, 2); assert.equal(r.status, changeGeneration ? 409 : 200);
  assert.equal(rows(f).length, changeGeneration ? 0 : 1);
  if (!changeGeneration) assert.equal(rows(f)[0][0], ids[0]);
});

for (const applied of [false, true]) test(`unknown commit applied=${applied} never retries or fabricates success`, async () => {
  const f = setup(); const original = f.store.runTransaction.bind(f.store); let calls = 0;
  f.store.runTransaction = async action => {
    calls++;
    if (applied) await original(action);
    throw Object.assign(new Error('SECRET_SENTINEL'), {uncertain: true, code: 'permission-denied'});
  };
  const r = await f.call('/staff/create');
  assert.deepEqual(r, {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(calls, 1); assert.equal(rows(f).length, applied ? 1 : 0);
  assert.equal(JSON.stringify(r).includes('SECRET_SENTINEL'), false);
});
