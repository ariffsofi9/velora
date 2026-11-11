import test from 'node:test';
import assert from 'node:assert/strict';
import {createMenuHttp} from '../https/menu-http.mjs';
import {createGoogleHttp} from '../backend/google-http.mjs';
import {createFirestoreStore} from '../backend/firestore-store.mjs';
import {createRestFake} from './helpers/shared-firestore-rest-fake.cjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const episode = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const creation = {...episode, idempotencyKey: 'menu-create-00001', name: ' Tea ', category: 'Drinks',
  priceMinor: 350, isAvailable: true};
const document = (changes = {}) => ({cafeId: 'cafe', name: 'Tea', category: 'Drinks', priceMinor: 350,
  currency: 'MYR', isAvailable: true, isArchived: false, version: 1, schemaVersion: 1,
  createdBy: 'owner', updatedBy: 'owner', createdAt: new Date(0), updatedAt: new Date(0), ...changes});
function fixture(overrides = {}) {
  const identity = fakes.fixture(), fake = createRestFake(identity.store.snapshot());
  const http = createGoogleHttp({projectId, transport: fake.transport});
  const store = createFirestoreStore({projectId, http, sleep: async () => {},
    accessToken: Object.assign(async () => 'synthetic-access', {projectId})});
  const options = {projectId, storeProjectId: projectId, verifyIdentity: createIdentity(identity.identity),
    store, timestamp: store.timestamp, ...overrides};
  const handler = createMenuHttp(options);
  const call = async (operation, data = {}, {uid = 'owner', token = identity.token(uid), method = 'POST', raw} = {}) => {
    const response = await handler(new Request(`https://offline.invalid/menu/${operation}`, {method,
      headers: {'content-type': 'application/json', ...(token === null ? {} : {authorization: `Bearer ${token}`})},
      ...(method === 'POST' ? {body: raw ?? JSON.stringify(data)} : {})}));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return {status: response.status, body: await response.json()};
  };
  fake.replace('cafes/cafe/menu_items/item', document());
  return {identity, fake, store, options, call};
}
const commits = f => f.fake.calls.filter(c => c.method === 'commit');
const update = {...episode, idempotencyKey: 'menu-update-00001', itemId: 'item', expectedVersion: 1, isAvailable: false};
const lifecycle = {...episode, idempotencyKey: 'menu-archive-0001', itemId: 'item', expectedVersion: 1, action: 'archive'};

test('construction requires explicit compatible dependencies and performs no I/O', () => {
  const f = fixture(); assert.equal(f.fake.calls.length, 0);
  for (const patch of [{storeProjectId: 'other'}, {store: {...f.store, projectId: 'other'}},
    {store: {...f.store, capabilities: {}}}, {timestamp: undefined}, {verifyIdentity: undefined}]) {
    assert.throws(() => createMenuHttp({...f.options, ...patch}));
  }
});

test('Owner creates canonical money, identity/time and receipt atomically; historical replay cannot overwrite later edits', async () => {
  const f = fixture(), initial = f.fake.snapshot();
  const first = await f.call('create', creation); assert.equal(first.status, 200);
  const itemId = first.body.itemId, path = `cafes/cafe/menu_items/${itemId}`;
  const item = f.fake.snapshot()[path];
  assert.equal(item.name, 'Tea'); assert.equal(item.priceMinor, 350); assert.equal(item.currency, 'MYR');
  assert.equal(item.createdBy, 'owner'); assert.ok(item.createdAt instanceof Date);
  assert.equal(commits(f)[0].body.writes.length, 2);
  assert.ok(commits(f)[0].body.writes.every(w => w.currentDocument.exists === false && w.updateTransforms.length));
  assert.equal((await f.call('update', {...update, itemId, priceMinor: 400})).status, 200);
  const before = f.fake.snapshot();
  assert.deepEqual(await f.call('create', creation), {status: 200, body: {...first.body, changed: false}});
  assert.deepEqual(f.fake.snapshot(), before); assert.deepEqual(commits(f).at(-1).body.writes, []);
  assert.equal((await f.call('create', {...creation, priceMinor: 401})).status, 409);
  assert.deepEqual(f.fake.snapshot()['cafes/cafe/inventory/item'], initial['cafes/cafe/inventory/item']);
  assert.ok(commits(f).flatMap(c => c.body.writes).every(w => /\/menu_(items|requests)\//.test(w.update.name)));
});

test('Staff reads and availability-only update succeed; Owner archive/restore increments versions', async () => {
  const f = fixture();
  assert.equal((await f.call('get', {itemId: 'item'}, {uid: 'staff'})).body.item.currency, 'MYR');
  assert.equal((await f.call('list', {}, {uid: 'staff'})).body.items.length, 1);
  assert.equal((await f.call('update', update, {uid: 'staff'})).body.version, 2);
  assert.equal((await f.call('lifecycle', {...lifecycle, expectedVersion: 2})).body.version, 3);
  assert.deepEqual((await f.call('list')).body.items, []);
  assert.equal((await f.call('list', {includeArchived: true})).body.items[0].isArchived, true);
  assert.equal((await f.call('get', {itemId: 'item'})).body.item.isArchived, true);
  assert.equal((await f.call('update', {...update, expectedVersion: 3})).status, 409);
  assert.equal((await f.call('lifecycle', {...lifecycle, expectedVersion: 3, action: 'restore', idempotencyKey: 'menu-restore-0001'})).body.version, 4);
});

for (const [op, data] of [['create', creation], ['lifecycle', lifecycle],
  ['update', {...update, name: 'Tea'}], ['update', {...update, priceMinor: 350}]]) {
  test(`Staff forbidden mutation ${op} ${JSON.stringify(data)}`, async () => {
    const f = fixture(), before = f.fake.snapshot();
    assert.deepEqual(await f.call(op, data, {uid: 'staff'}), {status: 403, body: {error: 'permission-denied'}});
    assert.deepEqual(f.fake.snapshot(), before); assert.equal(commits(f).length, 0);
  });
}
for (const [field, value] of [['role', 'owner'], ['actorUid', 'owner'], ['cafeId', 'other'],
  ['currency', 'USD'], ['priceMinor', 1.5], ['priceMinor', -1], ['priceMinor', 1000001], ['isAvailable', 'true']]) {
  test(`strict menu validation rejects ${field}=${value}`, async () => {
    const f = fixture(); assert.equal((await f.call('create', {...creation, [field]: value})).status, 400);
    assert.equal(commits(f).length, 0);
  });
}
for (const [name, patch] of [['stale version', {expectedVersion: 2}], ['foreign cafe', {expectedCafeId: 'other'}],
  ['stale generation', {expectedMembershipGeneration: 1}]]) test(`rejects ${name}`, async () => {
  const f = fixture(); assert.deepEqual(await f.call('update', {...update, ...patch}), {status: 409, body: {error: 'aborted'}});
  assert.equal(commits(f).length, 0);
});

test('receipt key conflicts across operations; unavailable foreign item is not read from another cafe', async () => {
  const f = fixture(); await f.call('update', update);
  assert.equal((await f.call('lifecycle', {...lifecycle, idempotencyKey: update.idempotencyKey})).status, 409);
  f.fake.replace('cafes/other/menu_items/foreign', document({cafeId: 'other'}));
  assert.equal((await f.call('get', {itemId: 'foreign'})).status, 404);
  assert.equal((await f.call('get', {itemId: '../other/item'})).status, 400);
  assert.ok(f.fake.calls.filter(c => c.method === 'batchGet').every(c => !c.body.documents[0].includes('/cafes/other/')));
});

test('query pagination orders IDs, filters archived, scopes parent and uses exclusive cursor plus look-ahead', async () => {
  const f = fixture();
  for (const id of ['a', 'b', 'c']) f.fake.replace(`cafes/cafe/menu_items/${id}`, document());
  f.fake.replace('cafes/cafe/menu_items/aa', document({isArchived: true}));
  f.fake.replace('cafes/other/menu_items/ab', document({cafeId: 'other'}));
  const first = await f.call('list', {limit: 2});
  assert.deepEqual(first.body.items.map(i => i.id), ['a', 'b']); assert.equal(first.body.nextCursor, 'b');
  const second = await f.call('list', {limit: 2, cursor: 'b'});
  assert.deepEqual(second.body.items.map(i => i.id), ['c', 'item']); assert.equal(second.body.nextCursor, null);
  assert.deepEqual((await f.call('list', {includeArchived: true, limit: 2})).body.items.map(i => i.id), ['a', 'aa']);
  const queries = f.fake.calls.filter(c => c.method === 'runQuery');
  assert.ok(queries.every(c => c.url.endsWith('/cafes/cafe:runQuery') && c.body.structuredQuery.limit === 3));
  assert.equal(queries[1].body.structuredQuery.startAt.before, false);
});
for (const kind of ['currency', 'price', 'timestamp', 'cafe', 'archived', 'duplicate', 'foreign', 'project', 'order', 'cursor']) {
  test(`query rejects malformed or isolated ${kind} row including look-ahead`, async () => {
    const f = fixture();
    f.fake.hooks.runQuery = () => {
      const bad = document(kind === 'currency' ? {currency: 'USD'} : kind === 'price' ? {priceMinor: -1} :
        kind === 'timestamp' ? {updatedAt: 'bad'} : kind === 'cafe' ? {cafeId: 'other'} :
          kind === 'archived' ? {isArchived: true} : {});
      const a = {document: f.fake.doc('cafes/cafe/menu_items/a', document()), readTime: f.fake.instant};
      const b = {document: f.fake.doc('cafes/cafe/menu_items/b', bad), readTime: f.fake.instant};
      if (kind === 'foreign') b.document.name = f.fake.resource('cafes/other/menu_items/b');
      if (kind === 'project') b.document.name = b.document.name.replace(projectId, 'velora-73222');
      return f.fake.json(kind === 'duplicate' ? [a, a] : kind === 'order' ? [b, a] : [a, b]);
    };
    const result = await f.call('list', {limit: 1, ...(kind === 'cursor' ? {cursor: 'a'} : {})});
    assert.ok([409, 503].includes(result.status)); assert.equal(commits(f).length, 0);
    assert.equal(JSON.stringify(result).includes('SYNTHETIC'), false);
  });
}
for (const mode of ['lost', 'applied-lost', 'malformed', 'bad-transform']) test(`${mode} commit remains unknown without automatic retry`, async () => {
  const f = fixture(); f.fake.commitModes.push(mode);
  assert.deepEqual(await f.call('create', creation), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 1);
});
test('known abort retries transaction; authority removed during contention fails closed', async () => {
  const f = fixture(); f.fake.commitModes.push('abort');
  assert.equal((await f.call('update', update)).status, 200); assert.equal(commits(f).length, 2);
  const g = fixture(); let first = true;
  g.fake.hooks.commit = () => { if (first) { first = false; g.fake.replace('user_cafe_memberships/owner', undefined); } };
  assert.equal((await g.call('update', update)).status, 403); assert.equal(commits(g).length, 1);
});
test('concurrent versions permit one distinct mutation and unchanged retry converges through receipt', async () => {
  const f = fixture();
  const results = await Promise.all([f.call('update', update), f.call('update', {...update, idempotencyKey: 'menu-update-00002'})]);
  assert.deepEqual(results.map(r => r.status).sort(), [200, 409]);
  const g = fixture(), replay = await Promise.all([g.call('update', update), g.call('update', update)]);
  assert.ok(replay.every(r => r.status === 200)); assert.equal(replay.filter(r => r.body.changed).length, 1);
});
for (const kind of ['missing', 'disabled', 'revoked', 'project', 'outsider', 'owner-link']) test(`rejects ${kind} authority`, async () => {
  const f = fixture(); let token = f.identity.token('owner');
  if (kind === 'missing') token = null;
  if (kind === 'disabled') f.identity.accounts.owner.disabled = true;
  if (kind === 'revoked') f.identity.accounts.owner.tokensValidAfterTime = new Date(f.identity.now() + 1000).toISOString();
  if (kind === 'project') token = f.identity.token('owner', {aud: 'velora-73222'});
  if (kind === 'outsider') token = f.identity.token('outsider');
  if (kind === 'owner-link') f.fake.replace('cafes/cafe/members/owner', undefined);
  assert.equal((await f.call('list', {}, {token})).status, ['outsider', 'owner-link'].includes(kind) ? 403 : 401);
  assert.equal(commits(f).length, 0);
});
test('unknown routes, malformed/oversized bodies and methods never dispatch', async () => {
  const f = fixture();
  assert.equal((await f.call('delete')).status, 404);
  assert.equal((await f.call('list?x=1')).status, 404);
  assert.equal((await f.call('list', {}, {method: 'GET'})).status, 405);
  assert.equal((await f.call('list', {}, {raw: '{'})).status, 400);
  assert.equal((await f.call('list', {}, {raw: ' '.repeat(2049)})).status, 413);
  assert.equal(f.fake.calls.length, 0);
});

test('verification deadline and late completion cannot dispatch menu work', async () => {
  let release;
  const pending = new Promise(resolve => { release = resolve; });
  const f = fixture({verifyIdentity: () => pending, verificationTimeoutMs: 5});
  assert.equal((await f.call('create', creation)).status, 408);
  release({uid: 'owner'}); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.fake.calls.length, 0);
});
test('storage read failures expose only sanitized uncertain outcomes', async () => {
  const f = fixture(); f.fake.hooks.batchGet = () => { throw Error('SYNTHETIC PRIVATE DETAIL'); };
  assert.deepEqual(await f.call('list'), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 0);
});
