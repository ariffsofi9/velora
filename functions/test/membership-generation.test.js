'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {activeMembershipGeneration: generation} = require('../src/membership-generation');
const {createWorkspace} = require('../src/workspace-creation');
const {createStaffInvitation, redeemStaffInvitation} = require('../src/workspace-invitations');
const {listTeamMembers} = require('../src/team-members');
const {menuOperation} = require('../src/menu-service');
const {createInventoryItem} = require('../src/inventory-create');
const {updateInventoryItem} = require('../src/inventory-update');
const {adjustInventoryStock} = require('../src/inventory-stock');
const {setInventoryLifecycle} = require('../src/inventory-lifecycle');

function pair(role = 'staff') {
  const uid = role === 'owner' ? 'owner' : 'staff';
  const mapping = {uid, cafeId: 'a', status: 'active', schemaVersion: 1};
  return [mapping, {...mapping, role}];
}
for (const role of ['owner', 'staff']) {
  const uid = role === 'owner' ? 'owner' : 'staff';
  test(`legacy active ${role} is generation zero without mutating records`, () => {
    const [mapping, member] = pair(role); const before = structuredClone([mapping, member]);
    assert.equal(generation(mapping, member, uid, 'a', 'owner'), 0);
    assert.deepEqual([mapping, member], before);
  });
  for (const value of [0, 1, Number.MAX_SAFE_INTEGER]) {
    test(`matching explicit ${role} generation ${value}`, () => {
      const [mapping, member] = pair(role);
      mapping.membershipGeneration = member.membershipGeneration = value;
      assert.equal(generation(mapping, member, uid, 'a', 'owner'), value);
    });
  }
}
const invalid = [-1, 0.5, '0', null, undefined, Number.MAX_SAFE_INTEGER + 1, NaN, Infinity, true, {}, []];
for (const [index, value] of invalid.entries()) {
  for (const side of [0, 1]) {
    test(`invalid generation ${index} on side ${side} denies`, () => {
      const links = pair(); links[0].membershipGeneration = links[1].membershipGeneration = 0;
      links[side].membershipGeneration = value;
      assert.equal(generation(...links, 'staff', 'a', 'owner'), null);
    });
  }
}
for (const defect of ['mismatch', 'partial-map-zero', 'partial-member-zero', 'inactive-map',
  'inactive-member', 'missing-map', 'missing-member', 'foreign-map', 'foreign-member',
  'wrong-uid', 'staff-as-owner', 'owner-as-staff', 'unknown-role', 'bad-schema']) {
  test(`pair denies ${defect}`, () => {
    const links = pair();
    if (defect === 'mismatch') { links[0].membershipGeneration = 1; links[1].membershipGeneration = 2; }
    if (defect === 'partial-map-zero') links[0].membershipGeneration = 0;
    if (defect === 'partial-member-zero') links[1].membershipGeneration = 0;
    if (defect === 'inactive-map') links[0].status = 'inactive';
    if (defect === 'inactive-member') links[1].status = 'inactive';
    if (defect === 'missing-map') links[0] = null;
    if (defect === 'missing-member') links[1] = null;
    if (defect === 'foreign-map') links[0].cafeId = 'b';
    if (defect === 'foreign-member') links[1].cafeId = 'b';
    if (defect === 'wrong-uid') links[0].uid = 'other';
    if (defect === 'staff-as-owner') links[1].role = 'owner';
    if (defect === 'owner-as-staff') { links[0].uid = links[1].uid = 'owner'; }
    if (defect === 'unknown-role') links[1].role = 'admin';
    if (defect === 'bad-schema') links[0].schemaVersion = 2;
    assert.equal(generation(...links, defect === 'owner-as-staff' ? 'owner' : 'staff', 'a', 'owner'), null);
  });
}

const setup = {businessName: 'Test Business', businessType: 'Restaurant', address: '',
  inventoryUnit: 'kg', lowStockAlerts: true, expiryReminders: true, reminderDays: 3};
class Authorized extends Error {}
function fixture(value) {
  const docs = new Map();
  for (const role of ['owner', 'staff']) {
    const [mapping, member] = pair(role);
    if (value !== undefined) mapping.membershipGeneration = member.membershipGeneration = value;
    docs.set(`user_cafe_memberships/${mapping.uid}`, mapping);
    docs.set(`cafes/a/members/${mapping.uid}`, member);
  }
  docs.set('cafes/a', {ownerUid: 'owner', status: 'active', schemaVersion: 1,
    name: setup.businessName, businessType: setup.businessType, address: '',
    inventoryPreferences: {unit: 'kg', lowStockAlerts: true, expiryReminders: true, reminderDays: 3}});
  let writes = 0;
  const store = {runTransaction: fn => fn({get: async path => {
    if (path.includes('/inventory/') || path.includes('/menu_items/') || path.startsWith('workspace_invite_requests/')) {
      throw new Authorized('Reached business operation after authorization');
    }
    return docs.get(path) ?? null;
  }, members: async () => { throw new Authorized(); },
  create: () => { writes++; }, update: () => { writes++; }})};
  return {docs, store, writes: () => writes};
}
const auth = uid => ({uid, token: {email_verified: true, email: `${uid}@example.test`}});
const base = f => ({store: f.store, timestamp: () => new Date(), auth: auth('staff')});
const operations = {
  'workspace retry': f => createWorkspace({...base(f), auth: auth('owner'), data: setup, idFactory: () => 'unused'}),
  'invitation owner': f => createStaffInvitation({...base(f), auth: auth('owner'),
    data: {expectedCafeId: 'a', expectedMembershipGeneration: f.docs.get('user_cafe_memberships/owner').membershipGeneration ?? 0, email: 'new@example.test', requestId: 'generation-invite-01'}}),
  'team context': f => listTeamMembers({...base(f), auth: auth('owner'), data: {}, accounts: async () => []}),
  'menu context': f => menuOperation({...base(f), operation: 'get', data: {itemId: 'item'}}),
  'inventory create': f => createInventoryItem({...base(f), toTimestamp: d => d,
    data: {expectedCafeId: 'a', expectedMembershipGeneration: f.docs.get('user_cafe_memberships/staff').membershipGeneration ?? 0, idempotencyKey: 'generation-create-01', name: 'Flour', category: 'Dry', quantity: 1,
      unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'}}),
  'inventory update': f => updateInventoryItem({...base(f), toTimestamp: d => d,
    data: {expectedCafeId: 'a', expectedMembershipGeneration: f.docs.get('user_cafe_memberships/staff').membershipGeneration ?? 0, idempotencyKey: 'generation-update-01', itemId: 'item', expectedVersion: 1, name: 'Flour'}}),
  'inventory stock': f => adjustInventoryStock({...base(f),
    data: {expectedCafeId: 'a', expectedMembershipGeneration: f.docs.get('user_cafe_memberships/staff').membershipGeneration ?? 0, idempotencyKey: 'generation-stock-01', itemId: 'item', expectedVersion: 1, direction: 'in', quantity: 1}}),
  'inventory lifecycle': f => setInventoryLifecycle({...base(f),
    data: {expectedCafeId: 'a', expectedMembershipGeneration: f.docs.get('user_cafe_memberships/staff').membershipGeneration ?? 0, idempotencyKey: 'generation-archive-01', itemId: 'item', expectedVersion: 1, action: 'archive'}}),
};
for (const [name, invoke] of Object.entries(operations)) {
  for (const value of [undefined, 7]) {
    test(`${name} accepts ${value === undefined ? 'legacy' : 'explicit'} generation before business operation`, async () => {
      const f = fixture(value); const before = structuredClone(f.docs);
      if (name === 'workspace retry') assert.equal((await invoke(f)).created, false);
      else await assert.rejects(invoke(f), Authorized);
      assert.deepEqual(f.docs, before); assert.equal(f.writes(), 0);
    });
  }
  for (const uid of ['owner', ...(name.startsWith('inventory') || name === 'menu context' ? ['staff'] : [])]) {
    test(`${name} denies mismatched ${uid} generation before any writes`, async () => {
      const f = fixture(7); f.docs.get(`cafes/a/members/${uid}`).membershipGeneration = 8;
      await assert.rejects(invoke(f), error => ['permission-denied', 'failed-precondition', 'already-exists'].includes(error.code));
      assert.equal(f.writes(), 0);
    });
  }
}
for (const explicit of [false, true]) {
  test(`redemption still rejects ${explicit ? 'explicit-generation' : 'legacy'} inactive tombstone`, async () => {
    const f = fixture(); const code = 'a'.repeat(32) + '.' + 'b'.repeat(64);
    const tombstone = {uid: 'new', cafeId: 'old', status: 'inactive', schemaVersion: 1,
      ...(explicit ? {membershipGeneration: 2} : {})};
    f.docs.set('user_cafe_memberships/new', tombstone);
    f.docs.set(`workspace_invitations/${'a'.repeat(32)}`, {ownerUid: 'owner', cafeId: 'a',
      role: 'staff', email: 'new@example.test', status: 'pending', schemaVersion: 1,
      issuerBindingVersion: 1, issuerMembershipGeneration: 0,
      tokenHash: createHash('sha256').update(code).digest('hex'), expiresAt: new Date('2031-01-01Z')});
    await assert.rejects(redeemStaffInvitation({store: f.store, auth: auth('new'),
      data: {code}, now: () => new Date('2030-01-01Z')}), {code: 'already-exists'});
    assert.deepEqual(f.docs.get('user_cafe_memberships/new'), tombstone);
    assert.equal(f.docs.get(`workspace_invitations/${'a'.repeat(32)}`).status, 'pending');
    assert.equal(f.writes(), 1); // Existing independent admission counter only.
  });
}
for (const defect of ['none', 'mismatched-candidate', 'partial-candidate', 'staff-caller']) {
  test(`team generation enforcement includes roster candidates: ${defect}`, async () => {
    const f = fixture(7);
    if (defect === 'mismatched-candidate') f.docs.get('cafes/a/members/staff').membershipGeneration = 8;
    if (defect === 'partial-candidate') delete f.docs.get('cafes/a/members/staff').membershipGeneration;
    const store = {runTransaction: fn => fn({get: async path => f.docs.get(path) ?? null,
      members: async () => ['owner', 'staff'].map(uid => ({id: uid, data: f.docs.get(`cafes/a/members/${uid}`)}))})};
    const result = await listTeamMembers({store, auth: auth(defect === 'staff-caller' ? 'staff' : 'owner'), data: {},
      accounts: async uids => uids.map(uid => ({uid, email: `${uid}@example.test`, emailVerified: true, disabled: false}))});
    assert.deepEqual(result.members.map(m => m.uid),
      defect === 'mismatched-candidate' || defect === 'partial-candidate' ? ['owner'] : ['owner', 'staff']);
  });
}
