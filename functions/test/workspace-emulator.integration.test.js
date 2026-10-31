'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {initializeApp} = require('firebase-admin/app');
const {getFirestore} = require('firebase-admin/firestore');

const projectId = 'demo-velora-workspaces';

async function createEmulatorUser() {
  const response = await fetch(
    'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key',
    {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({
        email: 'workspace-owner@example.test',
        password: 'local-test-password',
        returnSecureToken: true,
      }),
    },
  );
  assert.equal(response.ok, true);
  return response.json();
}

async function callCreateWorkspace(idToken) {
  const response = await fetch(
    `http://127.0.0.1:5001/${projectId}/asia-southeast1/createWorkspace`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${idToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        data: {
          businessName: 'Emulator Kitchen',
          businessType: 'Cloud Kitchen',
          address: '',
          inventoryUnit: 'kg',
          lowStockAlerts: true,
          expiryReminders: true,
          reminderDays: 3,
        },
      }),
    },
  );
  const body = await response.json();
  assert.equal(response.ok, true, JSON.stringify(body.error || {}));
  return body.result;
}

test('authenticated callable creates one resolver-compatible workspace', async () => {
  assert.equal(process.env.GCLOUD_PROJECT, projectId);
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST);
  assert.ok(process.env.FIREBASE_AUTH_EMULATOR_HOST);

  const user = await createEmulatorUser();
  const first = await callCreateWorkspace(user.idToken);
  const retry = await callCreateWorkspace(user.idToken);

  assert.equal(first.created, true);
  assert.equal(retry.created, false);
  assert.equal(retry.cafeId, first.cafeId);

  const app = initializeApp({projectId}, 'workspace-integration-test');
  const db = getFirestore(app);
  const mapping = await db.doc(`user_cafe_memberships/${user.localId}`).get();
  const cafe = await db.doc(`cafes/${first.cafeId}`).get();
  const member = await db
    .doc(`cafes/${first.cafeId}/members/${user.localId}`)
    .get();

  assert.equal(mapping.data().cafeId, first.cafeId);
  assert.equal(cafe.data().ownerUid, user.localId);
  assert.equal(member.data().role, 'owner');
});
