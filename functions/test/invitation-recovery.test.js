'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const invitations = require('../src/workspace-invitations');
const {fixture} = require('./helpers/shared-backend-fakes.cjs');
const context = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const requestId = 'request_123456789';
const receiptPath = 'workspace_invite_requests/' + createHash('sha256').update(`owner\0${requestId}`).digest('hex');
function setup() {
  const f = fixture();
  const common = {auth: {uid: 'owner', token: f.claims('owner')}, store: f.store, now: () => new Date(f.now())};
  const create = (id = requestId) => invitations.createStaffInvitation({...common,
    data: {...context, requestId: id, email: 'joiner@example.test'}});
  const reconcile = async (data = {...context, requestId}, auth = common.auth) => {
    const before = f.store.snapshot(); let writes = 0;
    const observed = {runTransaction: action => f.store.runTransaction(tx => action(new Proxy(tx, {
      get(target, method) {
        if (method === 'get') return target.get;
        return () => {writes++; throw Error('reconciliation must be read-only');};
      },
    })))};
    try { return await invitations.reconcileStaffInvitation({...common, auth, data, store: observed}); }
    finally { assert.equal(writes, 0); assert.deepEqual(f.store.snapshot(), before); }
  };
  return {...f, common, create, reconcile};
}
test('missing receipt remains unknown, including before a later original commit', async () => {
  const f = setup();
  assert.deepEqual(await f.reconcile(), {state: 'unknown'});
  await f.create(); // Original creation finishing later, not a recovery replay.
  assert.deepEqual(await f.reconcile(), {state: 'committed', invitationState: 'pending'});
});
test('applied commit with lost response is observed without returning its secret', async () => {
  const f = setup(); const run = f.store.runTransaction.bind(f.store);
  f.store.runTransaction = async action => {await run(action); throw Object.assign(Error('response lost'), {uncertain: true});};
  await assert.rejects(f.create()); f.store.runTransaction = run;
  assert.deepEqual(await f.reconcile(), {state: 'committed', invitationState: 'pending'});
});
for (const status of ['revoked', 'redeemed', 'expired']) test(`minimal ${status} state, zero writes`, async () => {
  const f = setup(); const inv = await f.create();
  if (status === 'revoked') await invitations.revokeStaffInvitation({...f.common, data: {...context, invitationId: inv.invitationId}});
  if (status === 'redeemed') await invitations.redeemStaffInvitation({...f.common,
    auth: {uid: 'joiner', token: f.claims('joiner')}, data: {code: inv.code}});
  if (status === 'expired') f.advance(24 * 60 * 60 * 1000);
  const response = await f.reconcile();
  assert.deepEqual(response, {state: 'committed', invitationState: status});
  assert.equal(JSON.stringify(response).includes(inv.code), false);
  assert.equal(JSON.stringify(response).includes('joiner'), false);
});
for (const [name, change] of [
  ['cross-workspace', {expectedCafeId: 'other'}], ['stale generation', {expectedMembershipGeneration: 7}],
  ['forged receipt path', {receiptPath}], ['forged identity', {uid: 'owner'}],
]) test(`${name} fails closed`, async () => {
  const f = setup(); await f.create();
  await assert.rejects(f.reconcile({...context, requestId, ...change}));
});
test('unauthorized, unverified and absent identities cannot look up receipts', async () => {
  const f = setup(); await f.create();
  for (const auth of [null, {uid: 'staff', token: f.claims('staff')}, {uid: 'outsider', token: f.claims('outsider')},
    {uid: 'owner', token: {...f.claims('owner'), email_verified: false}}]) await assert.rejects(f.reconcile(undefined, auth));
});
for (const corruption of ['wrong-uid', 'wrong-cafe', 'bad-link', 'missing-invitation', 'missing-issuer', 'stale-issuer', 'bad-time', 'bad-status']) {
  test(`corrupt ${corruption} never discloses receipt data`, async () => {
    const f = setup(); const inv = await f.create(); const path = 'workspace_invitations/' + inv.invitationId;
    await f.store.runTransaction(async tx => {
      if (corruption === 'wrong-uid') tx.update(receiptPath, {uid: 'other'});
      if (corruption === 'wrong-cafe') tx.update(receiptPath, {cafeId: 'other'});
      if (corruption === 'bad-link') tx.update(receiptPath, {invitationId: '../other'});
      if (corruption === 'missing-invitation') tx.delete(path);
      if (corruption === 'missing-issuer') tx.update(path, {issuerBindingVersion: undefined});
      if (corruption === 'stale-issuer') tx.update(path, {issuerMembershipGeneration: 7});
      if (corruption === 'bad-time') tx.update(path, {expiresAt: null});
      if (corruption === 'bad-status') tx.update(path, {status: 'active'});
    });
    await assert.rejects(f.reconcile());
  });
}
test('duplicate ID remains rejected; different device IDs are independent', async () => {
  const f = setup(); await f.create();
  await assert.rejects(f.create(), e => e.code === 'already-exists');
  const other = 'device2_123456789'; await f.create(other);
  assert.deepEqual(await f.reconcile({...context, requestId: other}), {state: 'committed', invitationState: 'pending'});
  assert.equal(Object.keys(f.store.snapshot()).filter(p => p.startsWith('workspace_invitations/')).length, 2);
});
test('generation change rejects old context, while fresh context cannot adopt old issuer', async () => {
  const f = setup(); await f.create();
  await f.store.runTransaction(async tx => {
    tx.update('user_cafe_memberships/owner', {membershipGeneration: 7});
    tx.update('cafes/cafe/members/owner', {membershipGeneration: 7});
  });
  await assert.rejects(f.reconcile(), e => e.code === 'failed-precondition');
  await assert.rejects(f.reconcile({...context, expectedMembershipGeneration: 7, requestId}));
});
test('HTTP reconciliation is authenticated, project-bound, minimal and read-only', async () => {
  const f = setup(); await f.create();
  const {createInvitationHttp} = await import('../https/invitation-http.mjs');
  const {createIdentity} = await import('../feasibility/shared-backend/identity.mjs');
  const handler = createInvitationHttp({projectId: 'velora-spark-test', storeProjectId: 'velora-spark-test',
    verifyIdentity: createIdentity(f.identity), store: f.store, now: f.common.now});
  const before = f.store.snapshot();
  for (const [token, expected] of [[f.token(), 200], [f.token('owner', {aud: 'velora-73222'}), 401], ['', 401]]) {
    const response = await handler(new Request('https://offline.invalid/staff/reconcile', {method: 'POST',
      headers: {'content-type': 'application/json', authorization: 'Bearer ' + token},
      body: JSON.stringify({...context, requestId})}));
    assert.equal(response.status, expected);
    if (expected === 200) assert.deepEqual(await response.json(), {state: 'committed', invitationState: 'pending'});
    assert.deepEqual(f.store.snapshot(), before);
  }
});
