'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {createWorkspace} = require('../src/workspace-creation');
const {createStaffInvitation, redeemStaffInvitation} = require('../src/workspace-invitations');
const {menuOperation} = require('../src/menu-service');

// Offline optimistic store: overlapping callbacks read snapshots, then commits
// validate read versions and create preconditions. Conflicts retry the callback.
// This exercises retries rather than serializing complete callbacks in a queue;
// it is not a certification of the Firestore SDK or deployed transaction behavior.
class OptimisticStore {
  constructor() { this.docs = new Map(); this.versions = new Map(); this.conflicts = 0; }
  async runTransaction(fn) {
    for (let attempt = 0; attempt < 30; attempt++) {
      const snapshot = structuredClone(this.docs);
      const versions = new Map(this.versions);
      const reads = new Set(); const writes = new Map();
      let writing = false;
      const result = await fn({
        get: async path => {
          assert.equal(writing, false, 'all reads must precede writes');
          reads.add(path);
          await Promise.resolve();
          return structuredClone(snapshot.get(path) ?? null);
        },
        create: (path, value) => {
          writing = true;
          assert.equal(snapshot.has(path) || writes.has(path), false);
          reads.add(path); writes.set(path, structuredClone(value));
        },
        update: (path, value) => {
          writing = true; assert.equal(snapshot.has(path), true);
          reads.add(path); writes.set(path, {...snapshot.get(path), ...structuredClone(value)});
        },
      });
      if ([...reads].some(path => this.versions.get(path) !== versions.get(path))) {
        this.conflicts++; continue;
      }
      for (const [path, value] of writes) {
        this.docs.set(path, value);
        this.versions.set(path, (this.versions.get(path) ?? 0) + 1);
      }
      return result;
    }
    throw Error('Offline retry limit exceeded');
  }
}
const data = {businessName: 'Test Business', businessType: 'Restaurant'};
const auth = uid => ({uid, token: {email_verified: true, email: `${uid}@example.test`}});
const create = (store, uid, cafeId, changes = {}) => createWorkspace({
  auth: auth(uid), data: {...data, ...changes}, store,
  idFactory: () => cafeId, timestamp: () => new Date('2030-01-01Z'),
});
const now = () => new Date('2030-01-01Z');
const invite = (store, owner, uid) => createStaffInvitation({store, auth: auth(owner),
  data: {email: `${uid}@example.test`, requestId: 'security-invite-0001'}, now});
const join = (store, uid, invitation) => redeemStaffInvitation({store, auth: auth(uid),
  data: {code: invitation.code}, now});
const cafes = store => [...store.docs.keys()].filter(path => /^cafes\/[^/]+$/.test(path));

for (const claim of [undefined, false, 'true', 1, null]) {
  test(`creation rejects non-true verified claim ${String(claim)} before any side effect`, async () => {
    const never = () => { throw Error('must not run'); };
    await assert.rejects(createWorkspace({auth: {uid: 'new', token: {email_verified: claim}},
      data: {...data, email_verified: true}, store: {runTransaction: never},
      idFactory: never, timestamp: never}), {code: 'failed-precondition'});
  });
}
test('missing token and client-supplied verified status cannot authorize creation', async () => {
  await assert.rejects(createWorkspace({auth: {uid: 'new'}, data: {...data, email_verified: true}}),
    {code: 'failed-precondition'});
  const store = new OptimisticStore();
  await assert.rejects(create(store, 'new', 'new', {email_verified: true}), {code: 'invalid-argument'});
  assert.equal(store.docs.size, 0);
});
test('duplicate owner creation preserves the original documents', async () => {
  const store = new OptimisticStore(); await create(store, 'owner', 'a');
  const before = structuredClone(store.docs);
  await assert.rejects(create(store, 'owner', 'b', {businessName: 'Second Business'}), {code: 'already-exists'});
  assert.deepEqual(store.docs, before);
});
test('unverified identical retry cannot bypass the email requirement', async () => {
  const store = new OptimisticStore(); await create(store, 'owner', 'a');
  const before = structuredClone(store.docs);
  await assert.rejects(createWorkspace({auth: {uid: 'owner', token: {email_verified: false}},
    data, store, idFactory: () => 'unused', timestamp: now}), {code: 'failed-precondition'});
  assert.deepEqual(store.docs, before);
});
test('owner cannot join another workspace as staff', async () => {
  const store = new OptimisticStore();
  await create(store, 'owner', 'a'); await create(store, 'other', 'b');
  const invitation = await invite(store, 'other', 'owner');
  await assert.rejects(join(store, 'owner', invitation), {code: 'already-exists'});
  assert.equal(store.docs.get('user_cafe_memberships/owner').cafeId, 'a');
  assert.equal(store.docs.has('cafes/b/members/owner'), false);
  assert.equal(store.docs.get(`workspace_invitations/${invitation.invitationId}`).status, 'pending');
});
test('staff cannot create ownership elsewhere', async () => {
  const store = new OptimisticStore(); await create(store, 'owner', 'a');
  await join(store, 'staff', await invite(store, 'owner', 'staff'));
  await assert.rejects(create(store, 'staff', 'b'), {code: 'already-exists'});
  assert.deepEqual(cafes(store), ['cafes/a']);
});
test('concurrent different owner creations retry and allow exactly one', async () => {
  const store = new OptimisticStore();
  const result = await Promise.allSettled([
    create(store, 'new', 'a', {businessName: 'First'}),
    create(store, 'new', 'b', {businessName: 'Second'}),
  ]);
  assert.equal(result.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(result.find(r => r.status === 'rejected').reason.code, 'already-exists');
  assert.equal(store.docs.size, 3); assert.ok(store.conflicts > 0);
});
test('two workspace invitations race for one canonical membership', async () => {
  const store = new OptimisticStore();
  await create(store, 'owner-a', 'a'); await create(store, 'owner-b', 'b');
  const invitations = await Promise.all([invite(store, 'owner-a', 'new'), invite(store, 'owner-b', 'new')]);
  const result = await Promise.allSettled(invitations.map(i => join(store, 'new', i)));
  assert.equal(result.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(result.find(r => r.status === 'rejected').reason.code, 'already-exists');
  const cafeId = store.docs.get('user_cafe_memberships/new').cafeId;
  assert.equal(store.docs.get(`cafes/${cafeId}/members/new`).role, 'staff');
  assert.equal(store.docs.has(`cafes/${cafeId === 'a' ? 'b' : 'a'}/members/new`), false);
  assert.equal(invitations.filter(i => store.docs.get(`workspace_invitations/${i.invitationId}`).status === 'redeemed').length, 1);
  assert.ok(store.conflicts > 0);
});
for (const creationFirst of [true, false]) {
  test(`creation versus join cannot both succeed (creation wins: ${creationFirst})`, async () => {
    const store = new OptimisticStore(); await create(store, 'owner', 'a');
    const invitation = await invite(store, 'owner', 'new');
    // Barrier both membership callbacks at the canonical read, including when
    // redemption first performs its independent admission-limit transaction.
    const original = store.runTransaction.bind(store);
    let arrivals = 0; let release;
    const barrier = new Promise(resolve => { release = resolve; });
    let committed;
    const winnerCommitted = new Promise(resolve => { committed = resolve; });
    store.runTransaction = async fn => {
      let winner = false;
      const result = await original(tx => {
        let firstRead;
        return fn({...tx, get: async path => {
          firstRead ??= path;
          const value = await tx.get(path);
          if (path === 'user_cafe_memberships/new') {
            if (arrivals < 2) {
              arrivals++; if (arrivals === 2) release(); await barrier;
            }
            if ((firstRead === 'user_cafe_memberships/new') === creationFirst) winner = true;
            else await winnerCommitted;
          }
          return value;
        }});
      });
      if (winner) committed();
      return result;
    };
    const operations = creationFirst
      ? [() => create(store, 'new', 'b'), () => join(store, 'new', invitation)]
      : [() => join(store, 'new', invitation), () => create(store, 'new', 'b')];
    const result = await Promise.allSettled(operations.map(fn => fn()));
    assert.equal(result.filter(r => r.status === 'fulfilled').length, 1);
    assert.equal(result.find(r => r.status === 'rejected').reason.code, 'already-exists');
    const cafeId = store.docs.get('user_cafe_memberships/new').cafeId;
    assert.equal(cafeId, creationFirst ? 'b' : 'a');
    assert.equal(store.docs.get(`cafes/${cafeId}/members/new`).role, cafeId === 'b' ? 'owner' : 'staff');
    assert.equal(store.docs.has(`cafes/${cafeId === 'a' ? 'b' : 'a'}/members/new`), false);
    assert.equal(store.docs.has('cafes/b'), cafeId === 'b');
    assert.equal(store.docs.get(`workspace_invitations/${invitation.invitationId}`).status,
      cafeId === 'a' ? 'redeemed' : 'pending');
    assert.ok(store.conflicts > 0);
  });
}
for (const defect of ['inactive-map', 'inactive-member', 'owner-role-conflict', 'foreign-map']) {
  test(`inactive or inconsistent access fails closed: ${defect}`, async () => {
    const store = new OptimisticStore(); await create(store, 'owner', 'a');
    await join(store, 'staff', await invite(store, 'owner', 'staff'));
    if (defect === 'inactive-map') store.docs.get('user_cafe_memberships/staff').status = 'inactive';
    if (defect === 'inactive-member') store.docs.get('cafes/a/members/staff').status = 'inactive';
    if (defect === 'owner-role-conflict') store.docs.get('cafes/a/members/staff').role = 'owner';
    if (defect === 'foreign-map') store.docs.get('user_cafe_memberships/staff').cafeId = 'foreign';
    const before = structuredClone(store.docs);
    await assert.rejects(menuOperation({operation: 'get', auth: auth('staff'),
      data: {itemId: 'item'}, store}), {code: 'permission-denied'});
    await assert.rejects(create(store, 'staff', 'b'));
    assert.deepEqual(store.docs, before);
  });
}
test('inactive historical membership cannot be overwritten through redemption', async () => {
  const store = new OptimisticStore(); await create(store, 'owner', 'a');
  const invitation = await invite(store, 'owner', 'new');
  const tombstone = {uid: 'new', cafeId: 'old', status: 'inactive', schemaVersion: 1};
  store.docs.set('user_cafe_memberships/new', tombstone);
  await assert.rejects(join(store, 'new', invitation), {code: 'already-exists'});
  assert.deepEqual(store.docs.get('user_cafe_memberships/new'), tombstone);
  assert.equal(store.docs.has('cafes/a/members/new'), false);
  assert.equal(store.docs.get(`workspace_invitations/${invitation.invitationId}`).status, 'pending');
});
