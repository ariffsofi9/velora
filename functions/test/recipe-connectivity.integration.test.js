'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const {initializeApp, deleteApp} = require('firebase-admin/app');
const {getFirestore, Timestamp} = require('firebase-admin/firestore');
const {CONNECTIVITY_PROJECT: PROJECT, assertConnectivity} = require('../ai1/recipe-service');

// No default host/project and no clearFirestore/delete/reset/import/export calls.
// Test fixtures are written only after proving the exact disposable environment.
assertConnectivity({...process.env, FUNCTIONS_EMULATOR: 'true'});

test('Fake connectivity: authenticated scoped read-only recipe callable', {timeout: 60000}, async (t) => {
  const app = initializeApp({projectId: PROJECT}, 'ai1-test');
  t.after(() => deleteApp(app));
  const db = getFirestore(app);
  const suffix = randomUUID();
  async function signUp() {
    const response = await fetch('http://127.0.0.1:49099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-only', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({email: `ai1-${randomUUID()}@example.test`,
        password: 'disposable-test-password', returnSecureToken: true}),
    });
    assert.equal(response.status, 200);
    return response.json();
  }
  const owner = await signUp();
  const staff = await signUp();
  const outsider = await signUp();
  const cafeId = `ai1-${suffix}`;
  const inventoryPath = `cafes/${cafeId}/inventory`;
  const membershipPath = `cafes/${cafeId}/members/${staff.localId}`;
  function link(uid, role) {
    return {uid, cafeId, status: 'active', schemaVersion: 1, ...(role ? {role} : {})};
  }
  const batch = db.batch();
  batch.set(db.doc(`cafes/${cafeId}`), {ownerUid: owner.localId, status: 'active', schemaVersion: 1});
  for (const [user, role] of [[owner, 'owner'], [staff, 'staff']]) {
    batch.set(db.doc(`user_cafe_memberships/${user.localId}`), link(user.localId));
    batch.set(db.doc(`cafes/${cafeId}/members/${user.localId}`), link(user.localId, role));
  }
  const base = {category: 'Food', quantity: 2, unit: 'pcs', version: 1, schemaVersion: 1,
    createdAt: Timestamp.now(), expiryDate: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z'))};
  for (const [id, data] of [['banana', {name: 'Banana'}], ['milk', {name: 'Milk'}],
    ['archived', {name: 'Archived', lifecycleState: 'archived', archivedAt: Timestamp.now(), archivedBy: owner.localId}],
    ['expired', {name: 'Expired', expiryDate: Timestamp.fromDate(new Date('2000-01-01T00:00:00Z'))}],
    ['zero', {name: 'Zero', quantity: 0}]]) {
    batch.set(db.doc(`${inventoryPath}/${id}`), {...base, ...data});
  }
  await batch.commit();
  async function invoke(token, extra = {}, requestId = randomUUID()) {
    const response = await fetch(`http://127.0.0.1:45001/${PROJECT}/asia-southeast1/suggestRecipes`, {
      method: 'POST', headers: {'Content-Type': 'application/json',
        ...(token ? {Authorization: `Bearer ${token}`} : {})},
      body: JSON.stringify({data: {requestId, ...extra}}),
    });
    return {status: response.status, body: await response.json()};
  }
  const before = (await db.collection(inventoryPath).get()).docs.map((d) => [d.id, d.data()]);
  const missing = await invoke();
  assert.equal(missing.body.error.status, 'UNAUTHENTICATED');
  const denied = await invoke(outsider.idToken);
  assert.equal(denied.body.error.status, 'PERMISSION_DENIED');
  const crossCafe = await invoke(staff.idToken, {cafeId: 'another-cafe'});
  assert.equal(crossCafe.body.error.status, 'INVALID_ARGUMENT');
  const requestId = randomUUID();
  const good = await invoke(staff.idToken, {}, requestId);
  assert.equal(good.status, 200);
  assert.equal(good.body.result.provider, 'fake');
  assert.equal(good.body.result.status, 'ok');
  assert.deepEqual(good.body.result.recipes[0].ingredientItemIds, ['banana', 'milk']);
  const ownerResult = await invoke(owner.idToken);
  assert.equal(ownerResult.body.result.provider, 'fake');
  assert.equal(good.body.result.schemaVersion, 1);
  assert.ok(!Object.hasOwn(good.body.result.recipes[0], 'ingredients'));
  const duplicate = await invoke(staff.idToken, {}, requestId);
  assert.equal(duplicate.body.error.status, 'ALREADY_EXISTS');
  assert.deepEqual((await db.collection(inventoryPath).get()).docs.map((d) => [d.id, d.data()]), before);
  for (const path of [`cafes/${cafeId}/ai_cache`, `cafes/${cafeId}/ai_quota`,
    `cafes/${cafeId}/ai_recipe_suggestions`, 'ai_cache', 'ai_quota', 'ai_recipe_suggestions']) {
    assert.equal((await db.collection(path).get()).empty, true);
  }
  await db.doc(membershipPath).update({status: 'revoked'});
  const revoked = await invoke(staff.idToken);
  assert.equal(revoked.body.error.status, 'PERMISSION_DENIED');
  await db.doc(membershipPath).update({status: 'active', cafeId: 'another-cafe'});
  const inconsistent = await invoke(staff.idToken);
  assert.equal(inconsistent.body.error.status, 'PERMISSION_DENIED');
  // Fixtures intentionally remain until this disposable emulator process exits.
});
