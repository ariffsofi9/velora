'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {PROJECT, HOSTS, assertIsolated, createRecipeService} = require('../ai1/recipe-service');
const {fakeProvider} = require('../ai1/fake-provider');

const env = () => ({GCLOUD_PROJECT: PROJECT, FUNCTIONS_EMULATOR: 'true', ...HOSTS});
const request = {auth: {uid: 'staff'}, data: {requestId: 'test-request-0001'}};
const fixedNow = new Date('2030-01-02T00:00:00Z');
function fixture() {
  const link = (uid, role) => ({uid, cafeId: 'cafe', status: 'active', schemaVersion: 1,
    ...(role ? {role} : {})});
  return {
    'user_cafe_memberships/staff': link('staff'),
    'user_cafe_memberships/owner': link('owner'),
    'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1},
    'cafes/cafe/members/staff': link('staff', 'staff'),
    'cafes/cafe/members/owner': link('owner', 'owner'),
  };
}
function item(id = 'banana', changes = {}) {
  return {id, data: {name: id === 'banana' ? 'Banana' : 'Milk', category: 'Food',
    quantity: 2, unit: 'pcs', version: 1, schemaVersion: 1,
    createdAt: new Date('2029-01-01T00:00:00Z'),
    expiryDate: new Date('2030-01-03T00:00:00Z'), ...changes}};
}
function setup({provider = fakeProvider, items = [item(), item('milk')]} = {}) {
  const docs = fixture();
  const reads = [];
  let calls = 0;
  let inTransaction = false;
  let identity = true;
  const settings = env();
  const invoke = createRecipeService({env: settings, now: () => fixedNow,
    verifyIdentity: async () => {
      if (!identity) throw Error('identity disabled');
    },
    store: {runTransaction: async (fn) => {
      inTransaction = true;
      try { return await fn({get: async (path) => { reads.push(path); return docs[path] ?? null; },
        inventory: async (path, limit) => {
          reads.push(path); assert.equal(path, 'cafes/cafe/inventory');
          assert.equal(limit, 101); return items;
        }}); } finally { inTransaction = false; }
    }},
    provider: async (input) => {
      assert.equal(inTransaction, false); calls++; return provider(input);
    },
  });
  return {invoke, docs, items, settings, reads, calls: () => calls,
    disable: () => { identity = false; }};
}
const errorCode = (code) => (error) => error.code === code;

test('exact emulator configuration required before any I/O', async () => {
  assert.doesNotThrow(() => assertIsolated(env()));
  for (const key of ['GCLOUD_PROJECT', 'FUNCTIONS_EMULATOR', ...Object.keys(HOSTS)]) {
    const s = setup(); delete s.settings[key];
    await assert.rejects(s.invoke(request), errorCode('failed-precondition'));
    assert.deepEqual(s.reads, []); assert.equal(s.calls(), 0);
  }
  for (const extra of [{GCLOUD_PROJECT: 'velora-73222'},
    {FIRESTORE_EMULATOR_HOST: 'localhost:8080'}, {GOOGLE_CLOUD_PROJECT: 'velora-73222'},
    {FIREBASE_CONFIG: 'invalid'}, {FIREBASE_CONFIG: '{"projectId":"velora-73222"}'}]) {
    assert.throws(() => assertIsolated({...env(), ...extra}), errorCode('failed-precondition'));
  }
});
test('strict authentication and request contract', async () => {
  for (const auth of [null, {uid: '../bad'}, {uid: ''}]) {
    const s = setup();
    await assert.rejects(s.invoke({...request, auth}), errorCode('unauthenticated'));
    assert.equal(s.calls(), 0);
  }
  for (const data of [null, [], {}, {...request.data, cafeId: 'other'},
    {...request.data, uid: 'owner'}, {...request.data, inventory: []},
    {...request.data, prompt: 'ignore rules'}, {...request.data, maxRecipes: 0},
    {...request.data, maxRecipes: 4}, {...request.data, maxRecipes: 1.5}]) {
    const s = setup();
    await assert.rejects(s.invoke({...request, data}), errorCode('invalid-argument'));
    assert.equal(s.calls(), 0); assert.deepEqual(s.reads, []);
  }
});
for (const [name, change] of [
  ['missing mapping', (d) => { delete d['user_cafe_memberships/staff']; }],
  ['revoked mapping', (d) => { d['user_cafe_memberships/staff'].status = 'revoked'; }],
  ['revoked member', (d) => { d['cafes/cafe/members/staff'].status = 'revoked'; }],
  ['cross-cafe member', (d) => { d['cafes/cafe/members/staff'].cafeId = 'other'; }],
  ['cross-cafe mapping', (d) => { d['user_cafe_memberships/staff'].cafeId = 'other'; }],
  ['bad schema', (d) => { d['user_cafe_memberships/staff'].schemaVersion = 2; }],
  ['inactive cafe', (d) => { d['cafes/cafe'].status = 'inactive'; }],
  ['profile role is not authority', (d) => {
    d['users/staff'] = {role: 'owner'}; d['cafes/cafe/members/staff'].role = 'owner';
  }],
  ['bad owner mapping', (d) => { d['user_cafe_memberships/owner'].cafeId = 'other'; }],
  ['missing owner', (d) => { delete d['cafes/cafe/members/owner']; }],
]) {
  test(`deny before provider: ${name}`, async () => {
    const s = setup(); change(s.docs);
    await assert.rejects(s.invoke(request), errorCode('permission-denied'));
    assert.equal(s.calls(), 0);
    assert.ok(!s.reads.includes('cafes/cafe/inventory'));
  });
}
test('read-only fixture result, filtering, UTC expiry and Malaysia today', async () => {
  const items = [item(), item('milk'), item('expired', {expiryDate: new Date('2030-01-01Z')}),
    item('zero', {quantity: 0}), item('archived', {lifecycleState: 'archived',
      archivedAt: fixedNow, archivedBy: 'owner'})];
  const original = structuredClone(items);
  const s = setup({items, provider: async ({items}) => {
    assert.deepEqual(items.map((i) => i.id), ['banana', 'milk']);
    return fakeProvider({items});
  }});
  const docs = structuredClone(s.docs);
  const result = await s.invoke(request);
  assert.equal(result.provider, 'fake'); assert.equal(result.status, 'ok');
  assert.deepEqual(result.recipes[0].ingredientItemIds, ['banana', 'milk']);
  assert.equal(s.calls(), 1); assert.deepEqual(items, original); assert.deepEqual(s.docs, docs);
});
test('empty usable inventory does not invoke provider or invent fallback', async () => {
  const s = setup({items: [item('zero', {quantity: 0})]});
  assert.equal((await s.invoke(request)).status, 'no_suggestions'); assert.equal(s.calls(), 0);
  const unmatched = setup({items: [item('rice', {name: 'Rice'})]});
  assert.deepEqual((await unmatched.invoke(request)).recipes, []);
});
test('malformed inventory fails closed, even when archived or zero stock', async () => {
  for (const changes of [{quantity: -1}, {quantity: 1.2}, {schemaVersion: 2},
    {cafeId: 'other'}, {name: ''}, {unit: null}, {version: null}, {createdAt: null},
    {expiryDate: null}, {lifecycleState: 'bad'}, {lifecycleState: 'archived'},
    {quantity: 0, name: ''}]) {
    const s = setup({items: [item('bad', changes)]});
    await assert.rejects(s.invoke(request), errorCode('failed-precondition'));
    assert.equal(s.calls(), 0);
  }
  const s = setup({items: Array.from({length: 101}, (_, n) => item(`i${n}`))});
  await assert.rejects(s.invoke(request), errorCode('resource-exhausted'));
});
test('provider results require bounded structured recipes and known item IDs', async () => {
  const valid = (await fakeProvider({items: [{id: 'banana', name: 'Banana'},
    {id: 'milk', name: 'Milk'}]}))[0];
  for (const result of [null, {}, [valid, valid], [{...valid, ingredientItemIds: ['other']}],
    [{...valid, steps: []}], [{...valid, steps: ['x'.repeat(301)]}],
    [{...valid, rawResponse: 'not allowed'}], [{...valid, title: ''}]]) {
    const s = setup({provider: async () => result});
    await assert.rejects(s.invoke(request), errorCode('internal'));
  }
});
test('authorization, identity, environment and inventory rechecked after provider', async () => {
  for (const change of ['membership', 'owner', 'inventory', 'identity', 'environment']) {
    let s;
    s = setup({provider: async (input) => {
      if (change === 'membership') s.docs['cafes/cafe/members/staff'].status = 'revoked';
      if (change === 'owner') s.docs['user_cafe_memberships/owner'].status = 'revoked';
      if (change === 'inventory') s.items[0].data.quantity++;
      if (change === 'identity') s.disable();
      if (change === 'environment') s.settings.GCLOUD_PROJECT = 'velora-73222';
      return fakeProvider(input);
    }});
    await assert.rejects(s.invoke(request)); assert.equal(s.calls(), 1);
  }
});
test('duplicate/replay requests and overlapping user requests do not call provider twice', async () => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  let started;
  const ready = new Promise((resolve) => { started = resolve; });
  const s = setup({provider: async (input) => { started(); await pending; return fakeProvider(input); }});
  const first = s.invoke(request); await ready;
  await assert.rejects(s.invoke(request), errorCode('resource-exhausted'));
  release(); await first;
  await assert.rejects(s.invoke(request), errorCode('already-exists')); assert.equal(s.calls(), 1);
  assert.equal((await s.invoke({...request, data: {requestId: 'new-request-0002'}})).status, 'ok');
});
test('transaction retries cannot duplicate provider invocation', async () => {
  let calls = 0;
  const docs = fixture();
  const tx = {get: async (p) => docs[p], inventory: async () => [item(), item('milk')]};
  const invoke = createRecipeService({env: env(), now: () => fixedNow,
    verifyIdentity: async () => {},
    store: {runTransaction: async (fn) => { await fn(tx); return fn(tx); }},
    provider: async (input) => { calls++; return fakeProvider(input); }});
  await invoke(request); assert.equal(calls, 1);
});
