'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {removeStaffMember, createStaffRemovalHandler} = require('../src/membership-removal');
const {menuOperation} = require('../src/menu-service');
const {redeemStaffInvitation} = require('../src/workspace-invitations');
const {createHash} = require('node:crypto');

// Offline optimistic model only; never imports Firebase or opens a connection.
class Store {
  constructor() { this.docs = new Map(); this.versions = new Map(); this.conflicts = 0; }
  put(p, d) { this.docs.set(p, structuredClone(d)); this.versions.set(p, (this.versions.get(p) ?? 0) + 1); }
  async runTransaction(fn) {
    for (let retry = 0; retry < 30; retry++) {
      const snapshot = structuredClone(this.docs); const versions = new Map(this.versions);
      const reads = new Set(); const writes = new Map(); let writing = false; let count = 0;
      const write = (p, d, creating) => {
        writing = true; count++; if (count === this.failWrite) throw Error('synthetic write failure');
        assert.equal(snapshot.has(p), !creating); assert.equal(writes.has(p), false);
        reads.add(p); writes.set(p, creating ? structuredClone(d) : {...snapshot.get(p), ...structuredClone(d)});
      };
      const result = await fn({get: async p => {
        assert.equal(writing, false, 'read after write'); reads.add(p); await Promise.resolve();
        return structuredClone(snapshot.get(p) ?? null);
      }, create: (p, d) => write(p, d, true), update: (p, d) => write(p, d, false)});
      if (this.beforeCommit) { const hook = this.beforeCommit; this.beforeCommit = null; await hook(); }
      if ([...reads].some(p => this.versions.get(p) !== versions.get(p))) { this.conflicts++; continue; }
      if (this.failCommit) throw Error('synthetic commit failure');
      for (const [p, d] of writes) this.put(p, d);
      return result;
    }
    throw Error('retry limit');
  }
}
const auth = {uid: 'owner', token: {email_verified: true, email: 'owner@example.test'}};
const data = {targetUid: 'staff', expectedCafeId: 'a', expectedGeneration: 0,
  expectedActorGeneration: 0, idempotencyKey: 'removal-request-0001'};
function fixture(generation) {
  const store = new Store();
  for (const [uid, role] of [['owner', 'owner'], ['staff', 'staff'], ['second', 'staff']]) {
    const link = {uid, cafeId: 'a', status: 'active', schemaVersion: 1, createdAt: 'old-time'};
    if (generation !== undefined) link.membershipGeneration = generation;
    store.put(`user_cafe_memberships/${uid}`, link);
    store.put(`cafes/a/members/${uid}`, {...link, role});
  }
  store.put('cafes/a', {ownerUid: 'owner', status: 'active', schemaVersion: 1});
  const input = {...data, expectedGeneration: generation ?? 0, expectedActorGeneration: generation ?? 0};
  const run = (changes = {}, identity = auth) => removeStaffMember({auth: identity, data: {...input, ...changes},
    store, timestamp: () => 'server-time'});
  return {store, input, run};
}
const events = f => [...f.store.docs].filter(([p]) => p.includes('/membership_events/'));
const receipts = f => [...f.store.docs].filter(([p]) => p.includes('/membership_requests/'));

for (const generation of [undefined, 0, 7]) {
  test(`atomic removal preserves history for generation ${generation ?? 'legacy'}`, async () => {
    const f = fixture(generation); const before = structuredClone(f.store.docs);
    const result = await f.run();
    assert.equal(result.changed, true); assert.equal(result.resultGeneration, (generation ?? 0) + 1);
    for (const p of ['user_cafe_memberships/staff', 'cafes/a/members/staff']) {
      assert.deepEqual(f.store.docs.get(p), {...before.get(p), status: 'inactive',
        membershipGeneration: result.resultGeneration, removedAt: 'server-time', removedBy: 'owner',
        updatedAt: 'server-time', removalEventId: result.eventId});
    }
    assert.equal(events(f).length, 1); assert.equal(receipts(f).length, 1);
    const event = events(f)[0][1];
    assert.deepEqual(event.previousMapping, before.get('user_cafe_memberships/staff'));
    assert.deepEqual(event.previousMember, before.get('cafes/a/members/staff'));
    for (const [p, d] of before) if (!['user_cafe_memberships/staff', 'cafes/a/members/staff'].includes(p)) {
      assert.deepEqual(f.store.docs.get(p), d);
    }
    assert.equal([...f.store.docs.keys()].some(p => p.includes('/activities/')), false);
    const removed = structuredClone(f.store.docs);
    const retry = await f.run(); assert.equal(retry.changed, false);
    assert.equal(retry.eventId, result.eventId); assert.deepEqual(f.store.docs, removed);
  });
}
for (const defect of ['unauthenticated', 'unverified', 'self', 'staff-actor', 'missing-owner-map',
  'inactive-owner', 'owner-pair-mismatch', 'wrong-cafe-owner', 'inactive-cafe', 'bad-schema',
  'missing-target-map', 'missing-target-member', 'inactive-target', 'target-owner', 'foreign-target',
  'target-generation-mismatch', 'partial-generation', 'overflow', 'stale-generation', 'stale-actor', 'wrong-cafe']) {
  test(`removal rejects ${defect} without writes`, async () => {
    const f = fixture(); let identity = auth; const changes = {};
    const edit = (p, delta) => f.store.put(p, {...f.store.docs.get(p), ...delta});
    if (defect === 'unauthenticated') identity = null;
    if (defect === 'unverified') identity = {uid: 'owner', token: {email_verified: false}};
    if (defect === 'self') changes.targetUid = 'owner';
    if (defect === 'staff-actor') identity = {...auth, uid: 'second'};
    if (defect === 'missing-owner-map') f.store.docs.delete('user_cafe_memberships/owner');
    if (defect === 'inactive-owner') edit('user_cafe_memberships/owner', {status: 'inactive'});
    if (defect === 'owner-pair-mismatch') { edit('user_cafe_memberships/owner', {membershipGeneration: 1}); edit('cafes/a/members/owner', {membershipGeneration: 2}); }
    if (defect === 'wrong-cafe-owner') edit('cafes/a', {ownerUid: 'other'});
    if (defect === 'inactive-cafe') edit('cafes/a', {status: 'inactive'});
    if (defect === 'bad-schema') edit('cafes/a/members/staff', {schemaVersion: 2});
    if (defect === 'missing-target-map') f.store.docs.delete('user_cafe_memberships/staff');
    if (defect === 'missing-target-member') f.store.docs.delete('cafes/a/members/staff');
    if (defect === 'inactive-target') edit('cafes/a/members/staff', {status: 'inactive'});
    if (defect === 'target-owner') edit('cafes/a/members/staff', {role: 'owner'});
    if (defect === 'foreign-target') edit('user_cafe_memberships/staff', {cafeId: 'b'});
    if (defect === 'target-generation-mismatch') { edit('user_cafe_memberships/staff', {membershipGeneration: 1}); edit('cafes/a/members/staff', {membershipGeneration: 2}); }
    if (defect === 'partial-generation') edit('user_cafe_memberships/staff', {membershipGeneration: 0});
    if (defect === 'overflow') {
      for (const p of ['user_cafe_memberships/staff', 'cafes/a/members/staff']) edit(p, {membershipGeneration: Number.MAX_SAFE_INTEGER});
      changes.expectedGeneration = Number.MAX_SAFE_INTEGER;
    }
    if (defect === 'stale-generation') changes.expectedGeneration = 1;
    if (defect === 'stale-actor') changes.expectedActorGeneration = 1;
    if (defect === 'wrong-cafe') changes.expectedCafeId = 'b';
    const before = structuredClone(f.store.docs);
    await assert.rejects(f.run(changes, identity), e => ['unauthenticated', 'failed-precondition', 'permission-denied', 'aborted'].includes(e.code));
    assert.deepEqual(f.store.docs, before);
  });
}
for (const changes of [{actorUid: 'owner'}, {cafeId: 'a'}, {expectedGeneration: -1},
  {expectedGeneration: 0.5}, {expectedGeneration: '0'}, {expectedGeneration: null},
  {expectedGeneration: Number.MAX_SAFE_INTEGER + 1}, {idempotencyKey: 'short'}, {targetUid: '../staff'}]) {
  test(`invalid payload ${JSON.stringify(changes)}`, async () => {
    const f = fixture(); const before = structuredClone(f.store.docs);
    await assert.rejects(f.run(changes), {code: 'invalid-argument'}); assert.deepEqual(f.store.docs, before);
  });
}
test('same key conflicting payload and different key repeated removal fail safely', async () => {
  const f = fixture(); await f.run(); const before = structuredClone(f.store.docs);
  await assert.rejects(f.run({targetUid: 'second'}), {code: 'already-exists'});
  await assert.rejects(f.run({expectedGeneration: 1}), {code: 'already-exists'});
  await assert.rejects(f.run({idempotencyKey: 'removal-request-0002'}), {code: 'permission-denied'});
  assert.deepEqual(f.store.docs, before);
});
for (const failWrite of [1, 2, 3, 4, 'commit']) {
  test(`transaction failure at ${failWrite} rolls back all documents`, async () => {
    const f = fixture(); const before = structuredClone(f.store.docs);
    if (failWrite === 'commit') f.store.failCommit = true; else f.store.failWrite = failWrite;
    await assert.rejects(f.run(), /synthetic/); assert.deepEqual(f.store.docs, before);
  });
}
for (const sameKey of [true, false]) {
  test(`concurrent removals increment once (same key ${sameKey})`, async () => {
    const f = fixture();
    const result = await Promise.allSettled([f.run(), f.run(sameKey ? {} : {idempotencyKey: 'removal-request-0002'})]);
    assert.equal(result.filter(r => r.status === 'fulfilled' && r.value.changed).length, 1);
    assert.equal(result.filter(r => r.status === 'fulfilled').length, sameKey ? 2 : 1);
    assert.equal(f.store.docs.get('user_cafe_memberships/staff').membershipGeneration, 1);
    assert.equal(events(f).length, 1); assert.equal(receipts(f).length, 1); assert.ok(f.store.conflicts > 0);
  });
}
test('actor authority is rechecked on retries and before receipt acknowledgement', async () => {
  const f = fixture();
  f.store.beforeCommit = () => f.store.put('user_cafe_memberships/owner', {...f.store.docs.get('user_cafe_memberships/owner'), status: 'inactive'});
  await assert.rejects(f.run(), {code: 'permission-denied'});
  assert.equal(events(f).length, 0); assert.equal(f.store.docs.get('user_cafe_memberships/staff').status, 'active');
  const g = fixture(); await g.run();
  g.store.put('user_cafe_memberships/owner', {...g.store.docs.get('user_cafe_memberships/owner'), status: 'inactive'});
  await assert.rejects(g.run(), {code: 'permission-denied'});
});
test('old retry acknowledges historical result without removing a simulated future episode', async () => {
  const f = fixture(); await f.run();
  for (const p of ['user_cafe_memberships/staff', 'cafes/a/members/staff']) {
    f.store.put(p, {...f.store.docs.get(p), status: 'active', membershipGeneration: 2});
  }
  const before = structuredClone(f.store.docs); assert.equal((await f.run()).changed, false);
  await assert.rejects(f.run({idempotencyKey: 'removal-request-0002'}), {code: 'aborted'});
  assert.deepEqual(f.store.docs, before);
});
for (const defect of ['missing-event', 'missing-receipt', 'bad-receipt']) {
  test(`inconsistent removal records deny: ${defect}`, async () => {
    const f = fixture(); await f.run();
    if (defect === 'missing-event') f.store.docs.delete(events(f)[0][0]);
    if (defect === 'missing-receipt') f.store.docs.delete(receipts(f)[0][0]);
    if (defect === 'bad-receipt') f.store.put(receipts(f)[0][0], {...receipts(f)[0][1], resultGeneration: 99});
    const before = structuredClone(f.store.docs); await assert.rejects(f.run(), {code: 'failed-precondition'});
    assert.deepEqual(f.store.docs, before);
  });
}
test('removed Staff loses backend authorization and cannot redeem an existing invitation', async () => {
  const f = fixture(); await f.run();
  await assert.rejects(menuOperation({auth: {uid: 'staff'}, data: {itemId: 'item'}, operation: 'get', store: f.store}), {code: 'permission-denied'});
  const code = 'a'.repeat(32) + '.' + 'b'.repeat(64);
  f.store.put(`workspace_invitations/${'a'.repeat(32)}`, {ownerUid: 'owner', cafeId: 'a', role: 'staff',
    email: 'staff@example.test', status: 'pending', schemaVersion: 1,
    expiresAt: new Date('2031-01-01Z'), tokenHash: createHash('sha256').update(code).digest('hex')});
  await assert.rejects(redeemStaffInvitation({auth: {uid: 'staff', token: {email_verified: true, email: 'staff@example.test'}},
    data: {code}, store: f.store, now: () => new Date('2030-01-01Z')}), {code: 'already-exists'});
  assert.equal(f.store.docs.get('user_cafe_memberships/staff').status, 'inactive');
});
for (const removalWins of [true, false]) {
  test(`removal versus Staff menu mutation respects commit ordering: removal first ${removalWins}`, async () => {
    const f = fixture();
    const item = {cafeId: 'a', schemaVersion: 1, currency: 'MYR', version: 1, isArchived: false,
      name: 'Soup', category: 'Lunch', priceMinor: 100, isAvailable: true,
      createdBy: 'owner', updatedBy: 'owner', createdAt: new Date('2030-01-01Z'), updatedAt: new Date('2030-01-01Z')};
    f.store.put('cafes/a/menu_items/item', item);
    const mutate = () => menuOperation({auth: {uid: 'staff'}, store: f.store,
      operation: 'update', timestamp: () => new Date('2030-01-02Z'), data: {
        expectedCafeId: 'a', expectedMembershipGeneration: 0, itemId: 'item', expectedVersion: 1, isAvailable: false, idempotencyKey: 'menu-removal-race-01'}});
    if (removalWins) {
      f.store.beforeCommit = () => f.run();
      await assert.rejects(mutate(), {code: 'permission-denied'});
      assert.deepEqual(f.store.docs.get('cafes/a/menu_items/item'), item);
      assert.ok(f.store.conflicts > 0);
    } else {
      f.store.beforeCommit = mutate;
      await f.run();
      assert.equal(f.store.docs.get('cafes/a/menu_items/item').isAvailable, false);
      assert.equal(f.store.docs.get('cafes/a/menu_items/item').version, 2);
    }
    assert.equal(f.store.docs.get('user_cafe_memberships/staff').status, 'inactive');
    assert.equal(events(f).length, 1);
  });
}
test('target episode change during removal retries and rejects stale generation', async () => {
  const f = fixture();
  f.store.beforeCommit = () => {
    for (const p of ['user_cafe_memberships/staff', 'cafes/a/members/staff']) {
      f.store.put(p, {...f.store.docs.get(p), membershipGeneration: 2});
    }
  };
  await assert.rejects(f.run(), {code: 'aborted'});
  assert.ok(f.store.conflicts > 0); assert.equal(events(f).length, 0);
  assert.equal(f.store.docs.get('user_cafe_memberships/staff').status, 'active');
});
test('callable factory stays disabled before account or store I/O', async () => {
  const never = () => { throw Error('I/O forbidden'); };
  await assert.rejects(createStaffRemovalHandler({account: never, store: {runTransaction: never}, timestamp: never})({auth, data}), {code: 'failed-precondition'});
  const index = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  assert.match(index, /createStaffRemovalHandler\(\{\s*enabled: false,/);
});
test('enabled offline handler checks fresh account and forwards trusted Auth', async () => {
  const f = fixture(); const account = async uid => ({uid, email: 'owner@example.test', emailVerified: true, disabled: false});
  const handler = createStaffRemovalHandler({enabled: true, store: f.store, account, timestamp: () => 'server-time'});
  assert.equal((await handler({auth, data})).changed, true);
  for (const user of [{uid: 'owner', disabled: true}, {uid: 'other'},
    {uid: 'owner', emailVerified: false}, {uid: 'owner', emailVerified: true, email: 'other@example.test'}]) {
    await assert.rejects(createStaffRemovalHandler({enabled: true, store: f.store, account: async () => user})({auth, data}));
  }
});
