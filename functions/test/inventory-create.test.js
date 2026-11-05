'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  createInventoryItem,
  InventoryCreationError,
} = require('../src/inventory-create');

const validData = {
  idempotencyKey: 'request-00000001',
  name: 'Fresh Milk',
  category: 'Dairy',
  quantity: 4,
  unit: 'L',
  expiryDate: '2030-01-02T00:00:00.000Z',
  imageUrl: '',
};

function membershipSeed({uid = 'staff-a', role = 'staff', status = 'active'} = {}) {
  return {
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
      role,
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
}

class MemoryStore {
  constructor(seed = {}, {failAtCreate} = {}) {
    this.docs = new Map(Object.entries(seed));
    this.failAtCreate = failAtCreate;
    this.queue = Promise.resolve();
  }

  runTransaction(operation) {
    const run = async () => {
      const writes = new Map();
      let createCount = 0;
      const transaction = {
        get: async (path) => writes.get(path) ?? this.docs.get(path) ?? null,
        create: (path, data) => {
          createCount += 1;
          if (createCount === this.failAtCreate) throw new Error('write failed');
          if (this.docs.has(path) || writes.has(path)) {
            throw new Error(`Document already exists: ${path}`);
          }
          writes.set(path, data);
        },
      };
      const result = await operation(transaction);
      for (const [path, value] of writes) this.docs.set(path, value);
      return result;
    };
    const result = this.queue.then(run, run);
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
}

function invoke({uid = 'staff-a', data = validData, store} = {}) {
  return createInventoryItem({
    auth: uid ? {uid} : null,
    data: data && !Array.isArray(data) && typeof data === 'object' ? {expectedCafeId: 'cafe-a', expectedMembershipGeneration: 0, ...data} : data,
    store: store ?? new MemoryStore(membershipSeed()),
    timestamp: () => 'server-time',
    toTimestamp: (date) => `timestamp:${date.toISOString()}`,
  });
}

function errorCode(code) {
  return (error) => error instanceof InventoryCreationError && error.code === code;
}

test('requires authenticated Firebase context', async () => {
  await assert.rejects(invoke({uid: null}), errorCode('unauthenticated'));
});

test('rejects invalid fields, quantities, units and expiry dates', async () => {
  await assert.rejects(
    invoke({data: {...validData, quantity: -1}}),
    errorCode('invalid-argument'),
  );
  await assert.rejects(
    invoke({data: {...validData, quantity: 1.5}}),
    errorCode('invalid-argument'),
  );
  await assert.rejects(
    invoke({data: {...validData, unit: 'box'}}),
    errorCode('invalid-argument'),
  );
  await assert.rejects(
    invoke({data: {...validData, expiryDate: '2030-01-02'}}),
    errorCode('invalid-argument'),
  );
});

for (const field of ['uid', 'actorUid', 'ownerUid', 'role', 'cafeId', 'itemId']) {
  test(`rejects client authority field ${field}`, async () => {
    await assert.rejects(
      invoke({data: {...validData, [field]: 'forged'}}),
      errorCode('invalid-argument'),
    );
  });
}

test('active staff atomically creates item, movement and activity', async () => {
  const store = new MemoryStore(membershipSeed());
  const result = await invoke({store});
  assert.equal(result.cafeId, 'cafe-a');
  assert.equal(result.created, true);
  const item = store.docs.get(`cafes/cafe-a/inventory/${result.itemId}`);
  assert.equal(item.createdBy, 'staff-a');
  assert.equal(item.quantity, 4);
  assert.equal(item.unit, 'L');
  const movement = [...store.docs.entries()].find(([path]) =>
    path.startsWith('cafes/cafe-a/inventory_movements/'))[1];
  const activity = [...store.docs.entries()].find(([path]) =>
    path.startsWith('cafes/cafe-a/activities/'))[1];
  assert.equal(movement.actorUid, 'staff-a');
  assert.equal(activity.actorUid, 'staff-a');
  assert.equal(store.docs.size, Object.keys(membershipSeed()).length + 3);
});

test('owner is authorized through the same verified membership chain', async () => {
  const store = new MemoryStore(membershipSeed({
    uid: 'owner-a',
    role: 'owner',
  }));
  const result = await invoke({uid: 'owner-a', store});
  assert.equal(result.created, true);
});

test('missing, inactive and inconsistent memberships fail closed', async () => {
  await assert.rejects(
    invoke({store: new MemoryStore()}),
    errorCode('permission-denied'),
  );
  await assert.rejects(
    invoke({store: new MemoryStore(membershipSeed({status: 'inactive'}))}),
    errorCode('permission-denied'),
  );
  await assert.rejects(
    invoke({store: new MemoryStore(membershipSeed({role: 'owner'}))}),
    errorCode('permission-denied'),
  );
});

test('retry with the same idempotency key returns the original item', async () => {
  const store = new MemoryStore(membershipSeed());
  const first = await invoke({store});
  const retry = await invoke({store});
  assert.deepEqual(retry, {...first, created: false});
  assert.equal(store.docs.size, Object.keys(membershipSeed()).length + 3);
});

test('reusing an idempotency key with changed data is rejected', async () => {
  const store = new MemoryStore(membershipSeed());
  await invoke({store});
  await assert.rejects(
    invoke({store, data: {...validData, quantity: 5}}),
    errorCode('already-exists'),
  );
  assert.equal(store.docs.size, Object.keys(membershipSeed()).length + 3);
});

test('concurrent duplicate requests create one item and one audit pair', async () => {
  const store = new MemoryStore(membershipSeed());
  const [first, second] = await Promise.all([
    invoke({store}),
    invoke({store}),
  ]);
  assert.equal(first.itemId, second.itemId);
  assert.equal([first, second].filter((value) => value.created).length, 1);
  assert.equal(store.docs.size, Object.keys(membershipSeed()).length + 3);
});

test('transaction failure leaves no item or audit records', async () => {
  const seed = membershipSeed();
  const store = new MemoryStore(seed, {failAtCreate: 2});
  await assert.rejects(invoke({store}), /write failed/);
  assert.equal(store.docs.size, Object.keys(seed).length);
  assert.equal(
    [...store.docs.keys()].some((path) => path.includes('/inventory/')),
    false,
  );
});
