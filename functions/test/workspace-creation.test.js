'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  WorkspaceCreationError,
  createWorkspace,
} = require('../src/workspace-creation');

const validData = {
  businessName: 'Velora Foods',
  businessType: 'Restaurant',
  address: '12 Market Street',
  inventoryUnit: 'kg',
  lowStockAlerts: true,
  expiryReminders: true,
  reminderDays: 3,
};

class MemoryStore {
  constructor(seed = {}) {
    this.docs = new Map(Object.entries(seed));
    this.queue = Promise.resolve();
  }

  runTransaction(operation) {
    const run = async () => {
      const writes = new Map();
      const transaction = {
        get: async (path) => writes.get(path) ?? this.docs.get(path) ?? null,
        create: (path, data) => {
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

function invoke({uid = 'owner-a', data = validData, store, id = 'cafe-a'} = {}) {
  return createWorkspace({
    auth: uid ? {uid} : null,
    data,
    store: store ?? new MemoryStore(),
    idFactory: () => id,
    timestamp: () => 'server-time',
  });
}

function errorCode(code) {
  return (error) => error instanceof WorkspaceCreationError && error.code === code;
}

test('requires authenticated Firebase context', async () => {
  await assert.rejects(invoke({uid: null}), errorCode('unauthenticated'));
});

for (const field of ['uid', 'ownerUid', 'role', 'cafeId', 'businessId']) {
  test(`rejects forged authority field ${field}`, async () => {
    await assert.rejects(
      invoke({data: {...validData, [field]: 'forged'}}),
      errorCode('invalid-argument'),
    );
  });
}

test('validates business setup input', async () => {
  await assert.rejects(
    invoke({data: {...validData, businessName: ' '}}),
    errorCode('invalid-argument'),
  );
  await assert.rejects(
    invoke({data: {...validData, reminderDays: 30}}),
    errorCode('invalid-argument'),
  );
});

test('atomically creates resolver-compatible owner documents', async () => {
  const store = new MemoryStore();
  const result = await invoke({store});
  assert.deepEqual(result, {cafeId: 'cafe-a', created: true});
  assert.equal(store.docs.get('cafes/cafe-a').ownerUid, 'owner-a');
  assert.equal(store.docs.get('cafes/cafe-a').schemaVersion, 1);
  assert.equal(
    store.docs.get('cafes/cafe-a/members/owner-a').role,
    'owner',
  );
  assert.equal(
    store.docs.get('user_cafe_memberships/owner-a').cafeId,
    'cafe-a',
  );
  assert.equal(store.docs.size, 3);
});

test('retry returns the existing valid owner workspace', async () => {
  const store = new MemoryStore();
  await invoke({store});
  const retry = await invoke({store, id: 'unused-cafe'});
  assert.deepEqual(retry, {cafeId: 'cafe-a', created: false});
  assert.equal(store.docs.size, 3);
});

test('concurrent requests create exactly one workspace', async () => {
  const store = new MemoryStore();
  const [first, second] = await Promise.all([
    invoke({store, id: 'cafe-a'}),
    invoke({store, id: 'cafe-b'}),
  ]);
  assert.equal([first, second].filter((result) => result.created).length, 1);
  assert.equal(new Set([first.cafeId, second.cafeId]).size, 1);
  assert.equal(store.docs.size, 3);
});

test('existing staff membership cannot bootstrap an owner workspace', async () => {
  const store = new MemoryStore({
    'user_cafe_memberships/staff-a': {
      uid: 'staff-a',
      cafeId: 'cafe-a',
      status: 'active',
      schemaVersion: 1,
    },
    'cafes/cafe-a': {
      ownerUid: 'owner-a',
      status: 'active',
      schemaVersion: 1,
    },
    'cafes/cafe-a/members/staff-a': {
      uid: 'staff-a',
      cafeId: 'cafe-a',
      role: 'staff',
      status: 'active',
      schemaVersion: 1,
    },
  });
  await assert.rejects(
    invoke({uid: 'staff-a', store}),
    errorCode('already-exists'),
  );
  assert.equal(store.docs.size, 3);
});
