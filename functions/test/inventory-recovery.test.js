'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const creation = require('../src/inventory-create');
const update = require('../src/inventory-update');
const stock = require('../src/inventory-stock');
const lifecycle = require('../src/inventory-lifecycle');
const {reconcileInventory, InventoryRecoveryError} = require('../src/inventory-recovery');
const {createRestFake} = require('./helpers/shared-firestore-rest-fake.cjs');
const modules = Promise.all([import('../backend/google-http.mjs'), import('../backend/firestore-store.mjs')]);
globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const templates = {
  create: {idempotencyKey: 'create-request-0001', name: 'Rice', category: 'Dry', quantity: 2,
    unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'},
  update: {idempotencyKey: 'update-request-0001', itemId: 'item', expectedVersion: 1, name: 'New rice'},
  'adjust-stock': {idempotencyKey: 'stock-request-0001', itemId: 'item', expectedVersion: 1, direction: 'in', quantity: 2, reason: 'Delivery'},
  lifecycle: {idempotencyKey: 'archive-request-0001', itemId: 'item', expectedVersion: 1, action: 'archive'},
};
const domains = {create: creation.createInventoryItem, update: update.updateInventoryItem,
  'adjust-stock': stock.adjustInventoryStock, lifecycle: lifecycle.setInventoryLifecycle};
async function fixture({uid = 'owner', generation = 0, ...storeOptions} = {}) {
  const [{createGoogleHttp}, {createFirestoreStore}] = await modules;
  const seed = {'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1},
    'cafes/cafe/inventory/item': {cafeId: 'cafe', name: 'Rice', category: 'Dry', quantity: 5, unit: 'kg',
      schemaVersion: 1, version: 1, expiryDate: new Date('2030-01-02T00:00:00Z')}};
  for (const actor of ['owner', 'staff']) {
    const link = {uid: actor, cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: generation};
    seed[`user_cafe_memberships/${actor}`] = link;
    seed[`cafes/cafe/members/${actor}`] = {...link, role: actor};
  }
  const fake = createRestFake(seed), http = createGoogleHttp({projectId, transport: fake.transport});
  const store = createFirestoreStore({projectId, http, accessToken: Object.assign(async () => 'synthetic-access', {projectId}),
    sleep: async () => {}, ...storeOptions});
  const auth = {uid, token: {email_verified: true}}, context = {expectedCafeId: 'cafe', expectedMembershipGeneration: generation};
  const mutate = (operation, request = {...context, ...templates[operation]}) => domains[operation]({auth, data: request, store,
    timestamp: store.timestamp, toTimestamp: store.toTimestamp, deleteValue: store.deleteValue});
  const recover = (operation, request = {...context, ...templates[operation]}, identity = auth) => reconcileInventory({auth: identity,
    data: {operation, request}, store});
  return {fake, store, auth, context, mutate, recover};
}
const commits = f => f.fake.calls.filter(call => call.method === 'commit');
function receiptPaths(f, operation) {
  return Object.keys(f.fake.snapshot()).filter(path => operation === 'create' ? path.includes('/inventory/item_') ||
    path.includes('/inventory_movements/create_') || path.includes('/activities/inventory_create_') :
  operation === 'adjust-stock' ? path.includes('/inventory_movements/stock_') || path.includes('/activities/inventory_stock_') :
    path.includes(`/activities/inventory_${operation === 'update' ? 'update' : 'lifecycle'}_`));
}
async function readOnly(f, action) {
  const before = f.fake.snapshot(), count = commits(f).length;
  const result = await action();
  assert.deepEqual(f.fake.snapshot(), before);
  assert.ok(commits(f).slice(count).every(call => call.body.writes.length === 0));
  return result;
}

for (const uid of ['owner', 'staff']) for (const generation of [0, 7]) for (const operation of Object.keys(templates)) {
  test(`${uid} generation ${generation} ${operation}: canonical REST records yield only historical result`, async () => {
    const f = await fixture({uid, generation}), original = await f.mutate(operation);
    assert.deepEqual(await readOnly(f, () => f.recover(operation)), {state: 'committed', result: original});
  });
}

test('normalizers preserve creation/key whitespace and sorted metadata changes/date/URL digest', async () => {
  const f = await fixture();
  const request = {...f.context, ...templates.create, name: ' Rice  flour ', category: ' Dry ', idempotencyKey: ' create-request-0001 '};
  const result = await f.mutate('create', request);
  assert.deepEqual(await f.recover('create', {...request, name: 'Rice flour', category: 'Dry', idempotencyKey: 'create-request-0001'}),
    {state: 'committed', result});
  const metadata = {...f.context, ...templates.update, unit: 'g', expiryDate: '2031-02-03T00:00:00.000Z',
    imageUrl: 'https://EXAMPLE.test/p', category: ' New  dry ', name: ' New  rice '};
  const updated = await f.mutate('update', metadata);
  const reordered = {...f.context, name: 'New rice', category: 'New dry', imageUrl: 'https://example.test/p',
    expiryDate: metadata.expiryDate, unit: 'g', expectedVersion: 1, itemId: 'item', idempotencyKey: 'update-request-0001'};
  assert.deepEqual(await readOnly(f, () => f.recover('update', reordered)), {state: 'committed', result: updated});
});

test('zero-stock creation, metadata no-op, stock-out and restore retain canonical historical flags', async () => {
  for (const [operation, changes] of [['create', {quantity: 0}], ['update', {name: 'Rice'}],
    ['adjust-stock', {direction: 'out', quantity: 5}], ['lifecycle', {action: 'restore', expectedVersion: 2, idempotencyKey: 'restore-request-0001'}]]) {
    const f = await fixture();
    if (operation === 'lifecycle') await f.mutate('lifecycle');
    const request = {...f.context, ...templates[operation], ...changes}, result = await f.mutate(operation, request);
    assert.deepEqual(await readOnly(f, () => f.recover(operation, request)), {state: 'committed', result});
  }
});

for (const operation of Object.keys(templates)) test(`${operation}: missing and every partial receipt remain unknown`, async () => {
  const empty = await fixture();
  assert.deepEqual(await readOnly(empty, () => empty.recover(operation)), {state: 'unknown'});
  const complete = await fixture(); await complete.mutate(operation);
  for (const path of receiptPaths(complete, operation)) {
    const f = await fixture(); await f.mutate(operation); f.fake.replace(path, undefined);
    assert.deepEqual(await readOnly(f, () => f.recover(operation)), {state: 'unknown'});
  }
});

for (const operation of Object.keys(templates)) for (const field of ['actorUid', 'cafeId', 'itemId', 'requestHash', 'schemaVersion', 'createdAt']) {
  test(`${operation}: corrupted audit ${field} cannot acknowledge a commit`, async () => {
    const f = await fixture(); await f.mutate(operation);
    const path = receiptPaths(f, operation).find(path => path.includes('/activities/'));
    f.fake.replace(path, {...f.fake.snapshot()[path], [field]: field === 'schemaVersion' ? 2 : 'forged'});
    assert.deepEqual(await readOnly(f, () => f.recover(operation)), {state: 'unknown'});
  });
}

for (const operation of ['update', 'adjust-stock', 'lifecycle']) test(`${operation}: payload digest conflicts remain unknown`, async () => {
  const f = await fixture(); await f.mutate(operation);
  const path = receiptPaths(f, operation).find(path => path.includes('/activities/'));
  f.fake.replace(path, {...f.fake.snapshot()[path], payloadHash: '0'.repeat(64)});
  assert.deepEqual(await readOnly(f, () => f.recover(operation)), {state: 'unknown'});
});

for (const operation of Object.keys(templates)) test(`${operation}: changed original payload with the same key cannot adopt a receipt`, async () => {
  const f = await fixture(); await f.mutate(operation);
  const changed = operation === 'create' || operation === 'update' ? {name: 'Different'} :
    operation === 'adjust-stock' ? {quantity: 3} : {action: 'restore'};
  assert.deepEqual(await readOnly(f, () => f.recover(operation, {...f.context, ...templates[operation], ...changed})), {state: 'unknown'});
  assert.equal((await f.recover(operation)).state, 'committed');
});

test('creation immutable binding and linked initial records survive later mutable item changes', async () => {
  const f = await fixture(), result = await f.mutate('create');
  const path = `cafes/cafe/inventory/${result.itemId}`;
  f.fake.replace(path, {...f.fake.snapshot()[path], name: 'Different', quantity: 999, version: 99,
    unit: 'pcs', imageUrl: 'different', expiryDate: new Date('2040-01-01'), lifecycleState: 'archived'});
  assert.deepEqual(await readOnly(f, () => f.recover('create')), {state: 'committed', result});
  for (const field of ['createPayloadHash', 'createRequestHash', 'createdBy', 'createdAt', 'cafeId', 'schemaVersion']) {
    const original = f.fake.snapshot()[path]; f.fake.replace(path, {...original, [field]: 'forged'});
    assert.deepEqual(await f.recover('create'), {state: 'unknown'}); f.fake.replace(path, original);
  }
});

for (const operation of ['update', 'adjust-stock', 'lifecycle']) test(`${operation}: later current stock/state/version cannot replace historical acknowledgement`, async () => {
  const f = await fixture(), original = await f.mutate(operation);
  f.fake.replace('cafes/cafe/inventory/item', {quantity: 0, version: 999, lifecycleState: 'active'});
  assert.deepEqual(await readOnly(f, () => f.recover(operation)), {state: 'committed', result: original});
});

for (const field of ['previousQuantity', 'resultingQuantity', 'quantity', 'direction', 'reason', 'fromVersion', 'resultVersion', 'delta', 'type']) {
  test(`stock arithmetic/schema corruption ${field} cannot acknowledge even when rows agree`, async () => {
    const f = await fixture(); await f.mutate('adjust-stock');
    for (const path of receiptPaths(f, 'adjust-stock')) {
      const row = f.fake.snapshot()[path];
      f.fake.replace(path, {...row, [field]: typeof row[field] === 'number' ? 0 : 'forged'});
    }
    assert.deepEqual(await readOnly(f, () => f.recover('adjust-stock')), {state: 'unknown'});
  });
}

for (const fields of [[], ['name', 'name'], ['unknown'], ['unit', 'name']]) test(`metadata changedFields ${JSON.stringify(fields)} must match canonical evidence`, async () => {
  const f = await fixture(); await f.mutate('update');
  const path = receiptPaths(f, 'update')[0]; f.fake.replace(path, {...f.fake.snapshot()[path], changedFields: fields});
  assert.deepEqual(await f.recover('update'), {state: 'unknown'});
});

for (const [field, value] of [['resultState', 'active'], ['fromState', 'archived'], ['resultVersion', 3],
  ['preservedQuantity', -1], ['type', 'inventory_restored']]) test(`lifecycle inconsistent ${field} stays unknown`, async () => {
  const f = await fixture(); await f.mutate('lifecycle');
  const path = receiptPaths(f, 'lifecycle')[0]; f.fake.replace(path, {...f.fake.snapshot()[path], [field]: value});
  assert.deepEqual(await f.recover('lifecycle'), {state: 'unknown'});
});

for (const data of [null, [], {}, {operation: 'unknown', request: {}}, {operation: '__proto__', request: {}},
  {operation: 'create', request: templates.create}, {operation: 'create', request: {}, receiptPath: 'arbitrary'},
  {operation: 'create', request: {...templates.create, expectedCafeId: 'cafe', expectedMembershipGeneration: 0, actorUid: 'owner'}},
  {operation: 'update', request: {expectedCafeId: 'cafe', expectedMembershipGeneration: 0, ...templates.update, quantity: 3}}]) {
  test(`strict observation envelope rejects ${JSON.stringify(data)}`, async () => {
    const f = await fixture();
    await assert.rejects(reconcileInventory({auth: f.auth, data, store: f.store}), error => error instanceof InventoryRecoveryError && error.code === 'invalid-argument');
    assert.equal(f.fake.calls.length, 0);
  });
}

test('missing/unverified identity denied before any reads', async () => {
  const f = await fixture();
  for (const auth of [null, {uid: 'owner'}, {uid: '../owner', token: {email_verified: true}}]) {
    await assert.rejects(f.recover('create', undefined, auth), {code: 'unauthenticated'});
  }
  assert.equal(f.fake.calls.length, 0);
});

for (const kind of ['other-actor', 'workspace', 'generation']) test(`${kind} cannot observe another original operation`, async () => {
  const f = await fixture(); await f.mutate('adjust-stock');
  if (kind === 'other-actor') assert.deepEqual(await f.recover('adjust-stock', undefined,
    {uid: 'staff', token: {email_verified: true}}), {state: 'unknown'});
  else await assert.rejects(f.recover('adjust-stock', {...f.context, ...templates['adjust-stock'],
    ...(kind === 'workspace' ? {expectedCafeId: 'other'} : {expectedMembershipGeneration: 1})}), {code: 'aborted'});
});

const invalidAuthority = [
  ['missing mapping', 'user_cafe_memberships/staff', null],
  ['inactive mapping', 'user_cafe_memberships/staff', {status: 'inactive'}],
  ['wrong mapping schema', 'user_cafe_memberships/staff', {schemaVersion: 2}],
  ['wrong mapping UID', 'user_cafe_memberships/staff', {uid: 'other'}],
  ['wrong cafe', 'user_cafe_memberships/staff', {cafeId: 'other'}],
  ['missing member', 'cafes/cafe/members/staff', null],
  ['inactive member', 'cafes/cafe/members/staff', {status: 'inactive'}],
  ['wrong member schema', 'cafes/cafe/members/staff', {schemaVersion: '1'}],
  ['role forged', 'cafes/cafe/members/staff', {role: 'owner'}],
  ['fractional generation', 'user_cafe_memberships/staff', {membershipGeneration: 0.5}],
  ['negative generation', 'cafes/cafe/members/staff', {membershipGeneration: -1}],
  ['mismatched generation', 'cafes/cafe/members/staff', {membershipGeneration: 1}],
  ['unsafe generation', 'user_cafe_memberships/staff', {membershipGeneration: 9007199254740992}],
  ['inactive cafe', 'cafes/cafe', {status: 'inactive'}],
  ['wrong cafe schema', 'cafes/cafe', {schemaVersion: 2}],
  ['missing cafe', 'cafes/cafe', null],
  ['invalid owner', 'cafes/cafe', {ownerUid: '..'}],
  ['missing owner', 'cafes/cafe/members/owner', null],
  ['inactive owner', 'cafes/cafe/members/owner', {status: 'inactive'}],
  ['wrong owner role', 'cafes/cafe/members/owner', {role: 'staff'}],
  ['missing owner mapping', 'user_cafe_memberships/owner', null],
  ['owner generation mismatch', 'user_cafe_memberships/owner', {membershipGeneration: 7}],
];
for (const [name, path, patch] of invalidAuthority) test(`cross-domain authority agreement: ${name}`, async () => {
  const f = await fixture({uid: 'staff'});
  const previous = f.fake.snapshot()[path];
  if (patch?.membershipGeneration === 9007199254740992) {
    // Wire decoder rejects the unsafe stored integer before any domain can use it.
    f.fake.hooks.batchGet = ({body}) => body.documents[0].endsWith('/' + path) ?
      f.fake.json([{found: {...f.fake.doc(path, previous), fields: {...f.fake.doc(path, previous).fields,
        membershipGeneration: {integerValue: '9007199254740992'}}}}]) : undefined;
  } else f.fake.replace(path, patch === null ? undefined : {...previous, ...patch});
  for (const operation of Object.keys(templates)) {
    await assert.rejects(f.mutate(operation));
    await assert.rejects(f.recover(operation));
  }
  assert.equal(commits(f).length, 0);
});

test('legacy absent generations are accepted only as complete actor/Owner pairs', async () => {
  const f = await fixture({uid: 'staff'});
  for (const path of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff',
    'user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
    const row = f.fake.snapshot()[path]; delete row.membershipGeneration; f.fake.replace(path, row);
  }
  const original = await f.mutate('adjust-stock');
  assert.deepEqual(await f.recover('adjust-stock'), {state: 'committed', result: original});
  f.fake.replace('user_cafe_memberships/staff', {...f.fake.snapshot()['user_cafe_memberships/staff'], membershipGeneration: 0});
  await assert.rejects(f.recover('adjust-stock'), {code: 'permission-denied'});
});

test('actor and Owner generations are independently validated, never implicitly equated', async () => {
  const f = await fixture({uid: 'staff', generation: 7});
  for (const path of ['user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 12});
  }
  const result = await f.mutate('adjust-stock');
  assert.deepEqual(await readOnly(f, () => f.recover('adjust-stock')), {state: 'committed', result});
});

test('a later actor episode cannot inherit an old receipt using the old key', async () => {
  const f = await fixture({uid: 'staff'}); await f.mutate('adjust-stock');
  for (const path of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 1});
  }
  await assert.rejects(f.recover('adjust-stock'), {code: 'aborted'});
  assert.deepEqual(await f.recover('adjust-stock', {...f.context, ...templates['adjust-stock'], expectedMembershipGeneration: 1}),
    {state: 'unknown'});
});

test('observation failures are bounded and do not publish evidence or retry unknown acknowledgements', async () => {
  const f = await fixture({rpcTimeoutMs: 15, timeoutMs: 100, cleanupTimeoutMs: 5});
  await f.mutate('adjust-stock');
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  f.fake.hooks.batchGet = () => gate;
  const start = Date.now();
  await assert.rejects(f.recover('adjust-stock'));
  assert.ok(Date.now() - start < 1000);
  const count = f.fake.calls.length;
  release(); await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(f.fake.calls.length, count);
  delete f.fake.hooks.batchGet;
  const commitCount = commits(f).length, before = f.fake.snapshot();
  f.fake.commitModes.push('lost');
  await assert.rejects(f.recover('adjust-stock'), error => error.outcomeUnknown === true);
  assert.equal(commits(f).length, commitCount + 1);
  assert.deepEqual(commits(f).at(-1).body.writes, []);
  assert.deepEqual(f.fake.snapshot(), before);
});

test('absent receipt plus late original commit stays unknown then becomes observable without replay', async () => {
  const f = await fixture({rpcTimeoutMs: 20, timeoutMs: 1000}); let release, entered;
  const gate = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  let blocked = false;
  f.fake.hooks.commit = async ({body}) => {
    if (!blocked && body.writes.length) { blocked = true; entered(); await gate; }
  };
  const failed = assert.rejects(f.mutate('adjust-stock'), error => error.outcomeUnknown === true);
  await started; await failed;
  assert.deepEqual(await readOnly(f, () => f.recover('adjust-stock')), {state: 'unknown'});
  release(); await new Promise(resolve => setTimeout(resolve, 10));
  const observed = await readOnly(f, () => f.recover('adjust-stock'));
  assert.equal(observed.state, 'committed'); assert.equal(observed.result.resultingQuantity, 7);
  assert.equal(commits(f).filter(call => call.body.writes.length).length, 1);
});

test('read-only contention retries safely and revalidates authority after removal', async () => {
  const f = await fixture({uid: 'staff'}); await f.mutate('adjust-stock');
  f.fake.commitModes.push('abort');
  assert.equal((await readOnly(f, () => f.recover('adjust-stock'))).state, 'committed');
  let first = true;
  f.fake.hooks.commit = () => {
    if (!first) return;
    first = false; f.fake.replace('cafes/cafe/members/staff', {...f.fake.snapshot()['cafes/cafe/members/staff'], status: 'removed'});
    return f.fake.nativeError(409, 'ABORTED');
  };
  await assert.rejects(f.recover('adjust-stock'), {code: 'permission-denied'});
});
