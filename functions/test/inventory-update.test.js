'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  InventoryUpdateError,
  updateInventoryItem,
} = require('../src/inventory-update');

const validData = {
  idempotencyKey: 'update-request-0001',
  itemId: 'item-a',
  expectedVersion: 1,
  name: 'Fresh Milk',
  category: 'Dairy',
  unit: 'L',
  expiryDate: '2030-01-03T00:00:00.000Z',
  imageUrl: 'https://example.test/milk.png',
};

function seed({uid = 'staff-a', status = 'active', includeItem = true} = {}) {
  const docs = {
    [`user_cafe_memberships/${uid}`]: {
      uid,
      cafeId: 'cafe-a',
      status,
      schemaVersion: 1,
    },
    'user_cafe_memberships/owner-a': {
      uid: 'owner-a',
      cafeId: 'cafe-a',
      status: 'active',
      schemaVersion: 1,
    },
    'cafes/cafe-a': {
      ownerUid: 'owner-a',
      status: 'active',
      schemaVersion: 1,
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
      name: 'Milk',
      category: 'Dairy',
      quantity: 4,
      unit: 'L',
      expiryDate: 'timestamp:2030-01-02T00:00:00.000Z',
      imageUrl: '',
      createdBy: 'owner-a',
      schemaVersion: 1,
      createdAt: 'created-time',
      updatedAt: 'created-time',
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
  return updateInventoryItem({
    auth: uid ? {uid} : null,
    data,
    store: store ?? new MemoryStore(seed()),
    timestamp: () => 'server-time',
    toTimestamp: (date) => `timestamp:${date.toISOString()}`,
  });
}

function errorCode(code) {
  return (error) => error instanceof InventoryUpdateError && error.code === code;
}

test('requires authentication', async () => {
  await assert.rejects(invoke({uid: null}), errorCode('unauthenticated'));
});

test('valid metadata update increments version and writes one audit', async () => {
  const store = new MemoryStore(seed());
  const result = await invoke({store});
  assert.deepEqual(result, {
    cafeId: 'cafe-a',
    itemId: 'item-a',
    updated: true,
    version: 2,
  });
  const item = store.docs.get('cafes/cafe-a/inventory/item-a');
  assert.equal(item.name, 'Fresh Milk');
  assert.equal(item.quantity, 4);
  assert.equal(item.version, 2);
  assert.equal(item.updatedBy, 'staff-a');
  const audits = [...store.docs.entries()].filter(([path]) =>
    path.startsWith('cafes/cafe-a/activities/inventory_update_'));
  assert.equal(audits.length, 1);
  assert.equal(audits[0][1].actorUid, 'staff-a');
  assert.equal(audits[0][1].type, 'inventory_updated');
  assert.equal(
    [...store.docs.keys()].some((path) => path.includes('inventory_movements')),
    false,
  );
});

test('active owner is authorized through the same membership chain', async () => {
  const store = new MemoryStore(seed({uid: 'owner-a'}));
  const result = await invoke({uid: 'owner-a', store});
  assert.equal(result.updated, true);
  assert.equal(
    store.docs.get('cafes/cafe-a/inventory/item-a').updatedBy,
    'owner-a',
  );
});

test('unchanged submission records one no-op audit without changing version', async () => {
  const store = new MemoryStore(seed());
  const result = await invoke({
    store,
    data: {
      idempotencyKey: 'update-noop-00001',
      itemId: 'item-a',
      expectedVersion: 1,
      name: 'Milk',
    },
  });
  assert.equal(result.updated, false);
  assert.equal(result.version, 1);
  const item = store.docs.get('cafes/cafe-a/inventory/item-a');
  assert.equal(item.version, undefined);
  const audit = [...store.docs.values()].find(
    (value) => value.type === 'inventory_update_noop');
  assert.equal(audit.updated, false);
});

test('rejects invalid inputs and forbidden quantity or authority fields', async () => {
  for (const data of [
    {...validData, expectedVersion: 0},
    {...validData, unit: 'box'},
    {...validData, expiryDate: '2030-01-03'},
    {...validData, imageUrl: 'file:///private/item.png'},
    {...validData, cafeId: 'cafe-b'},
    {...validData, actorUid: 'forged'},
    {...validData, createdAt: 'forged'},
    {...validData, schemaVersion: 99},
    {...validData, imageUrl: 'file:///private/item.png'},
    {...validData, quantity: 10},
    {...validData, cafeId: 'cafe-b'},
    {...validData, actorUid: 'attacker'},
    {...validData, createdAt: 'forged'},
    {...validData, version: 5},
  ]) {
    await assert.rejects(invoke({data}), errorCode('invalid-argument'));
  }
});

test('missing and cross-cafe items are not visible to the caller', async () => {
  const store = new MemoryStore({
    ...seed({includeItem: false}),
    'cafes/cafe-b/inventory/item-a': {name: 'Other cafe item'},
  });
  await assert.rejects(invoke({store}), errorCode('not-found'));
  assert.equal(store.docs.get('cafes/cafe-b/inventory/item-a').name, 'Other cafe item');
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

test('identical retry returns the previous result without another audit', async () => {
  const store = new MemoryStore(seed());
  const first = await invoke({store});
  const retry = await invoke({store});
  assert.deepEqual(retry, first);
  const audits = [...store.docs.keys()].filter((path) =>
    path.startsWith('cafes/cafe-a/activities/inventory_update_'));
  assert.equal(audits.length, 1);
});

test('changed payload with the same idempotency key is rejected', async () => {
  const store = new MemoryStore(seed());
  await invoke({store});
  await assert.rejects(
    invoke({store, data: {...validData, name: 'Changed again'}}),
    errorCode('already-exists'),
  );
});

test('stale and concurrent edits fail instead of overwriting', async () => {
  const store = new MemoryStore(seed());
  const first = await invoke({store});
  assert.equal(first.version, 2);
  await assert.rejects(
    invoke({
      store,
      data: {
        ...validData,
        idempotencyKey: 'different-update-key',
        name: 'Stale update',
      },
    }),
    errorCode('aborted'),
  );

  const concurrentStore = new MemoryStore(seed());
  const results = await Promise.allSettled([
    invoke({store: concurrentStore}),
    invoke({
      store: concurrentStore,
      data: {
        ...validData,
        idempotencyKey: 'concurrent-key-002',
        category: 'Beverage',
      },
    }),
  ]);
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
  assert.equal(results.filter((result) => result.status === 'rejected').length, 1);
  assert.equal(results.find((result) => result.status === 'rejected').reason.code, 'aborted');
});

test('transaction failure leaves item and audit unchanged', async () => {
  const initial = seed();
  const store = new MemoryStore(initial, {failAtWrite: 2});
  await assert.rejects(invoke({store}), /write failed/);
  assert.deepEqual(
    store.docs.get('cafes/cafe-a/inventory/item-a'),
    initial['cafes/cafe-a/inventory/item-a'],
  );
  assert.equal(
    [...store.docs.keys()].some((path) =>
      path.startsWith('cafes/cafe-a/activities/inventory_update_')),
    false,
  );
});
