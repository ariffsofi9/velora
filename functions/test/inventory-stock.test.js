'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  InventoryStockError,
  adjustInventoryStock,
} = require('../src/inventory-stock');

const validData = {
  idempotencyKey: 'stock-request-0001',
  itemId: 'item-a',
  direction: 'in',
  quantity: 3,
  expectedVersion: 1,
  reason: 'Supplier delivery',
};

function seed({
  uid = 'staff-a',
  status = 'active',
  includeItem = true,
  quantity = 4,
  unit = 'kg',
  version,
  lifecycleState,
} = {}) {
  const docs = {
    [`user_cafe_memberships/${uid}`]: {
      uid, cafeId: 'cafe-a', status, schemaVersion: 1,
    },
    'user_cafe_memberships/owner-a': {
      uid: 'owner-a', cafeId: 'cafe-a', status: 'active', schemaVersion: 1,
    },
    'cafes/cafe-a': {
      ownerUid: 'owner-a', status: 'active', schemaVersion: 1,
    },
    [`cafes/cafe-a/members/${uid}`]: {
      uid,
      cafeId: 'cafe-a',
      role: uid === 'owner-a' ? 'owner' : 'staff',
      status,
      schemaVersion: 1,
    },
    'cafes/cafe-a/members/owner-a': {
      uid: 'owner-a',
      cafeId: 'cafe-a',
      role: 'owner',
      status: 'active',
      schemaVersion: 1,
    },
  };
  if (includeItem) {
    docs['cafes/cafe-a/inventory/item-a'] = {
      cafeId: 'cafe-a',
      name: 'Flour',
      quantity,
      unit,
      schemaVersion: 1,
      ...(version == null ? {} : {version}),
      ...(lifecycleState == null ? {} : {lifecycleState}),
    };
  }
  return docs;
}

class MemoryStore {
  constructor(documents = {}, {failAtWrite} = {}) {
    this.docs = new Map(Object.entries(documents));
    this.failAtWrite = failAtWrite;
    this.queue = Promise.resolve();
  }

  runTransaction(operation) {
    const run = async () => {
      const creates = new Map();
      const updates = new Map();
      let writeCount = 0;
      const transaction = {
        get: async (path) => {
          if (creates.has(path)) return creates.get(path);
          const current = this.docs.get(path) ?? null;
          return updates.has(path) && current
            ? {...current, ...updates.get(path)}
            : current;
        },
        create: (path, data) => {
          writeCount += 1;
          if (writeCount === this.failAtWrite) throw new Error('write failed');
          if (this.docs.has(path) || creates.has(path)) {
            throw new Error(`Document already exists: ${path}`);
          }
          creates.set(path, data);
        },
        update: (path, data) => {
          writeCount += 1;
          if (writeCount === this.failAtWrite) throw new Error('write failed');
          if (!this.docs.has(path)) throw new Error(`Missing document: ${path}`);
          updates.set(path, {...(updates.get(path) ?? {}), ...data});
        },
      };
      const result = await operation(transaction);
      for (const [path, data] of updates) {
        this.docs.set(path, {...this.docs.get(path), ...data});
      }
      for (const [path, data] of creates) this.docs.set(path, data);
      return result;
    };
    const result = this.queue.then(run, run);
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
}

function invoke({uid = 'staff-a', data = validData, store} = {}) {
  return adjustInventoryStock({
    auth: uid ? {uid} : null,
    data: data && !Array.isArray(data) && typeof data === 'object' ? {expectedCafeId: 'cafe-a', expectedMembershipGeneration: 0, ...data} : data,
    store: store ?? new MemoryStore(seed()),
    timestamp: () => 'server-time',
  });
}

function errorCode(code) {
  return (error) => error instanceof InventoryStockError && error.code === code;
}

function auditDocs(store, collection) {
  return [...store.docs.entries()].filter(([path]) =>
    path.startsWith(`cafes/cafe-a/${collection}/`));
}

test('requires authentication', async () => {
  await assert.rejects(invoke({uid: null}), errorCode('unauthenticated'));
});

test('archived and invalid-lifecycle items reject stock adjustments', async () => {
  await assert.rejects(
    invoke({store: new MemoryStore(seed({lifecycleState: 'archived'}))}),
    errorCode('failed-precondition'),
  );
  await assert.rejects(
    invoke({store: new MemoryStore(seed({lifecycleState: 'unknown'}))}),
    errorCode('failed-precondition'),
  );
});

test('stock in updates quantity/version and atomically writes both audits', async () => {
  const store = new MemoryStore(seed());
  const result = await invoke({store});
  assert.deepEqual(result, {
    cafeId: 'cafe-a', itemId: 'item-a', direction: 'in', quantity: 3,
    resultingQuantity: 7, version: 2, adjusted: true,
  });
  const item = store.docs.get('cafes/cafe-a/inventory/item-a');
  assert.equal(item.quantity, 7);
  assert.equal(item.version, 2);
  assert.equal(item.updatedBy, 'staff-a');
  const movements = auditDocs(store, 'inventory_movements');
  const activities = auditDocs(store, 'activities');
  assert.equal(movements.length, 1);
  assert.equal(activities.length, 1);
  assert.equal(movements[0][1].type, 'stock_in');
  assert.equal(movements[0][1].delta, 3);
  assert.equal(movements[0][1].actorUid, 'staff-a');
  assert.equal(activities[0][1].type, 'inventory_stock_adjusted');
});

test('stock out supports an exact-zero result', async () => {
  const store = new MemoryStore(seed());
  const result = await invoke({
    store,
    data: {...validData, direction: 'out', quantity: 4},
  });
  assert.equal(result.resultingQuantity, 0);
  assert.equal(auditDocs(store, 'inventory_movements')[0][1].delta, -4);
});

test('stock out rejects insufficient stock without writes', async () => {
  const store = new MemoryStore(seed());
  await assert.rejects(
    invoke({store, data: {...validData, direction: 'out', quantity: 5}}),
    errorCode('failed-precondition'),
  );
  assert.equal(store.docs.get('cafes/cafe-a/inventory/item-a').quantity, 4);
  assert.equal(auditDocs(store, 'inventory_movements').length, 0);
});

test('rejects invalid quantities, overflow, direction and client authority', async () => {
  for (const data of [
    {...validData, quantity: 0},
    {...validData, quantity: -1},
    {...validData, quantity: 1.5},
    {...validData, quantity: Number.MAX_SAFE_INTEGER + 1},
    {...validData, direction: 'replace'},
    {...validData, cafeId: 'cafe-b'},
    {...validData, actorUid: 'forged'},
    {...validData, resultingQuantity: 100},
    {...validData, unit: 'kg'},
  ]) {
    await assert.rejects(invoke({data}), errorCode('invalid-argument'));
  }
  await assert.rejects(
    invoke({
      store: new MemoryStore(seed({quantity: Number.MAX_SAFE_INTEGER - 1})),
      data: {...validData, quantity: 2},
    }),
    errorCode('out-of-range'),
  );
});

test('missing or cross-cafe items are not visible', async () => {
  const store = new MemoryStore({
    ...seed({includeItem: false}),
    'cafes/cafe-b/inventory/item-a': {quantity: 100, unit: 'kg'},
  });
  await assert.rejects(invoke({store}), errorCode('not-found'));
  assert.equal(store.docs.get('cafes/cafe-b/inventory/item-a').quantity, 100);
});

test('inactive and inconsistent memberships fail closed', async () => {
  await assert.rejects(
    invoke({store: new MemoryStore(seed({status: 'inactive'}))}),
    errorCode('permission-denied'),
  );
  const inconsistent = seed();
  inconsistent['cafes/cafe-a/members/staff-a'].cafeId = 'cafe-b';
  await assert.rejects(
    invoke({store: new MemoryStore(inconsistent)}),
    errorCode('permission-denied'),
  );
});

test('active owner is authorized through the same trusted chain', async () => {
  const store = new MemoryStore(seed({uid: 'owner-a'}));
  const result = await invoke({uid: 'owner-a', store});
  assert.equal(result.adjusted, true);
  assert.equal(store.docs.get('cafes/cafe-a/inventory/item-a').updatedBy, 'owner-a');
});

test('identical retry is idempotent while changed reuse is rejected', async () => {
  const store = new MemoryStore(seed());
  const first = await invoke({store});
  const retry = await invoke({store});
  assert.equal(first.adjusted, true);
  assert.deepEqual(retry, {...first, adjusted: false});
  assert.equal(store.docs.get('cafes/cafe-a/inventory/item-a').quantity, 7);
  assert.equal(auditDocs(store, 'inventory_movements').length, 1);
  assert.equal(auditDocs(store, 'activities').length, 1);
  await assert.rejects(
    invoke({store, data: {...validData, quantity: 4}}),
    errorCode('already-exists'),
  );
});

test('stale and concurrent adjustments cannot overwrite newer stock', async () => {
  const store = new MemoryStore(seed());
  await invoke({store});
  await assert.rejects(
    invoke({
      store,
      data: {...validData, idempotencyKey: 'stale-stock-key-01'},
    }),
    errorCode('aborted'),
  );

  const concurrentStore = new MemoryStore(seed());
  const results = await Promise.allSettled([
    invoke({store: concurrentStore}),
    invoke({
      store: concurrentStore,
      data: {...validData, idempotencyKey: 'concurrent-stock-02'},
    }),
  ]);
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
  const rejected = results.find((result) => result.status === 'rejected');
  assert.equal(rejected.reason.code, 'aborted');
  assert.equal(concurrentStore.docs.get('cafes/cafe-a/inventory/item-a').quantity, 7);
});

test('transaction failure leaves item and both audits unchanged', async () => {
  const initial = seed();
  const store = new MemoryStore(initial, {failAtWrite: 2});
  await assert.rejects(invoke({store}), /write failed/);
  assert.deepEqual(
    store.docs.get('cafes/cafe-a/inventory/item-a'),
    initial['cafes/cafe-a/inventory/item-a'],
  );
  assert.equal(auditDocs(store, 'inventory_movements').length, 0);
  assert.equal(auditDocs(store, 'activities').length, 0);
});

test('invalid stored quantity, version and unit fail closed', async () => {
  await assert.rejects(
    invoke({store: new MemoryStore(seed({quantity: -1}))}),
    errorCode('failed-precondition'),
  );
  await assert.rejects(
    invoke({store: new MemoryStore(seed({version: 0}))}),
    errorCode('failed-precondition'),
  );
  await assert.rejects(
    invoke({store: new MemoryStore(seed({unit: ''}))}),
    errorCode('failed-precondition'),
  );
});


test('safe-integer version exhaustion rejects without item or audit writes', async () => {
  const store = new MemoryStore(seed());
  store.docs.get('cafes/cafe-a/inventory/item-a').version = Number.MAX_SAFE_INTEGER;
  const before = structuredClone(store.docs);
  await assert.rejects(invoke({store, data: {...validData, expectedVersion: Number.MAX_SAFE_INTEGER}}),
    {code: 'failed-precondition'});
  assert.deepEqual(store.docs, before);
});


test('only insufficient stock emits the explicit insufficient-stock reason', async () => {
  await assert.rejects(invoke({data: {...validData, direction: 'out', quantity: 100}}),
    error => error.code === 'failed-precondition' && error.reason === 'insufficient-stock');
  await assert.rejects(invoke({store: new MemoryStore(seed({lifecycleState: 'archived'}))}),
    error => error.code === 'failed-precondition' && error.reason === undefined);
});


for (const direction of ['in', 'out']) {
  test(`last safe stock ${direction} increment preserves movement/audit on retry and rejects exhaustion`, async () => {
    const store = new MemoryStore(seed({version: Number.MAX_SAFE_INTEGER - 1, quantity: 4}));
    const data = {...validData, direction, quantity: 1, expectedVersion: Number.MAX_SAFE_INTEGER - 1};
    const first = await invoke({store, data});
    assert.equal(first.version, Number.MAX_SAFE_INTEGER);
    assert.equal(first.resultingQuantity, direction === 'in' ? 5 : 3);
    const committed = structuredClone(store.docs);
    const retry = await invoke({store, data});
    assert.equal(retry.adjusted, false);
    assert.equal(retry.version, first.version);
    assert.equal(retry.resultingQuantity, first.resultingQuantity);
    assert.deepEqual(store.docs, committed);
    assert.equal(auditDocs(store, 'inventory_movements').length, 1);
    assert.equal(auditDocs(store, 'activities').length, 1);
    await assert.rejects(invoke({store, data: {...data, idempotencyKey: 'exhausted-stock-01',
      expectedVersion: Number.MAX_SAFE_INTEGER}}), {code: 'failed-precondition'});
    assert.deepEqual(store.docs, committed);
  });
}
