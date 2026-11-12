import test from 'node:test';
import assert from 'node:assert/strict';
import {createGoogleHttp} from '../backend/google-http.mjs';
import {createFirestoreStore, FirestoreStoreError} from '../backend/firestore-store.mjs';
import {BackendError} from '../backend/backend-errors.mjs';
import {createRestFake} from './helpers/shared-firestore-rest-fake.cjs';
import creation from '../src/inventory-create.js';
import update from '../src/inventory-update.js';
import stock from '../src/inventory-stock.js';
import lifecycle from '../src/inventory-lifecycle.js';
import menu from '../src/menu-service.js';
import menuModel from '../src/menu-model.js';
import team from '../src/team-members.js';
import savedRecipes from '../src/saved-recipe-service.js';
import savedRecipeModel from '../src/saved-recipe-model.js';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const bind = fn => Object.assign(fn, {projectId});
const root = `projects/${projectId}/databases/(default)/documents`;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function seed({generation = 0, cafeId = 'cafe'} = {}) {
  const records = {[`cafes/${cafeId}`]: {ownerUid: 'owner', status: 'active', schemaVersion: 1}};
  for (const uid of ['owner', 'staff']) {
    const link = {uid, cafeId, status: 'active', schemaVersion: 1, membershipGeneration: generation};
    records[`user_cafe_memberships/${uid}`] = link;
    records[`cafes/${cafeId}/members/${uid}`] = {...link, role: uid};
  }
  records[`cafes/${cafeId}/inventory/item`] = {cafeId, name: 'Rice', category: 'Dry', quantity: 5,
    unit: 'kg', version: 1, schemaVersion: 1, expiryDate: new Date('2030-01-02T00:00:00Z')};
  return records;
}
function fixture(records = seed(), overrides = {}) {
  const fake = createRestFake(records), sleeps = [];
  const http = createGoogleHttp({projectId, transport: fake.transport});
  const options = {projectId, http, accessToken: bind(async () => 'synthetic-access'),
    sleep: async ms => { sleeps.push(ms); }, random: () => 0.5, ...overrides};
  return {fake, sleeps, options, store: createFirestoreStore(options)};
}
const commits = f => f.fake.calls.filter(call => call.method === 'commit');
const begins = f => f.fake.calls.filter(call => call.method === 'beginTransaction');
const context = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const createData = {...context, idempotencyKey: 'create-request-0001', name: 'Rice', category: 'Dry', quantity: 2,
  unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'};
const stockData = {...context, itemId: 'item', idempotencyKey: 'stock-request-0001', expectedVersion: 1,
  direction: 'in', quantity: 2, reason: 'Delivery'};
const invokeCreate = (f, data = createData, uid = 'owner') => creation.createInventoryItem({auth: {uid}, data,
  store: f.store, timestamp: f.store.timestamp, toTimestamp: f.store.toTimestamp});
const invokeStock = (f, data = stockData) => stock.adjustInventoryStock({auth: {uid: 'owner'}, data,
  store: f.store, timestamp: f.store.timestamp});
const invokeLifecycle = (f, action, version) => lifecycle.setInventoryLifecycle({auth: {uid: 'owner'},
  data: {...context, itemId: 'item', action, expectedVersion: version, idempotencyKey: `${action}-request-0001`},
  store: f.store, timestamp: f.store.timestamp, deleteValue: f.store.deleteValue});
const storeFailure = unknown => error => error instanceof FirestoreStoreError && error.kind === 'store' &&
  error.outcomeUnknown === unknown && !JSON.stringify(error).includes('SYNTHETIC PRIVATE');

test('inert explicit project/database/credential binding, capabilities and no defaults', () => {
  const f = fixture();
  assert.equal(f.fake.calls.length, 0);
  assert.deepEqual(f.store.capabilities, {serverTimestamps: true, deleteFields: true});
  for (const patch of [{projectId: 'velora-73222'}, {databaseId: 'other'}, {http: async () => {}},
    {accessToken: Object.assign(async () => {}, {projectId: 'other'})}, {attempts: 4}, {timeoutMs: 20001}, {rpcTimeoutMs: 0}]) {
    assert.throws(() => createFirestoreStore({...f.options, ...patch}), BackendError);
  }
});

test('atomic native create/update/set/delete, patch masks and fixed transaction binding', async () => {
  const f = fixture({'cafes/cafe/inventory/a': {quantity: 5, keep: 'yes'}, 'cafes/cafe/inventory/d': {old: 1}});
  const result = await f.store.runTransaction(async tx => {
    assert.equal((await tx.get('cafes/cafe/inventory/a')).quantity, 5);
    tx.update('cafes/cafe/inventory/a', {quantity: 7, updatedAt: f.store.timestamp()});
    tx.create('cafes/cafe/inventory/b', {quantity: 1});
    tx.set('cafes/cafe/inventory/c', {replacement: true});
    tx.delete('cafes/cafe/inventory/d');
    return {ok: true};
  });
  assert.deepEqual(result, {ok: true});
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/a'].keep, 'yes');
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/a'].quantity, 7);
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/d'], undefined);
  const writes = commits(f)[0].body.writes;
  assert.deepEqual(writes[0].currentDocument, {exists: true});
  assert.deepEqual(writes[1].currentDocument, {exists: false});
  assert.equal(writes[2].updateMask, undefined);
  assert.ok(f.fake.calls.slice(1).every(call => call.body.transaction === commits(f)[0].body.transaction));
});

test('read-only transaction returns after zero-write commit, accepts omitted empty results', async () => {
  const f = fixture(), before = f.fake.snapshot();
  const result = await f.store.runTransaction(tx => tx.get('cafes/cafe/inventory/item'));
  assert.equal(result.quantity, 5);
  assert.deepEqual(commits(f)[0].body.writes, []);
  assert.deepEqual(f.fake.snapshot(), before);
  assert.equal(await f.store.runTransaction(tx => tx.get('cafes/cafe/inventory/missing')), null);
});

test('reads after writes, duplicate writes, unsupported operations and swallowed errors cannot commit', async () => {
  for (const action of [
    async tx => { tx.update('cafes/cafe/inventory/item', {quantity: 2}); await tx.get('cafes/cafe'); },
    async tx => { tx.update('cafes/cafe/inventory/item', {quantity: 2}); tx.update('cafes/cafe/inventory/item', {quantity: 3}); },
    async tx => { assert.throws(() => tx.update('cafes/cafe/inventory/item', {bad: undefined})); },
    async tx => { tx.increment('cafes/cafe/inventory/item'); },
    async tx => { tx.create('cafes/cafe/inventory/new', {x: 1}); await tx.members('cafe', 101); },
  ]) {
    const f = fixture(), before = f.fake.snapshot();
    await assert.rejects(f.store.runTransaction(action));
    assert.equal(commits(f).length, 0);
    assert.deepEqual(f.fake.snapshot(), before);
  }
});

test('closed transaction cannot be reused after callback or commit', async () => {
  const f = fixture(); let saved;
  await f.store.runTransaction(tx => { saved = tx; return 'done'; });
  assert.throws(() => saved.create('cafes/cafe/inventory/x', {x: 1}));
  await assert.rejects(saved.get('cafes/cafe'));
  assert.equal(commits(f).length, 1);
});

test('unawaited read poisons the attempt and late rejection is observed', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture(seed(), {rpcTimeoutMs: 30});
  f.fake.hooks.batchGet = async () => { await gate; throw Error('SECRET'); };
  await assert.rejects(f.store.runTransaction(tx => { tx.get('cafes/cafe'); }), storeFailure(false));
  release(); await delay(10);
  assert.equal(commits(f).length, 0);
});

test('staging writes during pending reads is rejected', async () => {
  const f = fixture();
  await assert.rejects(f.store.runTransaction(async tx => {
    const pending = tx.get('cafes/cafe');
    assert.throws(() => tx.create('cafes/cafe/inventory/new', {x: 1}), storeFailure(false));
    await pending;
  }), storeFailure(false));
  assert.equal(commits(f).length, 0);
});

for (const path of ['../x', 'cafes/..', 'cafes/cafe/inventory', 'cafes/cafe%2Fother', 'cafes/cafe\\other',
  'cafes/cafe\n', '/cafes/cafe', `${root}/cafes/cafe`, 'cafes/ cafe', 'cafes/%']) {
  test(`invalid resource path denied: ${JSON.stringify(path)}`, async () => {
    const f = fixture();
    await assert.rejects(f.store.runTransaction(tx => tx.get(path)), storeFailure(false));
    assert.equal(f.fake.calls.filter(call => call.method === 'batchGet').length, 0);
    assert.equal(commits(f).length, 0);
  });
}

for (const uid of ['owner', 'staff']) test(`canonical ${uid} create and replay use one item and atomic audits`, async () => {
  const f = fixture();
  const first = await invokeCreate(f, createData, uid), replay = await invokeCreate(f, createData, uid);
  assert.equal(first.created, true); assert.equal(replay.created, false); assert.equal(replay.itemId, first.itemId);
  const records = f.fake.snapshot();
  assert.equal(Object.keys(records).filter(path => path.includes('/inventory_movements/')).length, 1);
  assert.equal(Object.keys(records).filter(path => path.includes('/activities/')).length, 1);
  assert.equal(records[`cafes/cafe/inventory/${first.itemId}`].createdBy, uid);
  assert.equal(records[`cafes/cafe/inventory/${first.itemId}`].createdAt.toISOString(), '2026-11-11T00:00:00.123Z');
  assert.equal(commits(f)[0].body.writes.length, 3);
  await assert.rejects(invokeCreate(f, {...createData, quantity: 3}, uid), {code: 'already-exists'});
  assert.equal(commits(f).length, 2);
});

test('canonical stock replay retains historical arithmetic after subsequent stock movement', async () => {
  const f = fixture();
  const first = await invokeStock(f);
  assert.equal(first.resultingQuantity, 7);
  await invokeStock(f, {...stockData, idempotencyKey: 'stock-request-0002', expectedVersion: 2, direction: 'out', quantity: 7});
  const replay = await invokeStock(f);
  assert.equal(replay.adjusted, false);
  assert.equal(replay.resultingQuantity, 7);
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 0);
  assert.equal(commits(f)[2].body.writes.length, 0);
});

for (const sameKey of [true, false]) test(`concurrent adjustments sameKey=${sameKey} cannot double-apply or lose audits`, async () => {
  const f = fixture();
  const results = await Promise.allSettled([invokeStock(f), invokeStock(f,
    sameKey ? stockData : {...stockData, idempotencyKey: 'stock-request-0002'})]);
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 7);
  assert.equal(Object.keys(f.fake.snapshot()).filter(path => path.includes('/inventory_movements/')).length, 1);
  assert.equal(Object.keys(f.fake.snapshot()).filter(path => path.includes('/activities/')).length, 1);
  if (sameKey) {
    assert.ok(results.every(result => result.status === 'fulfilled'));
    assert.equal(results.filter(result => result.value.adjusted).length, 1);
  } else {
    assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
    const failure = results.find(result => result.status === 'rejected').reason;
    assert.ok(failure instanceof stock.InventoryStockError);
    assert.equal(failure.code, 'aborted');
  }
});

test('explicit unchanged retry after applied-but-lost commit observes historical receipt without duplicate audits', async () => {
  const f = fixture(); f.fake.commitModes.push('applied-lost');
  await assert.rejects(invokeStock(f), storeFailure(true));
  assert.equal(commits(f).length, 1);
  const result = await invokeStock(f);
  assert.equal(result.adjusted, false);
  assert.equal(result.resultingQuantity, 7);
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 7);
  assert.equal(Object.keys(f.fake.snapshot()).filter(path => path.includes('/activities/')).length, 1);
});

test('archive/restore atomically deletes both fields, never null, preserving stock and expiry', async () => {
  const f = fixture(), before = f.fake.snapshot()['cafes/cafe/inventory/item'];
  await invokeLifecycle(f, 'archive', 1);
  assert.ok(f.fake.snapshot()['cafes/cafe/inventory/item'].archivedAt instanceof Date);
  await invokeLifecycle(f, 'restore', 2);
  const after = f.fake.snapshot()['cafes/cafe/inventory/item'];
  assert.equal(Object.hasOwn(after, 'archivedAt'), false);
  assert.equal(Object.hasOwn(after, 'archivedBy'), false);
  assert.equal(after.quantity, before.quantity);
  assert.deepEqual(after.expiryDate, before.expiryDate);
  assert.equal(after.version, 3);
  const write = commits(f)[1].body.writes.find(write => write.update.name.endsWith('/inventory/item'));
  assert.ok(write.updateMask.fieldPaths.includes('`archivedAt`'));
  assert.ok(write.updateMask.fieldPaths.includes('`archivedBy`'));
  assert.equal(Object.hasOwn(write.update.fields, 'archivedAt'), false);
  assert.equal(Object.hasOwn(write.update.fields, 'archivedBy'), false);
  assert.ok(write.updateTransforms.some(transform => transform.setToServerValue === 'REQUEST_TIME'));
});

test('canonical metadata updates preserve quantities and optimistic versions', async () => {
  const f = fixture();
  const result = await update.updateInventoryItem({auth: {uid: 'owner'}, store: f.store, timestamp: f.store.timestamp,
    toTimestamp: f.store.toTimestamp, data: {...context, itemId: 'item', expectedVersion: 1,
      idempotencyKey: 'update-request-0001', name: 'New rice'}});
  assert.equal(result.version, 2);
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 5);
});

for (const [name, data, expected] of [
  ['wrong workspace', {...stockData, expectedCafeId: 'other'}, 'aborted'],
  ['stale generation', {...stockData, expectedMembershipGeneration: 1}, 'aborted'],
  ['stale version', {...stockData, expectedVersion: 2}, 'aborted'],
  ['insufficient stock', {...stockData, direction: 'out', quantity: 6}, 'failed-precondition'],
]) test(`canonical ${name} remains typed, definite and is never retried`, async () => {
  const f = fixture(), before = f.fake.snapshot();
  await assert.rejects(invokeStock(f, data), error => error instanceof stock.InventoryStockError &&
    error.code === expected && (name !== 'insufficient stock' || error.reason === 'insufficient-stock'));
  assert.equal(begins(f).length, 1);
  assert.equal(commits(f).length, 0);
  assert.deepEqual(f.fake.snapshot(), before);
});

test('missing/invalid membership denies using canonical source and zero commit', async () => {
  for (const patch of [undefined, {uid: 'owner', cafeId: 'cafe', status: 'removed', schemaVersion: 1},
    {uid: 'owner', cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: 9}]) {
    const f = fixture(); f.fake.replace('user_cafe_memberships/owner', patch);
    await assert.rejects(invokeStock(f), error => error instanceof stock.InventoryStockError);
    assert.equal(commits(f).length, 0);
  }
});

test('only native definite abort retries, with stable IDs and reread authority', async () => {
  const f = fixture(); f.fake.commitModes.push('abort');
  const result = await invokeCreate(f);
  assert.equal(result.created, true);
  assert.equal(begins(f).length, 2);
  assert.deepEqual(commits(f)[0].body.writes, commits(f)[1].body.writes);
  assert.deepEqual(f.sleeps, [60]);
  assert.equal(Object.keys(f.fake.snapshot()).filter(path => path.includes('/activities/')).length, 1);
});

for (const changed of ['membership', 'version']) test(`native abort rereads changed ${changed} and preserves domain rejection`, async () => {
  const f = fixture(); let once = false;
  f.fake.hooks.commit = () => {
    if (once) return;
    once = true;
    if (changed === 'membership') {
      for (const path of ['user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
        f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 1});
      }
    } else f.fake.replace('cafes/cafe/inventory/item', {...f.fake.snapshot()['cafes/cafe/inventory/item'], version: 2});
    return f.fake.nativeError(409, 'ABORTED');
  };
  await assert.rejects(invokeStock(f), error => error instanceof stock.InventoryStockError && error.code === 'aborted');
  assert.equal(begins(f).length, 2);
  assert.equal(commits(f).length, 1);
});

test('contention exhaustion is a store failure, never a canonical version conflict', async () => {
  const f = fixture(); f.fake.commitModes.push('abort', 'abort', 'abort');
  await assert.rejects(invokeStock(f), error => storeFailure(false)(error) && error.code === 'contention-exhausted');
  assert.equal(begins(f).length, 3);
  assert.equal(commits(f).length, 3);
  assert.equal(f.sleeps.length, 2);
});

for (const mode of ['lost', 'applied-lost', 'malformed', 'bad-transform']) {
  test(`commit ${mode} stays unknown, without callback retry or rollback`, async () => {
    const f = fixture(); f.fake.commitModes.push(mode);
    await assert.rejects(invokeStock(f), error => storeFailure(true)(error) && error.phase === 'unknown');
    assert.equal(begins(f).length, 1);
    assert.equal(commits(f).length, 1);
    assert.equal(f.fake.calls.filter(call => call.method === 'rollback').length, 0);
    assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, mode === 'lost' ? 5 : 7);
  });
}

test('native definite rejection has distinct provenance, no callback replay', async () => {
  const f = fixture(); f.fake.commitModes.push('reject');
  await assert.rejects(invokeStock(f), error => storeFailure(false)(error) && error.code === 'native-rejected');
  assert.equal(begins(f).length, 1);
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 5);
});

for (const error of [Object.assign(Error('SECRET'), {code: 'aborted', uncertain: false}),
  new FirestoreStoreError('contention'), new stock.InventoryStockError('aborted', 'SECRET')]) {
  test(`dependency exception cannot forge a definite abort: ${error.constructor.name}`, async () => {
    const f = fixture();
    f.fake.hooks.commit = () => { throw error; };
    await assert.rejects(invokeStock(f), storeFailure(true));
    assert.equal(begins(f).length, 1);
    assert.equal(commits(f).length, 1);
  });
}

for (const [status, response] of [[409, {error: {status: 'ABORTED'}}],
  [500, {error: {code: 500, status: 'ABORTED'}}], [409, {error: {code: 403, status: 'ABORTED'}}],
  [503, {error: {code: 503, status: 'UNAVAILABLE'}}]]) {
  test(`unproven commit error ${status}/${JSON.stringify(response)} stays unknown`, async () => {
    const f = fixture(); f.fake.hooks.commit = () => f.fake.json(response, status);
    await assert.rejects(invokeStock(f), storeFailure(true));
    assert.equal(begins(f).length, 1);
    assert.equal(f.fake.calls.filter(call => call.method === 'rollback').length, 0);
  });
}

for (const malformed of ['missing-time', 'missing-results', 'wrong-count', 'bad-update-time', 'null-result',
  'missing-transform', 'bad-transform', 'extra-field']) {
  test(`malformed commit acknowledgement ${malformed} cannot publish success`, async () => {
    const f = fixture();
    f.fake.hooks.commit = ({body}) => {
      const data = {commitTime: f.fake.instant, writeResults: body.writes.map(write => ({updateTime: f.fake.instant,
        transformResults: (write.updateTransforms ?? []).map(() => ({timestampValue: f.fake.instant}))}))};
      if (malformed === 'missing-time') delete data.commitTime;
      if (malformed === 'missing-results') delete data.writeResults;
      if (malformed === 'wrong-count') data.writeResults.pop();
      if (malformed === 'bad-update-time') data.writeResults[0].updateTime = 'invalid';
      if (malformed === 'null-result') data.writeResults[0] = null;
      if (malformed === 'missing-transform') delete data.writeResults[0].transformResults;
      if (malformed === 'bad-transform') data.writeResults[0].transformResults = [{integerValue: '1'}];
      if (malformed === 'extra-field') data.extra = true;
      return f.fake.json(data);
    };
    await assert.rejects(invokeStock(f), error => storeFailure(true)(error) && error.code === 'invalid-acknowledgement');
    assert.equal(begins(f).length, 1);
  });
}

test('native create/update/delete preconditions reject atomically without upsert or partial writes', async () => {
  for (const kind of ['create', 'update', 'delete']) {
    const f = fixture(), before = f.fake.snapshot();
    await assert.rejects(f.store.runTransaction(tx => {
      tx.create('cafes/cafe/inventory/first', {quantity: 1});
      const path = kind === 'create' ? 'cafes/cafe/inventory/item' : 'cafes/cafe/inventory/missing';
      if (kind === 'delete') tx.delete(path); else tx[kind](path, {quantity: 1});
    }), error => storeFailure(false)(error) && error.code === 'native-rejected');
    assert.deepEqual(f.fake.snapshot(), before);
    assert.equal(begins(f).length, 1);
  }
});

test('arbitrary domain error object preserved despite rollback errors/stalls', async () => {
  for (const mode of ['throw', 'stall']) {
    const f = fixture({}, {cleanupTimeoutMs: 10}), original = new stock.InventoryStockError('aborted', 'domain detail');
    f.fake.hooks.rollback = () => { if (mode === 'throw') throw Error('SECRET'); return new Promise(() => {}); };
    await assert.rejects(f.store.runTransaction(() => { throw original; }), error => error === original);
    assert.equal(begins(f).length, 1);
    assert.equal(commits(f).length, 0);
  }
});

test('commit credential stall is definite precommit and cannot dispatch after timeout', async () => {
  let calls = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({}, {rpcTimeoutMs: 15, timeoutMs: 60, cleanupTimeoutMs: 10,
    accessToken: bind(async () => { if (++calls === 2) await gate; return 'synthetic-access'; })});
  await assert.rejects(f.store.runTransaction(tx => tx.create('cafes/cafe/inventory/new', {x: 1})), storeFailure(false));
  assert.equal(commits(f).length, 0);
  release(); await delay(10);
  assert.equal(commits(f).length, 0);
});

for (const phase of ['precommit', 'commit']) test(`clock dependency failure during ${phase} is sanitized with correct uncertainty`, async () => {
  let failed = phase === 'precommit';
  const f = fixture(seed(), {now: () => { if (failed) throw Error('SECRET'); return 100000; }});
  if (phase === 'commit') f.fake.hooks.commit = () => { failed = true; return f.fake.json({}); };
  await assert.rejects(invokeStock(f), error => storeFailure(phase === 'commit')(error) &&
    error.code === 'invalid-clock' && !String(error).includes('SECRET'));
});

for (const begin of [{}, {transaction: ''}, {transaction: 'not base64'}, {transaction: null}]) {
  test(`malformed transaction identifier ${JSON.stringify(begin)} fails closed`, async () => {
    const f = fixture(); f.fake.hooks.beginTransaction = () => f.fake.json(begin);
    let callbacks = 0;
    await assert.rejects(f.store.runTransaction(() => { callbacks++; }), storeFailure(false));
    assert.equal(callbacks, 0);
    assert.equal(commits(f).length, 0);
  });
}

for (const dependency of ['sleep', 'random']) test(`backoff dependency ${dependency} failures are sanitized store errors`, async () => {
  const f = fixture(seed(), {[dependency]: () => { throw Error('SECRET'); }});
  f.fake.commitModes.push('abort');
  await assert.rejects(invokeStock(f), error => storeFailure(false)(error) && error.code === 'backoff-failed' &&
    error.cause === undefined && !String(error).includes('SECRET'));
  assert.equal(begins(f).length, 1);
});

for (const kind of ['empty', 'duplicate', 'cross-project', 'wrong-item', 'both', 'transaction', 'unsafe', 'metadata']) {
  test(`rejects malformed transactional read: ${kind}`, async () => {
    const f = fixture();
    f.fake.hooks.batchGet = ({body}) => {
      const row = {found: f.fake.doc('cafes/cafe/inventory/item', {quantity: 5})};
      if (kind === 'empty') return f.fake.json([]);
      if (kind === 'duplicate') return f.fake.json([row, row]);
      if (kind === 'cross-project') row.found.name = row.found.name.replace(projectId, 'other');
      if (kind === 'wrong-item') row.found.name += 'other';
      if (kind === 'both') row.missing = body.documents[0];
      if (kind === 'transaction') row.transaction = 'wrong-transaction';
      if (kind === 'unsafe') row.found.fields.quantity = {integerValue: '9007199254740992'};
      if (kind === 'metadata') row.found.updateTime = 'bad';
      return f.fake.json([row]);
    };
    await assert.rejects(f.store.runTransaction(tx => tx.get('cafes/cafe/inventory/item')), storeFailure(false));
    assert.equal(commits(f).length, 0);
  });
}

test('parent-scoped members/inventory queries preserve 101-row overflow evidence and cafe spaces', async () => {
  const records = seed({cafeId: 'cafe one'});
  for (let i = 0; i < 101; i++) records[`cafes/cafe one/members/m${String(i).padStart(3, '0')}`] = {uid: `m${i}`};
  const f = fixture(records);
  const result = await f.store.runTransaction(async tx => ({members: await tx.members('cafe one', 101),
    inventory: await tx.inventory('cafe one', 101)}));
  assert.equal(result.members.length, 101);
  assert.equal(result.inventory.length, 1);
  assert.ok(f.fake.calls.filter(call => call.method === 'runQuery').every(call => call.url.includes('/cafes/cafe%20one:runQuery')));
});

test('canonical roster retains 101-row overflow rejection before account enrichment', async () => {
  const records = seed();
  for (let i = 0; i < 101; i++) records[`cafes/cafe/members/x${i}`] = {uid: `x${i}`};
  const f = fixture(records);
  await assert.rejects(team.listTeamMembers({auth: {uid: 'owner'}, data: {}, store: f.store,
    accounts: () => { throw Error('account enrichment must not run'); }}),
  error => error instanceof team.TeamMembersError && error.code === 'resource-exhausted');
  assert.equal(commits(f).length, 0);
});

test('canonical menu list validates even the look-ahead document through the shared store', async () => {
  const f = fixture();
  for (const key of ['menu-request-0001', 'menu-request-0002']) {
    await menu.menuOperation({operation: 'create', auth: {uid: 'owner'}, store: f.store,
      timestamp: f.store.timestamp, data: {...context, idempotencyKey: key, name: 'Rice', category: 'Main',
        priceMinor: 500, isAvailable: true}});
  }
  const result = await menu.menuOperation({operation: 'list', auth: {uid: 'owner'}, store: f.store, data: {limit: 1}});
  assert.equal(result.items.length, 1);
  assert.equal(typeof result.nextCursor, 'string');
  const paths = Object.keys(f.fake.snapshot()).filter(path => path.includes('/menu_items/')).sort();
  f.fake.replace(paths[1], {...f.fake.snapshot()[paths[1]], priceMinor: -1});
  await assert.rejects(menu.menuOperation({operation: 'list', auth: {uid: 'owner'}, store: f.store, data: {limit: 1}}),
    error => error instanceof menuModel.MenuError && error.code === 'failed-precondition');
});

test('menu query preserves archived filter, cursor ordering and limit+1 look-ahead', async () => {
  const records = seed();
  for (const id of ['a', 'b', 'c', 'd']) records[`cafes/cafe/menu_items/${id}`] = {isArchived: id === 'c', name: id};
  const f = fixture(records);
  const rows = await f.store.runTransaction(tx => tx.menuItems('cafe', {includeArchived: false, limit: 1, cursor: 'a'}));
  assert.deepEqual(rows.map(row => row.id), ['b', 'd']);
  const q = f.fake.calls.find(call => call.method === 'runQuery').body.structuredQuery;
  assert.equal(q.limit, 2);
  assert.deepEqual(q.startAt, {values: [{referenceValue: `${root}/cafes/cafe/menu_items/a`}], before: false});
  const all = await f.store.runTransaction(tx => tx.menuItems('cafe', {includeArchived: true, limit: 2, cursor: null}));
  assert.deepEqual(all.map(row => row.id), ['a', 'b', 'c']);
});

for (const mode of ['cross-cafe', 'nested', 'duplicate', 'overflow', 'unsorted', 'look-ahead', 'cursor', 'archived']) {
  test(`rejects malformed/scoped query including ${mode}`, async () => {
    const f = fixture();
    f.fake.hooks.runQuery = () => {
      let paths = ['b', 'c'];
      if (mode === 'duplicate') paths = ['b', 'b'];
      if (mode === 'unsorted') paths = ['c', 'b'];
      if (mode === 'overflow') paths = ['b', 'c', 'd'];
      if (mode === 'cursor') paths = ['a', 'b'];
      const rows = paths.map(id => ({document: f.fake.doc(`cafes/cafe/menu_items/${id}`, {isArchived: false})}));
      if (mode === 'cross-cafe') rows[0].document.name = `${root}/cafes/other/menu_items/b`;
      if (mode === 'nested') rows[0].document.name += '/nested/item';
      if (mode === 'look-ahead') rows[1].document.fields.version = {integerValue: '9007199254740992'};
      if (mode === 'archived') rows[1].document.fields.isArchived = {booleanValue: true};
      return f.fake.json(rows);
    };
    await assert.rejects(f.store.runTransaction(tx => tx.menuItems('cafe', {includeArchived: false, limit: 1, cursor: 'a'})), storeFailure(false));
    assert.equal(commits(f).length, 0);
  });
}

for (const phase of ['credential', 'beginTransaction', 'batchGet', 'runQuery', 'callback', 'commit', 'backoff']) {
  test(`aggregate deadline bounds ${phase}, late work cannot dispatch/publish/retry`, async () => {
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    const f = fixture(seed(), {timeoutMs: 30, rpcTimeoutMs: 20, cleanupTimeoutMs: 5,
      ...(phase === 'credential' ? {accessToken: bind(async () => { await gate; return 'synthetic-access'; })} : {}),
      ...(phase === 'backoff' ? {sleep: () => gate} : {})});
    if (['beginTransaction', 'batchGet', 'runQuery', 'commit'].includes(phase)) f.fake.hooks[phase] = () => gate;
    if (phase === 'backoff') f.fake.commitModes.push('abort');
    const action = async tx => {
      if (phase === 'callback') { await gate; tx.create('cafes/cafe/inventory/new', {x: 1}); }
      else if (phase === 'runQuery') await tx.inventory('cafe', 101);
      else { await tx.get('cafes/cafe/inventory/item'); tx.update('cafes/cafe/inventory/item', {quantity: 7}); }
    };
    const start = Date.now();
    await assert.rejects(f.store.runTransaction(action), storeFailure(phase === 'commit'));
    assert.ok(Date.now() - start < 1000);
    const count = f.fake.calls.length;
    release(undefined); await delay(10);
    assert.equal(f.fake.calls.length, count);
    assert.equal(commits(f).length, ['commit', 'backoff'].includes(phase) ? 1 : 0);
  });
}

// Exercise the unchanged E2 domain through native-shaped REST transactions.
// Identity/account lookup is explicitly synthetic; no live Firebase is called.
function savedFixture(records = seed(), overrides = {}) {
  const f = fixture(records, overrides);
  f.accounts = new Map(['owner', 'staff', 'outsider'].map(uid => [uid, {uid, token: {
    sub: uid, aud: projectId, iss: `https://securetoken.google.com/${projectId}`, email_verified: true,
  }}]));
  const verifyIdentity = bind(async token => {
    const auth = f.accounts.get(token);
    if (!auth || auth.disabled || auth.revoked) throw Error('SYNTHETIC ACCOUNT REJECTION');
    return structuredClone(auth);
  });
  const domain = savedRecipes.createSavedRecipeService({projectId, store: f.store, verifyIdentity, timestamp: f.store.timestamp});
  f.recipes = (operation, data, token = 'owner') => domain({operation, token,
    data: operation === 'reconcile' ? data : {...context, ...data}});
  return f;
}
const savedInput = (key = 'saved-request-0001', title = 'Milk recipe') => ({idempotencyKey: key,
  recipe: {title, ingredients: [{itemId: 'milk', quantity: 0.125, unit: 'L'}], steps: ['Stir.'], whyRecommended: 'Uses stock.'},
  attribution: {kind: 'claimed-ai', provider: 'groq', ticketId: 'a'.repeat(64)}});
const savedLifecycle = (item, action = 'archive', key = 'saved-lifecycle-0001') => ({idempotencyKey: key,
  recipeId: item.recipeId, expectedVersion: item.version, action});
const savedFailure = (code, unknown = false) => error => error instanceof savedRecipeModel.SavedRecipeError &&
  error.code === code && error.outcomeUnknown === unknown && error.message === 'Saved recipes are unavailable.';
const savedPath = item => `cafes/cafe/saved_recipes/${item.recipeId}`;
const savedReceipt = item => `cafes/cafe/saved_recipe_requests/${item.requestHash}`;
const syntheticRecipeId = ch => 'recipe_' + ch.repeat(64);

for (const uid of ['owner', 'staff']) {
  test(`Saved Recipes ${uid} save/detail uses atomic scoped recipe and private receipt transforms`, async () => {
    const f = savedFixture(), before = f.fake.snapshot();
    assert.equal(f.fake.calls.length, 0);
    const ack = await f.recipes('save', savedInput(), uid);
    assert.equal(ack.outcome, 'created'); assert.equal(ack.changed, true);
    const commit = commits(f)[0];
    assert.equal(commit.body.writes.length, 2);
    assert.deepEqual(commit.body.writes.map(w => w.update.name), [f.fake.resource(savedPath(ack)), f.fake.resource(savedReceipt(ack))]);
    assert.ok(commit.body.writes.every(w => w.currentDocument.exists === false));
    assert.equal(commit.body.writes[0].updateMask, undefined);
    assert.deepEqual(commit.body.writes[0].updateTransforms.map(t => t.fieldPath), ['`createdAt`', '`updatedAt`']);
    assert.deepEqual(commit.body.writes[1].updateTransforms.map(t => t.fieldPath), ['`createdAt`']);
    const authReads = f.fake.calls.filter(c => c.method === 'batchGet').map(c => c.body.documents[0]);
    for (const path of [`user_cafe_memberships/${uid}`, `cafes/cafe/members/${uid}`, 'cafes/cafe',
      'user_cafe_memberships/owner', 'cafes/cafe/members/owner']) assert.ok(authReads.includes(f.fake.resource(path)));
    assert.ok(f.fake.calls.filter(c => c.method === 'batchGet').every(c => c.body.transaction === commit.body.transaction));
    const item = (await f.recipes('get', {recipeId: ack.recipeId}, uid)).item;
    assert.deepEqual(item.recipe, savedInput().recipe);
    assert.equal(item.createdAt, new Date(f.fake.instant).toISOString());
    assert.equal(item.createdBy, uid); assert.equal(item.provenanceEvidence, 'unverified-attribution');
    for (const [path, value] of Object.entries(before)) assert.deepEqual(f.fake.snapshot()[path], value);
    assert.equal(Object.keys(f.fake.snapshot()).length, Object.keys(before).length + 2);
  });
}

test('Saved Recipes replay and duplicate content preserve original record and attribution', async () => {
  const f = savedFixture(), first = await f.recipes('save', savedInput());
  const record = f.fake.snapshot()[savedPath(first)], writes = f.fake.snapshot();
  const replay = await f.recipes('save', savedInput());
  assert.deepEqual(replay, {...first, replayed: true});
  assert.deepEqual(commits(f).at(-1).body.writes, []); assert.deepEqual(f.fake.snapshot(), writes);
  const duplicate = await f.recipes('save', {...savedInput('duplicate-save-0001'),
    attribution: {kind: 'mock', provider: null, ticketId: null}}, 'staff');
  assert.equal(duplicate.outcome, 'existing-active'); assert.equal(duplicate.changed, false);
  assert.equal(commits(f).at(-1).body.writes.length, 1);
  assert.equal(commits(f).at(-1).body.writes[0].update.name, f.fake.resource(savedReceipt(duplicate)));
  assert.deepEqual(f.fake.snapshot()[savedPath(first)], record);
  const count = commits(f).length;
  await assert.rejects(f.recipes('save', savedInput('saved-request-0001', 'Changed')), savedFailure('already-exists'));
  assert.equal(commits(f).length, count);
});

test('Saved Recipes lifecycle patch masks preserve immutable content and restore explicit nulls', async () => {
  const f = savedFixture(), first = await f.recipes('save', savedInput());
  const original = f.fake.snapshot()[savedPath(first)];
  const archived = await f.recipes('lifecycle', savedLifecycle(first));
  assert.equal(archived.version, 2); assert.equal(archived.isArchived, true);
  const patch = commits(f).at(-1).body.writes[0];
  assert.deepEqual(patch.currentDocument, {exists: true});
  assert.deepEqual([...patch.updateMask.fieldPaths].sort(), ['`archivedBy`', '`isArchived`', '`updatedBy`', '`version`']);
  assert.deepEqual(patch.updateTransforms.map(t => t.fieldPath), ['`updatedAt`', '`archivedAt`']);
  assert.equal(patch.update.fields.recipe, undefined); assert.equal(patch.update.fields.createdBy, undefined);
  const doc = f.fake.snapshot()[savedPath(first)];
  assert.deepEqual(doc.recipe, original.recipe); assert.deepEqual(doc.createdAt, original.createdAt);
  assert.deepEqual(doc.archivedAt, doc.updatedAt); assert.equal(doc.archivedBy, 'owner');
  for (const action of ['archive', 'restore']) {
    const count = commits(f).length;
    await assert.rejects(f.recipes('lifecycle', savedLifecycle(archived, action, `staff-${action}-0001`), 'staff'), savedFailure('permission-denied'));
    assert.equal(commits(f).length, count);
  }
  const duplicate = await f.recipes('save', savedInput('archived-save-0001'), 'staff');
  assert.equal(duplicate.outcome, 'existing-archived');
  assert.equal((await f.recipes('get', {recipeId: first.recipeId}, 'staff')).item.isArchived, true);
  const restored = await f.recipes('lifecycle', savedLifecycle(archived, 'restore', 'restore-saved-0001'));
  assert.equal(restored.version, 3); assert.equal(restored.isArchived, false);
  const restorePatch = commits(f).at(-1).body.writes[0];
  assert.deepEqual(restorePatch.update.fields.archivedAt, {nullValue: null});
  assert.ok(restorePatch.updateMask.fieldPaths.includes('`archivedAt`'));
  assert.equal(f.fake.snapshot()[savedPath(first)].archivedBy, null);
  const beforeReplay = f.fake.snapshot();
  assert.deepEqual(await f.recipes('lifecycle', savedLifecycle(first)), {...archived, replayed: true});
  assert.deepEqual(f.fake.snapshot(), beforeReplay);
});

for (const reason of ['revoked', 'generation', 'owner-link', 'cross-cafe', 'unverified', 'wrong-project']) {
  test(`Saved Recipes ${reason} rejects before protected query/write`, async () => {
    const f = savedFixture();
    if (reason === 'unverified') f.accounts.get('staff').token.email_verified = false;
    else if (reason === 'wrong-project') f.accounts.get('staff').token.aud = 'velora-73222';
    else if (reason === 'owner-link') f.fake.replace('user_cafe_memberships/owner', {...f.fake.snapshot()['user_cafe_memberships/owner'], status: 'revoked'});
    else if (reason === 'revoked') f.fake.replace('cafes/cafe/members/staff', {...f.fake.snapshot()['cafes/cafe/members/staff'], status: 'revoked'});
    else if (reason === 'generation') {
      for (const p of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) f.fake.replace(p, {...f.fake.snapshot()[p], membershipGeneration: 1});
    }
    const before = f.fake.snapshot();
    const expectedCafeId = reason === 'cross-cafe' ? 'other' : 'cafe';
    await assert.rejects(f.recipes('save', {...savedInput(), expectedCafeId}, 'staff'),
      savedFailure(['unverified', 'wrong-project'].includes(reason) ? 'unauthenticated' : ['generation', 'cross-cafe'].includes(reason) ? 'aborted' : 'permission-denied'));
    assert.deepEqual(f.fake.snapshot(), before); assert.equal(commits(f).length, 0);
    assert.equal(f.fake.calls.filter(c => c.method === 'runQuery').length, 0);
  });
}

for (const change of ['generation', 'revocation']) {
  test(`Saved Recipes native abort rechecks ${change} and never retries a domain rejection`, async () => {
    const f = savedFixture(); let once = false;
    f.fake.hooks.commit = () => {
      if (once) return; once = true;
      if (change === 'revocation') f.fake.replace('cafes/cafe/members/staff', {...f.fake.snapshot()['cafes/cafe/members/staff'], status: 'revoked'});
      else for (const p of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) f.fake.replace(p, {...f.fake.snapshot()[p], membershipGeneration: 1});
    };
    await assert.rejects(f.recipes('save', savedInput(), 'staff'), savedFailure(change === 'revocation' ? 'permission-denied' : 'aborted'));
    assert.equal(begins(f).length, 2); assert.equal(commits(f).length, 1); assert.equal(f.sleeps.length, 1);
    assert.equal(Object.keys(f.fake.snapshot()).filter(p => p.includes('/saved_recipe')).length, 0);
  });
}

test('Saved Recipes concurrent content saves commit one content record and two receipts', async () => {
  const f = savedFixture();
  const result = await Promise.all([f.recipes('save', savedInput()), f.recipes('save', savedInput('concurrent-save-0001'), 'staff')]);
  assert.deepEqual(result.map(r => r.outcome).sort(), ['created', 'existing-active']);
  assert.equal(result[0].recipeId, result[1].recipeId);
  const paths = Object.keys(f.fake.snapshot());
  assert.equal(paths.filter(p => p.includes('/saved_recipes/')).length, 1);
  assert.equal(paths.filter(p => p.includes('/saved_recipe_requests/')).length, 2);
  assert.ok(f.sleeps.length >= 1);
});
test('Saved Recipes concurrent lifecycle operations cannot both change one version', async () => {
  const f = savedFixture(), first = await f.recipes('save', savedInput());
  const result = await Promise.allSettled([f.recipes('lifecycle', savedLifecycle(first)),
    f.recipes('lifecycle', savedLifecycle(first, 'archive', 'second-archive-0001'))]);
  assert.equal(result.filter(r => r.status === 'fulfilled').length, 1);
  assert.ok(savedFailure('aborted')(result.find(r => r.status === 'rejected').reason));
  assert.equal(f.fake.snapshot()[savedPath(first)].version, 2);
  assert.equal(Object.keys(f.fake.snapshot()).filter(p => p.includes('/saved_recipe_requests/')).length, 2);
});

for (const mode of ['active', 'archived', 'all']) {
  test(`Saved Recipes ${mode} query uses exact bound, filter-before-limit and parent cursor`, async () => {
    const records = seed({cafeId: 'cafe one'});
    for (const [i, ch] of ['a', 'b', 'c', 'd'].entries()) records[`cafes/cafe one/saved_recipes/${syntheticRecipeId(ch)}`] = {isArchived: i % 2 === 0};
    records[`cafes/other/saved_recipes/${syntheticRecipeId('e')}`] = {isArchived: false};
    const f = fixture(records);
    const rows = await f.store.runTransaction(tx => tx.savedRecipes('cafe one', {mode, limit: 2, afterId: syntheticRecipeId('a')}));
    assert.deepEqual(rows.map(r => r.id), (mode === 'active' ? ['b', 'd'] : mode === 'archived' ? ['c'] : ['b', 'c']).map(syntheticRecipeId));
    const call = f.fake.calls.find(c => c.method === 'runQuery'), q = call.body.structuredQuery;
    assert.ok(call.url.endsWith('/cafes/cafe%20one:runQuery'));
    assert.equal(q.limit, 2); assert.deepEqual(q.from, [{collectionId: 'saved_recipes'}]);
    assert.deepEqual(q.orderBy, [{field: {fieldPath: '__name__'}, direction: 'ASCENDING'}]);
    assert.deepEqual(q.startAt, {values: [{referenceValue: `${root}/cafes/cafe one/saved_recipes/${syntheticRecipeId('a')}`}], before: false});
    if (mode === 'all') assert.equal(q.where, undefined);
    else assert.deepEqual(q.where.fieldFilter.value, {booleanValue: mode === 'archived'});
    assert.deepEqual(commits(f)[0].body.writes, []);
  });
}

test('Saved Recipes domain pagination keeps the E1 look-ahead and scope-bound cursor', async () => {
  const f = savedFixture(), created = [];
  for (let i = 0; i < 3; i++) created.push(await f.recipes('save', savedInput(`saved-page-key-${i}00`, `Recipe ${i}`)));
  const ids = created.map(r => r.recipeId).sort();
  const first = await f.recipes('list', {mode: 'active', limit: 1, cursor: null});
  assert.equal(first.items[0].recipeId, ids[0]); assert.equal(first.items[0].recipe, undefined);
  assert.equal(first.nextCursor.afterId, ids[0]);
  assert.equal(f.fake.calls.filter(c => c.method === 'runQuery').at(-1).body.structuredQuery.limit, 2);
  const second = await f.recipes('list', {mode: 'active', limit: 1, cursor: first.nextCursor});
  assert.equal(second.items[0].recipeId, ids[1]);
  const last = await f.recipes('list', {mode: 'active', limit: 1, cursor: second.nextCursor});
  assert.equal(last.items[0].recipeId, ids[2]); assert.equal(last.nextCursor, null);
  for (const field of ['projectId', 'cafeId', 'uid', 'membershipGeneration', 'mode', 'limit']) {
    const count = f.fake.calls.filter(c => c.method === 'runQuery').length;
    const cursor = {...first.nextCursor, [field]: typeof first.nextCursor[field] === 'number' ? 2 : 'other'};
    await assert.rejects(f.recipes('list', {mode: 'active', limit: 1, cursor}), savedFailure('invalid-argument'));
    assert.equal(f.fake.calls.filter(c => c.method === 'runQuery').length, count);
  }
});

for (const input of [{mode: 'active', limit: 0, afterId: null}, {mode: 'all', limit: 22, afterId: null},
  {mode: 'all', limit: 1.5, afterId: null}, {mode: 'bad', limit: 1, afterId: null},
  {mode: 'active', limit: 1}, {mode: 'active', limit: 1, afterId: '../other'},
  {mode: 'active', limit: 1, afterId: null, collectionId: 'ai_recipe_suggestions'},
  {mode: 'all', limit: 1, afterId: `${root}/cafes/other/saved_recipes/${syntheticRecipeId('a')}`}]) {
  test(`Saved Recipes invalid adapter input poisons swallowed errors: ${JSON.stringify(input)}`, async () => {
    const f = fixture();
    await assert.rejects(f.store.runTransaction(tx => { assert.throws(() => tx.savedRecipes('cafe', input), storeFailure(false)); }), storeFailure(false));
    assert.equal(commits(f).length, 0); assert.equal(f.fake.calls.filter(c => c.method === 'runQuery').length, 0);
  });
}
test('Saved Recipes adapter accepts max 21 and detaches mutable input while waiting', async () => {
  const f = fixture(), input = {mode: 'active', limit: 21, afterId: null};
  const result = f.store.runTransaction(async tx => {
    const rows = tx.savedRecipes('cafe', input);
    input.mode = 'archived'; input.limit = 99; input.afterId = 'bad';
    return rows;
  });
  assert.deepEqual(await result, []);
  const q = f.fake.calls.find(c => c.method === 'runQuery').body.structuredQuery;
  assert.equal(q.limit, 21); assert.equal(q.where.fieldFilter.value.booleanValue, false); assert.equal(q.startAt, undefined);
});

for (const mode of ['foreign-cafe', 'foreign-project', 'nested', 'bad-id', 'duplicate', 'unsorted', 'overflow', 'cursor', 'filter', 'look-ahead-codec']) {
  test(`Saved Recipes rejects malformed native query ${mode} without commit`, async () => {
    const f = fixture();
    f.fake.hooks.runQuery = () => {
      let ids = ['b', 'c'];
      if (mode === 'duplicate') ids = ['b', 'b'];
      if (mode === 'unsorted') ids = ['c', 'b'];
      if (mode === 'overflow') ids = ['b', 'c', 'd'];
      if (mode === 'cursor') ids = ['a', 'b'];
      const rows = ids.map(ch => ({document: f.fake.doc(`cafes/cafe/saved_recipes/${syntheticRecipeId(ch)}`, {isArchived: false})}));
      if (mode === 'foreign-cafe') rows[0].document.name = `${root}/cafes/other/saved_recipes/${syntheticRecipeId('b')}`;
      if (mode === 'foreign-project') rows[0].document.name = rows[0].document.name.replace(projectId, 'velora-73222');
      if (mode === 'nested') rows[0].document.name += '/nested/child';
      if (mode === 'bad-id') rows[0].document.name = `${root}/cafes/cafe/saved_recipes/arbitrary`;
      if (mode === 'filter') rows[1].document.fields.isArchived = {booleanValue: true};
      if (mode === 'look-ahead-codec') rows[1].document.fields.version = {integerValue: '9007199254740992'};
      return f.fake.json(rows);
    };
    await assert.rejects(f.store.runTransaction(tx => tx.savedRecipes('cafe', {mode: 'active', limit: 2, afterId: syntheticRecipeId('a')})), storeFailure(false));
    assert.equal(commits(f).length, 0);
  });
}

test('Saved Recipes malformed full look-ahead record fails at domain boundary', async () => {
  const f = savedFixture();
  await f.recipes('save', savedInput()); await f.recipes('save', savedInput('second-saved-0001', 'Other recipe'));
  const paths = Object.keys(f.fake.snapshot()).filter(p => p.includes('/saved_recipes/')).sort();
  f.fake.replace(paths[1], {...f.fake.snapshot()[paths[1]], provenanceEvidence: 'verified-groq'});
  const count = commits(f).length;
  await assert.rejects(f.recipes('list', {mode: 'all', limit: 1, cursor: null}), savedFailure('failed-precondition'));
  assert.equal(commits(f).length, count);
});

for (const mode of ['lost', 'applied-lost', 'malformed', 'bad-transform']) {
  test(`Saved Recipes ${mode} commit is unknown; no retry; reconciliation remains read-only`, async () => {
    const f = savedFixture(); f.fake.commitModes.push(mode);
    await assert.rejects(f.recipes('save', savedInput()), savedFailure('unavailable', true));
    assert.equal(begins(f).length, 1); assert.equal(commits(f).length, 1); assert.equal(f.sleeps.length, 0);
    assert.equal(f.fake.calls.filter(c => c.method === 'rollback').length, 0);
    const before = f.fake.snapshot();
    const observed = await f.recipes('reconcile', {operation: 'save', request: {...context, ...savedInput()}});
    assert.equal(observed.status, mode === 'lost' ? 'unknown' : 'committed');
    assert.deepEqual(commits(f).at(-1).body.writes, []); assert.deepEqual(f.fake.snapshot(), before);
    if (mode !== 'lost') assert.equal(observed.result.replayed, true);
  });
}
test('Saved Recipes private receipt corruption cannot be reconciled as success', async () => {
  const f = savedFixture(), first = await f.recipes('save', savedInput());
  f.fake.replace(savedReceipt(first), {...f.fake.snapshot()[savedReceipt(first)], payloadHash: 'b'.repeat(64)});
  const before = f.fake.snapshot(), count = commits(f).length;
  await assert.rejects(f.recipes('reconcile', {operation: 'save', request: {...context, ...savedInput()}}), savedFailure('already-exists'));
  assert.deepEqual(f.fake.snapshot(), before); assert.equal(commits(f).length, count);
});
test('Saved Recipes commit precondition failure rolls back the fake draft atomically', async () => {
  const f = savedFixture();
  f.fake.hooks.commit = call => {
    // First recipe create is valid, second receipt create must fail. The fake
    // must discard the entire draft, rather than publish the first write.
    call.body.writes[1].currentDocument = {exists: true};
  };
  await assert.rejects(f.recipes('save', savedInput()), savedFailure('unavailable', true));
  assert.equal(Object.keys(f.fake.snapshot()).filter(p => p.includes('/saved_recipe')).length, 0);
  assert.equal(commits(f).length, 1);
});

test('Saved Recipes native index/query rejection is unavailable, never an empty page or automatic retry', async () => {
  const f = savedFixture();
  f.fake.hooks.runQuery = () => f.fake.nativeError(400, 'FAILED_PRECONDITION');
  await assert.rejects(f.recipes('list', {mode: 'active', limit: 20, cursor: null}), savedFailure('unavailable'));
  assert.equal(begins(f).length, 1); assert.equal(commits(f).length, 0); assert.equal(f.sleeps.length, 0);
});

test('Saved Recipes query uses existing closed/read-before-write transaction safeguards', async () => {
  const f = fixture(); let closed;
  await f.store.runTransaction(tx => { closed = tx; });
  await assert.rejects(closed.savedRecipes('cafe', {mode: 'all', limit: 1, afterId: null}), storeFailure(false));
  const count = commits(f).length;
  await assert.rejects(f.store.runTransaction(async tx => {
    tx.create(`cafes/cafe/saved_recipes/${syntheticRecipeId('a')}`, {isArchived: false});
    await tx.savedRecipes('cafe', {mode: 'all', limit: 1, afterId: null});
  }), storeFailure(false));
  assert.equal(commits(f).length, count);
  assert.equal(f.fake.calls.filter(c => c.method === 'runQuery').length, 0);
});
