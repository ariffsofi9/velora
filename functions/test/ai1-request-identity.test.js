'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {verifyRequestIdentity} = require('../ai1/request-identity');
const {PROJECT, HOSTS, createRecipeService} = require('../ai1/recipe-service');
const identity = {uid: 'staff', bearer: 'synthetic-token'};
const token = () => ({uid: 'staff', sub: 'staff', aud: PROJECT,
  iss: `https://securetoken.google.com/${PROJECT}`, auth_time: 1000});
function setup() {
  const user = {disabled: false, tokensValidAfterTime: new Date(999000).toISOString()};
  const claims = token(); let rejected = false;
  const auth = {verifyIdToken: async (bearer, revoked) => {
    assert.equal(bearer, identity.bearer); assert.equal(revoked, true);
    if (rejected) throw Error('PRIVATE token'); return claims;
  }, getUser: async uid => { assert.equal(uid, identity.uid); return user; }};
  return {auth, user, claims, reject: () => { rejected = true; }};
}
const denied = error => error.code === 'unauthenticated' && !error.message.includes('PRIVATE');
test('valid request-bound identity uses explicit SDK revocation verification', async () => {
  await verifyRequestIdentity(setup().auth, 'staff', identity);
});
for (const state of ['revoked', 'disabled', 'sdk-revoked', 'wrong-project', 'wrong-issuer', 'wrong-sub', 'missing-auth-time', 'bad-cutoff', 'missing-bearer']) {
  test(`reject request identity: ${state}`, async () => {
    const s = setup();
    if (state === 'revoked') s.user.tokensValidAfterTime = new Date(1001000).toISOString();
    if (state === 'disabled') s.user.disabled = true;
    if (state === 'sdk-revoked') s.reject();
    if (state === 'wrong-project') s.claims.aud = 'other';
    if (state === 'wrong-issuer') s.claims.iss = 'other';
    if (state === 'wrong-sub') s.claims.sub = 'other';
    if (state === 'missing-auth-time') delete s.claims.auth_time;
    if (state === 'bad-cutoff') s.user.tokensValidAfterTime = 'invalid';
    await assert.rejects(verifyRequestIdentity(s.auth, 'staff', state === 'missing-bearer' ? {uid: 'staff'} : identity), denied);
  });
}
for (const phase of ['before', 'after']) {
  for (const state of ['revoked', 'disabled']) {
    test(`${state} ${phase} provider prevents successful result`, async () => {
      const s = setup(); let calls = 0;
      const change = () => { if (state === 'disabled') s.user.disabled = true;
        else s.user.tokensValidAfterTime = new Date(1001000).toISOString(); };
      const link = uid => ({uid, cafeId: 'cafe', status: 'active', schemaVersion: 1});
      const docs = {'user_cafe_memberships/staff': link('staff'), 'user_cafe_memberships/owner': link('owner'),
        'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1},
        'cafes/cafe/members/staff': {...link('staff'), role: 'staff'},
        'cafes/cafe/members/owner': {...link('owner'), role: 'owner'}};
      const invoke = createRecipeService({env: {GCLOUD_PROJECT: PROJECT, FUNCTIONS_EMULATOR: 'true', ...HOSTS},
        verifyIdentity: (uid, request) => verifyRequestIdentity(s.auth, uid, request),
        store: {runTransaction: async fn => fn({get: async path => docs[path], inventory: async () => [{id: 'milk', data: {
          name: 'Milk', category: 'Food', quantity: 2, unit: 'L', version: 1, schemaVersion: 1,
          createdAt: new Date('2026-01-01Z'), expiryDate: new Date('2099-01-01Z')}}]})},
        provider: async () => { calls++; if (phase === 'after') change(); return []; }});
      if (phase === 'before') change();
      await assert.rejects(invoke({auth: identity, data: {requestId: 'identity-test-0001'}}), denied);
      assert.equal(calls, phase === 'before' ? 0 : 1);
    });
  }
}
