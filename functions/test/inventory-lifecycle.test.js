'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  InventoryLifecycleError,
  setInventoryLifecycle,
} = require('../src/inventory-lifecycle');

const deleted = Symbol('deleted');

function seed({status = 'active', lifecycleState, version = 1} = {}) {
  const item = {
    cafeId: 'cafe-a', name: 'Milk', quantity: 4, unit: 'L', version,
    schemaVersion: 1,
  };
  if (lifecycleState != null) item.lifecycleState = lifecycleState;
  return {
    'user_cafe_memberships/staff-a': {
      uid: 'staff-a', cafeId: 'cafe-a', status, schemaVersion: 1,
    },
    'user_cafe_memberships/owner-a': {
      uid: 'owner-a', cafeId: 'cafe-a', status: 'active', schemaVersion: 1,
    },
    'cafes/cafe-a': {
      ownerUid: 'owner-a', status: 'active', schemaVersion: 1,
    },
    'cafes/cafe-a/members/staff-a': {
      uid: 'staff-a', cafeId: 'cafe-a', role: 'staff', status, schemaVersion: 1,
    },
    'cafes/cafe-a/members/owner-a': {
      uid: 'owner-a', cafeId: 'cafe-a', role: 'owner', status: 'active', schemaVersion: 1,
    },
    'cafes/cafe-a/inventory/item-a': item,
  };
}

class MemoryStore {
  constructor(documents) {
    this.docs = new Map(Object.entries(documents));
    this.queue = Promise.resolve();
  }
  runTransaction(operation) {
    const run = async () => {
      const updates = new Map();
      const creates = new Map();
      const transaction = {
        get: async (path) => creates.get(path) ?? this.docs.get(path) ?? null,
        update: (path, data) => updates.set(path, data),
        create: (path, data) => {
          if (this.docs.has(path) || creates.has(path)) throw new Error('exists');
          creates.set(path, data);
        },
      };
      const result = await operation(transaction);
      for (const [path, changes] of updates) {
        const next = {...this.docs.get(path)};
        for (const [key, value] of Object.entries(changes)) {
          if (value === deleted) delete next[key]; else next[key] = value;
        }
        this.docs.set(path, next);
      }
      for (const [path, data] of creates) this.docs.set(path, data);
      return result;
    };
    const result = this.queue.then(run, run);
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
}

const archive = {
  idempotencyKey: 'lifecycle-request-0001', itemId: 'item-a',
  action: 'archive', expectedVersion: 1,
};

function invoke({uid = 'staff-a', data = archive, store} = {}) {
  return setInventoryLifecycle({
    auth: uid ? {uid} : null,
    data: data && !Array.isArray(data) && typeof data === 'object' ? {expectedCafeId: 'cafe-a', expectedMembershipGeneration: 0, ...data} : data,
    store: store ?? new MemoryStore(seed()),
    timestamp: () => 'server-time',
    deleteValue: () => deleted,
  });
}

function code(expected) {
  return (error) => error instanceof InventoryLifecycleError && error.code === expected;
}

test('archives legacy-active item atomically while preserving quantity', async () => {
  const store = new MemoryStore(seed());
  const result = await invoke({store});
  assert.deepEqual(result, {
    cafeId: 'cafe-a', itemId: 'item-a', lifecycleState: 'archived',
    version: 2, changed: true,
  });
  const item = store.docs.get('cafes/cafe-a/inventory/item-a');
  assert.equal(item.quantity, 4);
  assert.equal(item.lifecycleState, 'archived');
  assert.equal(item.archivedBy, 'staff-a');
  assert.equal([...store.docs.keys()].filter((p) => p.includes('/activities/')).length, 1);
});

test('restores archived item and removes archive metadata', async () => {
  const docs = seed({lifecycleState: 'archived', version: 2});
  docs['cafes/cafe-a/inventory/item-a'].archivedAt = 'old';
  docs['cafes/cafe-a/inventory/item-a'].archivedBy = 'staff-a';
  const store = new MemoryStore(docs);
  const result = await invoke({store, data: {
    ...archive, idempotencyKey: 'lifecycle-request-0002', action: 'restore',
    expectedVersion: 2,
  }});
  assert.equal(result.lifecycleState, 'active');
  const item = store.docs.get('cafes/cafe-a/inventory/item-a');
  assert.equal(item.quantity, 4);
  assert.equal(item.archivedAt, undefined);
  assert.equal(item.archivedBy, undefined);
});

test('identical retry is idempotent and changed reuse is rejected', async () => {
  const store = new MemoryStore(seed());
  const first = await invoke({store});
  const retry = await invoke({store});
  assert.equal(first.version, retry.version);
  assert.equal(retry.changed, false);
  await assert.rejects(invoke({store, data: {...archive, action: 'restore'}}),
    code('already-exists'));
  assert.equal([...store.docs.keys()].filter((p) => p.includes('/activities/')).length, 1);
});

test('rejects unauthenticated inactive invalid transition and stale version', async () => {
  await assert.rejects(invoke({uid: null}), code('unauthenticated'));
  await assert.rejects(invoke({store: new MemoryStore(seed({status: 'disabled'}))}),
    code('permission-denied'));
  await assert.rejects(invoke({store: new MemoryStore(seed({lifecycleState: 'archived'}))}),
    code('failed-precondition'));
  await assert.rejects(invoke({data: {...archive, expectedVersion: 2}}), code('aborted'));
});

test('concurrent archive requests cannot create duplicate lifecycle events', async () => {
  const store = new MemoryStore(seed());
  const results = await Promise.allSettled([
    invoke({store}),
    invoke({store, data: {...archive, idempotencyKey: 'lifecycle-request-0002'}}),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(results.filter((r) => r.status === 'rejected').length, 1);
  assert.equal([...store.docs.keys()].filter((p) => p.includes('/activities/')).length, 1);
});
