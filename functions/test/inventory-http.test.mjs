import test from 'node:test';
import assert from 'node:assert/strict';
import {createInventoryHttp} from '../https/inventory-http.mjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';
import stockDomain from '../src/inventory-stock.js';
import updateDomain from '../src/inventory-update.js';

// These explicit sentinels are resolved by the transaction store at commit.
// They are never serialized as null, client time, or an archive-field value.
const SERVER_TIME = Symbol('server timestamp'), DELETE_FIELD = Symbol('delete field');
const commitTime = new Date('2026-11-11T00:00:00.000Z');
function resolve(value) {
  if (value === SERVER_TIME) return new Date(commitTime);
  if (value instanceof Date) return new Date(value);
  if (Array.isArray(value)) return value.map(resolve);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .filter(([, v]) => v !== DELETE_FIELD).map(([k, v]) => [k, resolve(v)]));
  return value;
}
class MemoryStore {
  capabilities = {serverTimestamps: true, deleteFields: true};
  transactions = 0; failAtWrite = 0; failCommit = false; appliedLost = false;
  constructor(seed) { this.records = new Map(Object.entries(structuredClone(seed))); this.tail = Promise.resolve(); }
  snapshot() { return structuredClone(Object.fromEntries(this.records)); }
  async runTransaction(action) {
    const previous = this.tail; let release; this.tail = new Promise(done => {release = done;});
    await previous; this.transactions++;
    try {
      const draft = structuredClone(this.records), writes = [];
      const stage = (kind, path, data) => {
        if (this.failAtWrite && writes.length + 1 === this.failAtWrite) throw Error('SENSITIVE_STORE_FAILURE');
        writes.push({kind, path, data});
      };
      const result = await action({get: async path => {
        if (writes.length) throw Error('read after write');
        return structuredClone(draft.get(path) ?? null);
      }, create: (path, data) => stage('create', path, data), update: (path, data) => stage('update', path, data)});
      if (this.failCommit) throw Object.assign(Error('SENSITIVE_STORE_FAILURE'), {uncertain: true});
      for (const {kind, path, data} of writes) {
        if ((kind === 'create') === draft.has(path)) throw Error('precondition');
        if (kind === 'create') draft.set(path, resolve(data));
        else {
          const row = {...draft.get(path)};
          for (const [key, value] of Object.entries(data)) {
            if (value === DELETE_FIELD) delete row[key]; else row[key] = resolve(value);
          }
          draft.set(path, row);
        }
      }
      this.records = draft;
      if (this.appliedLost) throw Object.assign(Error('SENSITIVE_STORE_FAILURE'), {uncertain: true, code: 'aborted'});
      return result;
    } finally { release(); }
  }
}
const context = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const createData = {...context, idempotencyKey: 'create-request-0001', name: 'Flour', category: 'Dry',
  quantity: 4, unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z', imageUrl: ''};
const updateData = {...context, idempotencyKey: 'update-request-0001', itemId: 'item', expectedVersion: 1, name: 'New Rice'};
const stockData = {...context, idempotencyKey: 'stock-request-0001', itemId: 'item', expectedVersion: 1,
  direction: 'in', quantity: 2, reason: 'Delivery'};
const lifecycleData = {...context, idempotencyKey: 'lifecycle-request-0001', itemId: 'item', expectedVersion: 1, action: 'archive'};
const operations = [['create', createData], ['update', updateData], ['adjust-stock', stockData], ['lifecycle', lifecycleData]];
function fixture(overrides = {}) {
  const f = fakes.fixture(), store = new MemoryStore(f.store.snapshot());
  const transforms = {timestamps: 0, dates: 0, deletes: 0};
  const dependencies = {projectId: 'velora-spark-test', storeProjectId: 'velora-spark-test',
    verifyIdentity: createIdentity(f.identity), store,
    timestamp: () => {transforms.timestamps++; return SERVER_TIME;},
    toTimestamp: date => {assert.ok(date instanceof Date); transforms.dates++; return new Date(date);},
    deleteValue: () => {transforms.deletes++; return DELETE_FIELD;}, ...overrides};
  const handler = createInventoryHttp(dependencies);
  const call = async (route, data, {uid = 'owner', token, method = 'POST', raw, headers = {}} = {}) => {
    const response = await handler(new Request('https://offline.invalid' + route, {method,
      headers: {'content-type': 'application/json', authorization: 'Bearer ' + (token ?? f.token(uid)), ...headers},
      ...(method === 'GET' ? {} : {body: raw ?? JSON.stringify(data)})}));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return {status: response.status, body: await response.json()};
  };
  return {...f, store, dependencies, handler, call, transforms};
}
const rows = (f, collection) => Object.entries(f.store.snapshot()).filter(([p]) => p.includes('/' + collection + '/'));

test('requires compatible transform-capable store and explicit dependencies', () => {
  assert.throws(() => createInventoryHttp({}));
  const f = fixture();
  for (const change of [{timestamp: undefined}, {toTimestamp: undefined}, {deleteValue: undefined},
    {store: {runTransaction() {}}}, {storeProjectId: 'velora-73222'}]) assert.throws(() => createInventoryHttp({...f.dependencies, ...change}));
});

for (const uid of ['owner', 'staff']) for (const [name, data] of operations) test(`${uid} ${name} uses canonical domain`, async () => {
  const f = fixture(); const response = await f.call('/inventory/' + name, data, {uid});
  assert.equal(response.status, 200); assert.equal(response.body.cafeId, 'cafe'); assert.equal(f.store.transactions, 1);
  const activities = rows(f, 'activities'); assert.equal(activities.length, 1);
  assert.equal(activities[0][1].actorUid, uid); assert.deepEqual(activities[0][1].createdAt, commitTime);
  assert.equal(f.transforms.timestamps, 1);
  if (name === 'create') {
    const item = f.store.snapshot()['cafes/cafe/inventory/' + response.body.itemId];
    assert.equal(item.quantity, 4); assert.equal(item.schemaVersion, 1); assert.deepEqual(item.expiryDate, new Date(createData.expiryDate));
    assert.equal(rows(f, 'inventory_movements').length, 1); assert.equal(f.transforms.dates, 1);
  }
  if (name === 'adjust-stock') {
    assert.equal(f.store.snapshot()['cafes/cafe/inventory/item'].quantity, 7);
    assert.equal(rows(f, 'inventory_movements').length, 1);
  }
});

test('newly created item retains canonical initial-version stock compatibility', async () => {
  const f = fixture(); const created = await f.call('/inventory/create', createData);
  const adjusted = await f.call('/inventory/adjust-stock', {...stockData, itemId: created.body.itemId});
  assert.equal(adjusted.status, 200);
  const row = f.store.snapshot()['cafes/cafe/inventory/' + created.body.itemId];
  assert.equal(row.version, 2); assert.equal(row.quantity, 6);
  assert.equal(rows(f, 'inventory_movements').length, 2);
});

test('archive then restore deletes both archive fields and preserves stock and expiry', async () => {
  const f = fixture(); const expiry = f.store.snapshot()['cafes/cafe/inventory/item'].expiryDate;
  assert.equal((await f.call('/inventory/lifecycle', lifecycleData)).status, 200);
  const archived = f.store.snapshot()['cafes/cafe/inventory/item'];
  assert.deepEqual(archived.archivedAt, commitTime); assert.equal(archived.archivedBy, 'owner');
  const restored = await f.call('/inventory/lifecycle', {...lifecycleData, expectedVersion: 2, action: 'restore', idempotencyKey: 'restore-request-0001'});
  assert.equal(restored.status, 200);
  const row = f.store.snapshot()['cafes/cafe/inventory/item'];
  assert.equal(Object.hasOwn(row, 'archivedAt'), false); assert.equal(Object.hasOwn(row, 'archivedBy'), false);
  assert.equal(row.lifecycleState, 'active'); assert.equal(row.version, 3); assert.equal(row.quantity, 5);
  assert.deepEqual(row.expiryDate, expiry); assert.equal(f.transforms.deletes, 2);
  assert.equal(rows(f, 'activities').length, 2);
});

for (const path of ['/staff/create', '/staff/reconcile', '/inventory/list', '/inventory/read', '/menu/create', '/ai/issue', '/inventory/create?x=1']) {
  test(`inventory route isolation: ${path}`, async () => {
    const f = fixture(); assert.equal((await f.call(path, createData)).status, 404); assert.equal(f.store.transactions, 0);
  });
}
test('method content type malformed JSON and UTF-8/body bounds fail before domain', async () => {
  const f = fixture();
  assert.equal((await f.call('/inventory/create', createData, {method: 'GET'})).status, 405);
  assert.equal((await f.call('/inventory/create', createData, {headers: {'content-type': 'text/plain'}})).status, 400);
  for (const raw of ['{', '[]', 'null', '"scalar"']) assert.equal((await f.call('/inventory/create', null, {raw})).status, 400);
  assert.equal((await f.call('/inventory/create', null, {raw: 'x'.repeat(4097)})).status, 413);
  assert.equal((await f.call('/inventory/create', null, {raw: new Uint8Array([0xff])})).status, 400);
  assert.equal(f.store.transactions, 0);
});
test('inventory body limit supports a valid long image URL without widening invitation limit', async () => {
  const f = fixture();
  const imageUrl = 'https://example.invalid/' + 'a'.repeat(1980);
  const response = await f.call('/inventory/create', {...createData, imageUrl});
  assert.equal(response.status, 200);
});

for (const kind of ['missing', 'forged', 'expired', 'wrong-project', 'disabled', 'revoked']) test(`inventory identity ${kind} denied`, async () => {
  const f = fixture();
  if (kind === 'disabled') f.accounts.owner.disabled = true;
  if (kind === 'revoked') f.accounts.owner.tokensValidAfterTime = '2099-01-01T00:00:00Z';
  const parts = f.token().split('.'); const signature = Buffer.from(parts[2], 'base64url'); signature[0] ^= 1;
  const token = kind === 'forged' ? [parts[0], parts[1], signature.toString('base64url')].join('.') :
    f.token('owner', kind === 'expired' ? {exp: 1} : kind === 'wrong-project' ? {aud: 'velora-73222'} : {});
  assert.equal((await f.call('/inventory/create', createData, {token, headers: kind === 'missing' ? {authorization: ''} : {}})).status, 401);
  assert.equal(f.store.transactions, 0);
});

for (const [name, data] of operations) {
  test(`${name} rejects outsider, stale and cross-workspace contexts without writes`, async () => {
    const f = fixture(); const before = f.store.snapshot();
    assert.equal((await f.call('/inventory/' + name, data, {uid: 'outsider'})).status, 403);
    for (const change of [{expectedCafeId: 'other'}, {expectedMembershipGeneration: 1}]) {
      const r = await f.call('/inventory/' + name, {...data, ...change});
      assert.deepEqual(r, {status: 409, body: {error: 'aborted'}});
    }
    assert.deepEqual(f.store.snapshot(), before);
  });
  test(`${name} idempotent replay and conflicting key never duplicate audits`, async () => {
    const f = fixture(); assert.equal((await f.call('/inventory/' + name, data)).status, 200);
    const before = f.store.snapshot(); assert.equal((await f.call('/inventory/' + name, data)).status, 200);
    assert.deepEqual(f.store.snapshot(), before);
    const conflict = name === 'create' || name === 'update' ? {name: 'Different name'} :
      name === 'adjust-stock' ? {quantity: 1} : {action: 'restore'};
    assert.equal((await f.call('/inventory/' + name, {...data, ...conflict})).status, 409);
    assert.deepEqual(f.store.snapshot(), before);
  });
  test(`${name} rejects forged authority or missing context`, async () => {
    const f = fixture(); const before = f.store.snapshot();
    assert.equal((await f.call('/inventory/' + name, {...data, actorUid: 'owner'})).status, 400);
    const {expectedMembershipGeneration, ...missing} = data;
    assert.equal((await f.call('/inventory/' + name, missing)).status, 400);
    assert.deepEqual(f.store.snapshot(), before);
  });
  for (const failAtWrite of (name === 'create' || name === 'adjust-stock' ? [1, 2, 3] : [1, 2])) test(`${name} rollback at write ${failAtWrite}`, async () => {
    const f = fixture(); f.store.failAtWrite = failAtWrite; const before = f.store.snapshot();
    const response = await f.call('/inventory/' + name, data);
    assert.deepEqual(response, {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
    assert.deepEqual(f.store.snapshot(), before); assert.equal(f.store.transactions, 1);
  });
  for (const applied of [false, true]) test(`${name} unknown commit applied=${applied} never replays`, async () => {
    const f = fixture(); f.store.failCommit = !applied; f.store.appliedLost = applied;
    const before = f.store.snapshot(); const response = await f.call('/inventory/' + name, data);
    assert.deepEqual(response, {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
    assert.equal(f.store.transactions, 1); assert.equal(JSON.stringify(response).includes('SENSITIVE'), false);
    if (!applied) assert.deepEqual(f.store.snapshot(), before);
    else assert.equal(rows(f, 'activities').length, 1);
  });
}
test('stock underflow, version conflict and metadata quantity edit leave state unchanged', async () => {
  const f = fixture(); const before = f.store.snapshot();
  assert.deepEqual(await f.call('/inventory/adjust-stock', {...stockData, direction: 'out', quantity: 6}),
    {status: 409, body: {error: 'failed-precondition', reason: 'insufficient-stock'}});
  assert.equal((await f.call('/inventory/update', {...updateData, expectedVersion: 2})).status, 409);
  assert.equal((await f.call('/inventory/update', {...updateData, quantity: 10})).status, 400);
  assert.deepEqual(f.store.snapshot(), before);
});

test('canonical overflow is a definite pre-write rejection with no state change', async () => {
  const f = fixture();
  f.store.records.get('cafes/cafe/inventory/item').quantity = Number.MAX_SAFE_INTEGER;
  const before = f.store.snapshot();
  assert.deepEqual(await f.call('/inventory/adjust-stock', stockData),
    {status: 409, body: {error: 'out-of-range'}});
  assert.deepEqual(f.store.snapshot(), before);
  assert.equal(f.store.transactions, 1);
});

for (const [name, error, body] of [
  ['arbitrary reason', new stockDomain.InventoryStockError('failed-precondition', 'SECRET', 'SECRET'), {error: 'failed-precondition'}],
  ['wrong domain type', Object.assign(new updateDomain.InventoryUpdateError('failed-precondition', 'SECRET'), {reason: 'insufficient-stock'}), {error: 'failed-precondition'}],
  ['wrong code', new stockDomain.InventoryStockError('out-of-range', 'SECRET', 'insufficient-stock'), {error: 'out-of-range'}],
  ['uncertain domain error', Object.assign(new stockDomain.InventoryStockError('failed-precondition', 'SECRET', 'insufficient-stock'), {uncertain: true}), {error: 'unavailable', outcomeUnknown: true}],
  ['untrusted store error', Object.assign(Error('SECRET'), {code: 'failed-precondition', reason: 'insufficient-stock'}), {error: 'unavailable', outcomeUnknown: true}],
]) test(`public error reason excludes ${name}`, async () => {
  const f = fixture(); f.store.runTransaction = async () => {throw error;};
  const result = await f.call('/inventory/adjust-stock', stockData);
  assert.deepEqual(result, {status: body.outcomeUnknown ? 503 : 409, body});
  assert.equal(JSON.stringify(result).includes('SECRET'), false);
});
test('concurrent HTTP stock duplicates commit only one movement and activity', async () => {
  const f = fixture();
  const responses = await Promise.all([f.call('/inventory/adjust-stock', stockData), f.call('/inventory/adjust-stock', stockData)]);
  assert.ok(responses.every(r => r.status === 200));
  assert.equal(f.store.snapshot()['cafes/cafe/inventory/item'].quantity, 7);
  assert.equal(rows(f, 'inventory_movements').length, 1); assert.equal(rows(f, 'activities').length, 1);
});
test('expiry metadata update uses the injected date conversion without touching quantity', async () => {
  const f = fixture();
  const expiryDate = '2031-04-03T00:00:00.000Z';
  assert.equal((await f.call('/inventory/update', {...updateData, expiryDate})).status, 200);
  const row = f.store.snapshot()['cafes/cafe/inventory/item'];
  assert.deepEqual(row.expiryDate, new Date(expiryDate)); assert.equal(row.quantity, 5);
  assert.equal(f.transforms.dates, 1);
});

function timers() {
  const pending = [];
  return {scheduleTimeout(callback, ms) {const t = {callback, ms, active: true}; pending.push(t); return () => {t.active = false;};},
    fire(ms) {const t = pending.find(t => t.active && t.ms === ms); assert.ok(t); t.active = false; t.callback();},
    active: () => pending.filter(t => t.active).length};
}
const deferred = () => {let resolve, reject; const promise = new Promise((yes, no) => {resolve = yes; reject = no;}); return {promise, resolve, reject};};
const flush = () => new Promise(resolve => setImmediate(resolve));
for (const lateReject of [false, true]) test(`inventory verifier deadline blocks late dispatch, rejection=${lateReject}`, async () => {
  const timer = timers(), pending = deferred(), entered = deferred();
  const f = fixture({...timer, verificationTimeoutMs: 19, verifyIdentity: () => {entered.resolve(); return pending.promise;}});
  const result = f.call('/inventory/create', createData); await entered.promise; timer.fire(19);
  assert.deepEqual(await result, {status: 408, body: {error: 'deadline-exceeded'}});
  if (lateReject) pending.reject(Error('SENSITIVE')); else pending.resolve({uid: 'owner', token: f.claims('owner')});
  await flush(); assert.equal(f.store.transactions, 0); assert.equal(timer.active(), 0);
});

for (const [operation, request] of operations) test(`reconcile ${operation} is authenticated, minimal and read-only`, async () => {
  const f = fixture();
  const original = await f.call('/inventory/' + operation, request);
  assert.equal(original.status, 200);
  const before = f.store.snapshot();
  assert.deepEqual(await f.call('/inventory/reconcile', {operation, request}),
    {status: 200, body: {state: 'committed', result: original.body}});
  assert.deepEqual(f.store.snapshot(), before);
  assert.equal(f.transforms.timestamps, 1);
});

test('reconcile absence is unknown, malformed envelopes and stale authority fail closed', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'create', request: createData}),
    {status: 200, body: {state: 'unknown'}});
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'create', request: createData, receiptPath: 'arbitrary'}),
    {status: 400, body: {error: 'invalid-argument'}});
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'create', request: {...createData, expectedCafeId: 'other'}}),
    {status: 409, body: {error: 'aborted'}});
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'create', request: createData}, {uid: 'outsider'}),
    {status: 403, body: {error: 'permission-denied'}});
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'create', request: createData}, {token: 'invalid'}),
    {status: 401, body: {error: 'unauthenticated'}});
});

test('reconcile read/store failure keeps existing sanitized uncertainty envelope', async () => {
  const f = fixture(); f.store.failCommit = true;
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'create', request: createData}),
    {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
});

test('reconcile wraps a maximum-sized valid original request without widening mutation limits', async () => {
  const f = fixture();
  const original = {...createData, imageUrl: ''};
  const available = 4096 - Buffer.byteLength(JSON.stringify(original));
  original.imageUrl = 'é'.repeat(Math.floor(available / 2)) + 'a'.repeat(available % 2);
  assert.equal(Buffer.byteLength(JSON.stringify(original)), 4096);
  assert.ok(original.imageUrl.length <= 2048);
  const result = await f.call('/inventory/create', original);
  assert.equal(result.status, 200);
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'create', request: original}),
    {status: 200, body: {state: 'committed', result: result.body}});
  assert.deepEqual(await f.call('/inventory/reconcile', {}, {raw: ' '.repeat(4161)}),
    {status: 413, body: {error: 'too-large'}});
  assert.deepEqual(await f.call('/inventory/create', {}, {raw: ' '.repeat(4097)}),
    {status: 413, body: {error: 'too-large'}});
});
test('inventory body deadline and stalled reader cleanup prevent any domain dispatch', async () => {
  const timer = timers(), entered = deferred(), read = deferred(), cancelled = deferred();
  const f = fixture({...timer, bodyTimeoutMs: 23, cleanupTimeoutMs: 11});
  const result = f.handler({url: 'https://offline.invalid/inventory/create', method: 'POST',
    headers: new Headers({'content-type': 'application/json', authorization: 'Bearer ' + f.token()}),
    body: {getReader: () => ({read: () => {entered.resolve(); return read.promise;},
      cancel: () => {cancelled.resolve(); return new Promise(() => {});}})}});
  await entered.promise; timer.fire(23); await cancelled.promise; await flush(); timer.fire(11);
  const response = await result; assert.equal(response.status, 408);
  read.resolve({done: false, value: new TextEncoder().encode(JSON.stringify(createData))});
  await flush(); assert.equal(f.store.transactions, 0); assert.equal(timer.active(), 0);
});
