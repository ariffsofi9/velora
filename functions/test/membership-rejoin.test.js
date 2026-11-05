'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createStaffInvitation, redeemStaffInvitation} = require('../src/workspace-invitations');
const {removeStaffMember} = require('../src/membership-removal');
const {menuOperation} = require('../src/menu-service');
class Store {
  constructor() { this.docs = new Map(); this.versions = new Map(); this.conflicts = 0; }
  put(p, d) { this.docs.set(p, structuredClone(d)); this.versions.set(p, (this.versions.get(p) ?? 0) + 1); }
  async runTransaction(fn) {
    for (let attempt = 0; attempt < 30; attempt++) {
      const docs = structuredClone(this.docs), versions = new Map(this.versions), reads = new Set(), writes = new Map();
      let writing = false, count = 0;
      const write = (p, d, kind) => {
        writing = true; if (++count === this.failWrite) throw Error('synthetic write failure');
        if (kind === 'create') assert.equal(docs.has(p), false);
        if (kind !== 'create') assert.equal(docs.has(p), true);
        reads.add(p); writes.set(p, kind === 'update' ? {...docs.get(p), ...structuredClone(d)} : structuredClone(d));
      };
      const result = await fn({get: async p => {
        assert.equal(writing, false); reads.add(p); await Promise.resolve(); return structuredClone(docs.get(p) ?? null);
      }, create: (p, d) => write(p, d, 'create'), update: (p, d) => write(p, d, 'update'), set: (p, d) => write(p, d, 'set')});
      if (this.beforeCommit) { const hook = this.beforeCommit; this.beforeCommit = null; await hook(writes); }
      if ([...reads].some(p => versions.get(p) !== this.versions.get(p))) { this.conflicts++; continue; }
      if (this.failCommit && [...writes.keys()].some(p => p.includes('/membership_events/rejoin_'))) throw Error('synthetic commit failure');
      for (const [p, d] of writes) this.put(p, d);
      return result;
    }
    throw Error('retry limit');
  }
}
const now = () => new Date('2030-01-02T00:00:00Z');
const auth = uid => ({uid, token: {email_verified: true, email: `${uid}@example.test`}});
async function fixture() {
  const store = new Store();
  for (const [uid, cafeId, role] of [['oa', 'a', 'owner'], ['ob', 'b', 'owner'], ['oc', 'c', 'owner'], ['staff', 'a', 'staff']]) {
    const link = {uid, cafeId, status: 'active', schemaVersion: 1, createdAt: new Date('2030-01-01Z')};
    store.put(`user_cafe_memberships/${uid}`, link); store.put(`cafes/${cafeId}/members/${uid}`, {...link, role});
    if (role === 'owner') store.put(`cafes/${cafeId}`, {ownerUid: uid, status: 'active', schemaVersion: 1});
  }
  let sequence = 0;
  const remove = (owner = 'oa', cafeId = 'a', generation = 0) => removeStaffMember({store, auth: auth(owner), timestamp: now,
    data: {targetUid: 'staff', expectedCafeId: cafeId, expectedGeneration: generation, expectedActorGeneration: 0,
      idempotencyKey: `remove-request-${String(++sequence).padStart(8, '0')}`}});
  const issue = (owner = 'ob', options = {}) => createStaffInvitation({store, auth: auth(owner), now,
    data: {email: 'staff@example.test', requestId: `rejoin-request-${String(++sequence).padStart(8, '0')}`},
    allowRejoin: true, resolveAccount: async () => ({uid: 'staff', email: 'staff@example.test', emailVerified: true, disabled: false}), ...options});
  const redeem = (invite, options = {}) => redeemStaffInvitation({store, auth: auth('staff'),
    data: {code: invite.code}, now, allowRejoin: true, ...options});
  await remove();
  return {store, issue, redeem, remove};
}
const rejoinEvents = f => [...f.store.docs].filter(([p]) => p.includes('/membership_events/rejoin_'));
const protectedState = f => [...f.store.docs].filter(([p]) => !p.startsWith('workspace_invite_limits/'));

for (const sameCafe of [false, true]) {
  test(`valid bound rejoin is atomic and preserves history (same cafe ${sameCafe})`, async () => {
    const f = await fixture(); const old = structuredClone(f.store.docs);
    const invite = await f.issue(sameCafe ? 'oa' : 'ob');
    const document = f.store.docs.get(`workspace_invitations/${invite.invitationId}`);
    assert.equal(document.targetUid, 'staff'); assert.equal(document.targetGeneration, 1);
    assert.equal(document.previousCafeId, 'a');
    await assert.rejects(menuOperation({store: f.store, auth: auth('staff'), operation: 'get', data: {itemId: 'x'}}), {code: 'permission-denied'});
    const result = await f.redeem(invite); const cafeId = sameCafe ? 'a' : 'b';
    assert.equal(result.generation, 2); assert.equal(result.cafeId, cafeId);
    const mapping = f.store.docs.get('user_cafe_memberships/staff');
    const member = f.store.docs.get(`cafes/${cafeId}/members/staff`);
    assert.equal(mapping.status, 'active'); assert.equal(member.role, 'staff');
    assert.equal(mapping.membershipGeneration, 2); assert.equal(member.membershipGeneration, 2);
    assert.equal(Object.hasOwn(mapping, 'removedAt'), false);
    for (const [p, d] of old) if (p.includes('/membership_events/') || p.includes('/membership_requests/')) assert.deepEqual(f.store.docs.get(p), d);
    if (!sameCafe) assert.deepEqual(f.store.docs.get('cafes/a/members/staff'), old.get('cafes/a/members/staff'));
    assert.equal(rejoinEvents(f).length, 1);
    assert.deepEqual(rejoinEvents(f)[0][1].previousMapping, old.get('user_cafe_memberships/staff'));
    const beforeReplay = protectedState(f); await assert.rejects(f.redeem(invite), {code: 'failed-precondition'});
    assert.deepEqual(protectedState(f), beforeReplay);
  });
}
test('return to a previously visited workspace requires explicit audited reactivation', async () => {
  const f = await fixture(); await f.redeem(await f.issue()); await f.remove('ob', 'b', 2);
  const old = structuredClone(f.store.docs.get('cafes/a/members/staff'));
  await f.redeem(await f.issue('oa'));
  assert.equal(f.store.docs.get('user_cafe_memberships/staff').membershipGeneration, 4);
  assert.deepEqual(rejoinEvents(f).at(-1)[1].previousDestinationMember, old);
});
for (const defect of ['legacy', 'default-disabled', 'wrong-uid', 'wrong-generation', 'wrong-workspace-binding',
  'wrong-destination', 'wrong-email', 'unverified', 'expired', 'revoked', 'missing-map', 'inactive-owner',
  'active-staff', 'owner-role', 'bad-schema', 'partial-generation', 'missing-event', 'missing-receipt',
  'bad-event', 'bad-snapshot', 'wrong-remover', 'missing-old-member', 'foreign-destination-member', 'overflow']) {
  test(`rejoin denies ${defect}`, async () => {
    const f = await fixture(); const invite = await f.issue(); const p = `workspace_invitations/${invite.invitationId}`;
    const invitation = f.store.docs.get(p), mapping = f.store.docs.get('user_cafe_memberships/staff');
    const member = f.store.docs.get('cafes/a/members/staff');
    const eventPath = `cafes/a/membership_events/${mapping.removalEventId}`;
    const event = f.store.docs.get(eventPath);
    const options = {};
    if (defect === 'legacy') { delete invitation.bindingVersion; delete invitation.targetUid; delete invitation.targetGeneration; }
    if (defect === 'default-disabled') options.allowRejoin = false;
    if (defect === 'wrong-uid') invitation.targetUid = 'other';
    if (defect === 'wrong-generation') invitation.targetGeneration = 0;
    if (defect === 'wrong-workspace-binding') invitation.previousCafeId = 'c';
    if (defect === 'wrong-destination') invitation.cafeId = 'c';
    if (defect === 'wrong-email') options.auth = {...auth('staff'), token: {email_verified: true, email: 'other@example.test'}};
    if (defect === 'unverified') options.auth = {...auth('staff'), token: {email_verified: false, email: 'staff@example.test'}};
    if (defect === 'expired') invitation.expiresAt = new Date('2029-01-01Z');
    if (defect === 'revoked') invitation.status = 'revoked';
    if (defect === 'missing-map') f.store.docs.delete('user_cafe_memberships/staff');
    if (defect === 'inactive-owner') f.store.docs.get('user_cafe_memberships/ob').status = 'inactive';
    if (defect === 'active-staff') mapping.status = 'active';
    if (defect === 'owner-role') member.role = 'owner';
    if (defect === 'bad-schema') mapping.schemaVersion = 2;
    if (defect === 'partial-generation') delete member.membershipGeneration;
    if (defect === 'missing-event') f.store.docs.delete(eventPath);
    if (defect === 'missing-receipt') f.store.docs.delete(`cafes/a/membership_requests/${event.requestHash}`);
    if (defect === 'bad-event') event.resultGeneration = 4;
    if (defect === 'bad-snapshot') event.previousMember.role = 'owner';
    if (defect === 'wrong-remover') mapping.removedBy = 'other';
    if (defect === 'missing-old-member') f.store.docs.delete('cafes/a/members/staff');
    if (defect === 'foreign-destination-member') f.store.put('cafes/b/members/staff', {...member, cafeId: 'c'});
    if (defect === 'overflow') {
      mapping.membershipGeneration = member.membershipGeneration = Number.MAX_SAFE_INTEGER;
      invitation.targetGeneration = Number.MAX_SAFE_INTEGER;
      event.previousMapping.membershipGeneration = event.previousMember.membershipGeneration = Number.MAX_SAFE_INTEGER - 1;
      for (const record of [event, f.store.docs.get(`cafes/a/membership_requests/${event.requestHash}`)]) {
        record.fromGeneration = Number.MAX_SAFE_INTEGER - 1; record.resultGeneration = Number.MAX_SAFE_INTEGER;
      }
    }
    const before = protectedState(f); await assert.rejects(f.redeem(invite, options));
    assert.deepEqual(protectedState(f), before); assert.equal(rejoinEvents(f).length, 0);
  });
}
test('disabled issuance creates only email invitations that cannot rejoin', async () => {
  const f = await fixture(); const invite = await f.issue('ob', {allowRejoin: false});
  assert.equal(f.store.docs.get(`workspace_invitations/${invite.invitationId}`).bindingVersion, undefined);
  await assert.rejects(f.redeem(invite));
});
test('no client authority fields can select the rejoin identity or generation', async () => {
  const f = await fixture(); const invite = await f.issue();
  for (const extra of [{targetUid: 'staff'}, {targetGeneration: 1}, {cafeId: 'b'}, {role: 'staff'}, {allowRejoin: true}]) {
    await assert.rejects(f.redeem(invite, {data: {code: invite.code, ...extra}}), {code: 'invalid-argument'});
  }
});
for (const sameInvite of [true, false]) {
  test(`concurrent redemption has one winner (same invite ${sameInvite})`, async () => {
    const f = await fixture(); const first = await f.issue(); const second = sameInvite ? first : await f.issue('oc');
    const results = await Promise.allSettled([f.redeem(first), f.redeem(second)]);
    assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
    assert.equal(f.store.docs.get('user_cafe_memberships/staff').membershipGeneration, 2);
    assert.equal(rejoinEvents(f).length, 1); assert.ok(f.store.conflicts > 0);
    assert.equal(f.store.docs.has('cafes/b/members/staff') && f.store.docs.has('cafes/c/members/staff'), false);
  });
}
for (const failWrite of [2, 3, 4, 'commit']) {
  test(`rejoin rollback ${failWrite}`, async () => {
    const f = await fixture(); const invite = await f.issue(); const before = protectedState(f);
    if (failWrite === 'commit') f.store.failCommit = true; else f.store.failWrite = failWrite;
    await assert.rejects(f.redeem(invite)); assert.deepEqual(protectedState(f), before);
  });
}
test('old invitation cannot authorize another rejoin after a later removal', async () => {
  const f = await fixture(); const old = await f.issue('oc');
  await f.redeem(await f.issue('ob')); await f.remove('ob', 'b', 2);
  await assert.rejects(f.redeem(old));
  assert.equal(f.store.docs.get('user_cafe_memberships/staff').membershipGeneration, 3);
});
test('first rejoin write failure rolls back links and invitation after admission', async () => {
  const f = await fixture(); const invite = await f.issue(); const before = protectedState(f);
  f.store.beforeCommit = () => { f.store.failWrite = 1; };
  await assert.rejects(f.redeem(invite)); assert.deepEqual(protectedState(f), before);
});
test('owner invalidation at rejoin commit retries and denies without partial state', async () => {
  const f = await fixture(); const invite = await f.issue();
  const hook = writes => {
    if (![...writes.keys()].some(p => p.includes('/membership_events/rejoin_'))) { f.store.beforeCommit = hook; return; }
    f.store.put('user_cafe_memberships/ob', {...f.store.docs.get('user_cafe_memberships/ob'), status: 'inactive'});
  };
  f.store.beforeCommit = hook;
  await assert.rejects(f.redeem(invite)); assert.ok(f.store.conflicts > 0);
  assert.equal(rejoinEvents(f).length, 0);
  assert.equal(f.store.docs.get('user_cafe_memberships/staff').status, 'inactive');
  assert.equal(f.store.docs.get(`workspace_invitations/${invite.invitationId}`).status, 'pending');
});
test('first-time invitation and legacy active generation-zero behavior remain compatible', async () => {
  const f = await fixture();
  const invitation = await createStaffInvitation({store: f.store, auth: auth('ob'),
    data: {email: 'new@example.test', requestId: 'first-time-request-01'}, now,
    allowRejoin: true, resolveAccount: async () => null});
  const result = await redeemStaffInvitation({store: f.store, auth: auth('new'), data: {code: invitation.code}, now});
  assert.equal(result.cafeId, 'b');
  assert.equal(f.store.docs.get('user_cafe_memberships/new').membershipGeneration, undefined);
  assert.equal(f.store.docs.get('cafes/b/members/new').role, 'staff');
});
for (const defect of ['wrong-uid-email', 'disabled', 'unverified', 'lookup-missing']) {
  test(`bound issuance denies invalid trusted account lookup: ${defect}`, async () => {
    const f = await fixture(); const before = structuredClone(f.store.docs);
    const account = {uid: 'staff', email: 'staff@example.test', emailVerified: true};
    if (defect === 'wrong-uid-email') account.email = 'other@example.test';
    if (defect === 'disabled') account.disabled = true;
    if (defect === 'unverified') account.emailVerified = false;
    await assert.rejects(f.issue('ob', {resolveAccount: defect === 'lookup-missing' ? undefined : async () => account}));
    assert.deepEqual(f.store.docs, before);
  });
}
test('runtime wiring exposes no new rejoin callable or internal opt-in', () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  assert.ok(!source.includes('allowRejoin: true'));
  assert.ok(!/exports\.\w*[Rr]ejoin/.test(source));
  assert.match(source, /createStaffRemovalHandler\(\{\s*enabled: false,/);
});
