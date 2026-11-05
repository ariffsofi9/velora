'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {createInventoryItem} = require('../src/inventory-create');
const {updateInventoryItem} = require('../src/inventory-update');
const {adjustInventoryStock} = require('../src/inventory-stock');
const {setInventoryLifecycle} = require('../src/inventory-lifecycle');
const {menuOperation} = require('../src/menu-service');
const {removeStaffMember} = require('../src/membership-removal');
const {createStaffInvitation, redeemStaffInvitation} = require('../src/workspace-invitations');
class Store {
  constructor() { this.docs = new Map(); this.versions = new Map(); this.conflicts = 0; }
  put(p, d) { this.docs.set(p, structuredClone(d)); this.versions.set(p, (this.versions.get(p) ?? 0) + 1); }
  async runTransaction(fn) {
    for (let attempt = 0; attempt < 30; attempt++) {
      const docs = structuredClone(this.docs), versions = new Map(this.versions), reads = new Set(), writes = new Map();
      let writing = false;
      const write = (p, d, create) => {
        writing = true; assert.equal(docs.has(p), !create); reads.add(p);
        const value = create ? structuredClone(d) : {...docs.get(p), ...structuredClone(d)};
        for (const k of Object.keys(value)) if (value[k] === '__delete__') delete value[k];
        writes.set(p, value);
      };
      const result = await fn({get: async p => { assert.equal(writing, false); reads.add(p); await Promise.resolve(); return structuredClone(docs.get(p) ?? null); },
        create: (p, d) => write(p, d, true), update: (p, d) => write(p, d, false), set: (p, d) => { writing = true; reads.add(p); writes.set(p, structuredClone(d)); }});
      if (this.beforeCommit) { const hook = this.beforeCommit; this.beforeCommit = null; await hook(); }
      if ([...reads].some(p => versions.get(p) !== this.versions.get(p))) { this.conflicts++; continue; }
      for (const [p, d] of writes) this.put(p, d);
      return result;
    }
    throw Error('retry limit');
  }
}
const now = () => new Date('2030-01-01Z');
const auth = uid => ({uid, token: {email_verified: true, email: `${uid}@example.test`}});
function fixture() {
  const store = new Store();
  for (const [uid, cafeId, role] of [['owner', 'a', 'owner'], ['other', 'b', 'owner'], ['staff', 'a', 'staff']]) {
    const link = {uid, cafeId, status: 'active', schemaVersion: 1, createdAt: now()};
    store.put(`user_cafe_memberships/${uid}`, link); store.put(`cafes/${cafeId}/members/${uid}`, {...link, role});
    if (role === 'owner') store.put(`cafes/${cafeId}`, {ownerUid: uid, status: 'active', schemaVersion: 1});
  }
  store.put('cafes/a/inventory/item', {cafeId: 'a', name: 'Flour', category: 'Dry', quantity: 10, unit: 'kg',
    schemaVersion: 1, lifecycleState: 'active', version: 1, createdAt: now(), expiryDate: new Date('2031-01-01Z')});
  store.put('cafes/a/menu_items/menu', {cafeId: 'a', name: 'Soup', category: 'Lunch', priceMinor: 100, currency: 'MYR',
    schemaVersion: 1, isAvailable: true, isArchived: false, version: 1, createdAt: now(), updatedAt: now(), createdBy: 'owner', updatedBy: 'owner'});
  return {store};
}
const episode = {expectedCafeId: 'a', expectedMembershipGeneration: 0};
const operations = [
  {name: 'inventory create', fn: createInventoryItem, data: {name: 'Salt', category: 'Dry', quantity: 2, unit: 'kg', expiryDate: '2031-01-01T00:00:00.000Z'}},
  {name: 'inventory metadata', fn: updateInventoryItem, data: {itemId: 'item', expectedVersion: 1, name: 'Fresh Flour'}},
  ...['in', 'out'].map(direction => ({name: `stock ${direction}`, fn: adjustInventoryStock, data: {itemId: 'item', expectedVersion: 1, quantity: 1, direction}})),
  ...['archive', 'restore'].map(action => ({name: `inventory ${action}`, fn: setInventoryLifecycle, data: {itemId: 'item', expectedVersion: 1, action}})),
  {name: 'menu create', uid: 'owner', operation: 'create', data: {name: 'Tea', category: 'Drinks', priceMinor: 100, isAvailable: true}},
  {name: 'menu metadata', uid: 'owner', operation: 'update', data: {itemId: 'menu', expectedVersion: 1, name: 'New Soup'}},
  {name: 'menu availability', operation: 'update', data: {itemId: 'menu', expectedVersion: 1, isAvailable: false}},
  ...['archive', 'restore'].map(action => ({name: `menu ${action}`, uid: 'owner', operation: 'lifecycle', data: {itemId: 'menu', expectedVersion: 1, action}})),
];
function prepare(f, op) {
  if (op.name === 'inventory restore') f.store.put('cafes/a/inventory/item', {...f.store.docs.get('cafes/a/inventory/item'), lifecycleState: 'archived', archivedAt: now(), archivedBy: 'owner'});
  if (op.name === 'menu restore') f.store.put('cafes/a/menu_items/menu', {...f.store.docs.get('cafes/a/menu_items/menu'), isArchived: true});
}
function invoke(f, op, fields = episode) {
  const args = {store: f.store, auth: auth(op.uid ?? 'staff'), timestamp: now, toTimestamp: d => d, deleteValue: () => '__delete__',
    data: {idempotencyKey: 'episode-security-key-01', ...op.data, ...fields}};
  return op.fn ? op.fn(args) : menuOperation({...args, operation: op.operation});
}
async function remove(f) {
  return removeStaffMember({store: f.store, auth: auth('owner'), timestamp: now, data: {
    targetUid: 'staff', expectedCafeId: 'a', expectedGeneration: 0, expectedActorGeneration: 0, idempotencyKey: 'episode-removal-key-01'}});
}
async function rejoin(f, destination = 'owner') {
  const invitation = await createStaffInvitation({store: f.store, auth: auth(destination), now, allowRejoin: true,
    resolveAccount: async () => ({uid: 'staff', email: 'staff@example.test', emailVerified: true}),
    data: {email: 'staff@example.test', requestId: 'episode-rejoin-key-01'}});
  await redeemStaffInvitation({store: f.store, auth: auth('staff'), now, allowRejoin: true, data: {code: invitation.code}});
}
for (const op of operations) {
  test(`${op.name}: valid current legacy request and unchanged retry`, async () => {
    const f = fixture(); prepare(f, op); await invoke(f, op);
    const before = structuredClone(f.store.docs); await invoke(f, op); assert.deepEqual(f.store.docs, before);
  });
  test(`${op.name}: missing/malformed expectations deny with no writes`, async () => {
    for (const fields of [{}, {expectedCafeId: 'a'}, {expectedMembershipGeneration: 0},
      {...episode, expectedCafeId: '../a'}, ...[-1, 0.5, '0', null, Number.MAX_SAFE_INTEGER + 1].map(v => ({...episode, expectedMembershipGeneration: v}))]) {
      const f = fixture(); prepare(f, op); const before = structuredClone(f.store.docs);
      await assert.rejects(invoke(f, op, fields), {code: 'invalid-argument'}); assert.deepEqual(f.store.docs, before);
    }
  });
  test(`${op.name}: wrong workspace and generation deny before receipts or writes`, async () => {
    const f = fixture(); prepare(f, op); await invoke(f, op); const before = structuredClone(f.store.docs);
    for (const fields of [{...episode, expectedCafeId: 'b'}, {...episode, expectedMembershipGeneration: 2}]) {
      await assert.rejects(invoke(f, op, fields), {code: 'aborted'}); assert.deepEqual(f.store.docs, before);
    }
  });
  if (!op.uid) {
    test(`${op.name}: completed old receipt cannot replay in a new episode`, async () => {
      const f = fixture(); prepare(f, op); await invoke(f, op); await remove(f); await rejoin(f);
      const before = structuredClone(f.store.docs);
      await assert.rejects(invoke(f, op), {code: 'aborted'});
      await assert.rejects(invoke(f, op, {...episode, expectedMembershipGeneration: 2}), {code: 'already-exists'});
      assert.deepEqual(f.store.docs, before);
    });
    test(`${op.name}: removal and same-workspace rejoin reject original episode`, async () => {
      const f = fixture(); prepare(f, op); await remove(f); await rejoin(f); const before = structuredClone(f.store.docs);
      await assert.rejects(invoke(f, op), {code: 'aborted'}); assert.deepEqual(f.store.docs, before);
      await invoke(f, op, {...episode, expectedMembershipGeneration: 2});
    });
    test(`${op.name}: cross-workspace rejoin cannot retarget old request`, async () => {
      const f = fixture(); prepare(f, op); await remove(f); await rejoin(f, 'other'); const before = structuredClone(f.store.docs);
      await assert.rejects(invoke(f, op), {code: 'aborted'}); assert.deepEqual(f.store.docs, before);
    });
    for (const removalFirst of [true, false]) {
      test(`${op.name}: concurrent removal ordering, removal first ${removalFirst}`, async () => {
        const f = fixture(); prepare(f, op);
        if (removalFirst) {
          f.store.beforeCommit = () => remove(f);
          await assert.rejects(invoke(f, op), e => ['permission-denied', 'failed-precondition'].includes(e.code));
          assert.ok(f.store.conflicts > 0);
        } else { f.store.beforeCommit = () => invoke(f, op); await remove(f); }
        assert.equal(f.store.docs.get('user_cafe_memberships/staff').status, 'inactive');
      });
    }
  }
}
test('menu get/list request contract remains unchanged', async () => {
  const f = fixture(); const item = await menuOperation({store: f.store, auth: auth('staff'), operation: 'get', data: {itemId: 'menu'}});
  assert.equal(item.item.id, 'menu');
  f.store.runTransaction = fn => fn({get: async p => f.store.docs.get(p) ?? null,
    menuItems: async () => [{id: 'menu', data: f.store.docs.get('cafes/a/menu_items/menu')}]});
  const list = await menuOperation({store: f.store, auth: auth('staff'), operation: 'list', data: {}});
  assert.equal(list.items.length, 1);
});
