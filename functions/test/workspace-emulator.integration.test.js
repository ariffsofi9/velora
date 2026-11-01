'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {initializeApp} = require('firebase-admin/app');
const {getFirestore} = require('firebase-admin/firestore');

const projectId = process.env.GCLOUD_PROJECT || 'demo-velora-workspaces';

async function createEmulatorUser() {
  const response = await fetch(
    'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key',
    {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({
        email: `workspace-owner-${Date.now()}@example.test`,
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

async function callCreateInventoryItem(idToken, data = {}) {
  const response = await fetch(
    `http://127.0.0.1:5001/${projectId}/asia-southeast1/createInventoryItem`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${idToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        data: {
          idempotencyKey: 'integration-request-0001',
          name: 'Fresh Milk',
          category: 'Dairy',
          quantity: 4,
          unit: 'L',
          expiryDate: '2030-01-02T00:00:00.000Z',
          imageUrl: '',
          ...data,
        },
      }),
    },
  );
  const body = await response.json();
  return {ok: response.ok, body};
}

async function callUpdateInventoryItem(idToken, itemId, data = {}) {
  const response = await fetch(
    `http://127.0.0.1:5001/${projectId}/asia-southeast1/updateInventoryItem`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${idToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        data: {
          idempotencyKey: 'integration-update-0001',
          itemId,
          expectedVersion: 1,
          name: 'Fresh Whole Milk',
          ...data,
        },
      }),
    },
  );
  const body = await response.json();
  return {ok: response.ok, body};
}

async function callAdjustInventoryStock(idToken, itemId, data = {}) {
  const response = await fetch(
    `http://127.0.0.1:5001/${projectId}/asia-southeast1/adjustInventoryStock`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${idToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        data: {
          idempotencyKey: 'integration-stock-in-0001',
          itemId,
          direction: 'in',
          quantity: 3,
          expectedVersion: 2,
          reason: 'Supplier delivery',
          ...data,
        },
      }),
    },
  );
  const body = await response.json();
  return {ok: response.ok, body};
}

async function attemptDirectInventoryWrite(idToken, cafeId) {
  return fetch(
    `http://127.0.0.1:8080/v1/projects/${projectId}/databases/(default)/documents/cafes/${cafeId}/inventory/direct-client-write`,
    {
      method: 'PATCH',
      headers: {
        authorization: `Bearer ${idToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        fields: {name: {stringValue: 'Forbidden client item'}},
      }),
    },
  );
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

  const directWrite = await attemptDirectInventoryWrite(
    user.idToken,
    first.cafeId,
  );
  assert.equal(directWrite.ok, false);

  const created = await callCreateInventoryItem(user.idToken);
  const retryItem = await callCreateInventoryItem(user.idToken);
  assert.equal(created.ok, true, JSON.stringify(created.body.error || {}));
  assert.equal(created.body.result.created, true);
  assert.equal(retryItem.body.result.created, false);
  assert.equal(retryItem.body.result.itemId, created.body.result.itemId);

  const cafeId = first.cafeId;
  const itemId = created.body.result.itemId;
  const item = await db.doc(`cafes/${cafeId}/inventory/${itemId}`).get();
  const movements = await db
    .collection(`cafes/${cafeId}/inventory_movements`)
    .get();
  const activities = await db.collection(`cafes/${cafeId}/activities`).get();
  assert.equal(item.data().createdBy, user.localId);
  assert.equal(item.data().quantity, 4);
  assert.equal(movements.size, 1);
  assert.equal(activities.size, 1);

  const changedRetry = await callCreateInventoryItem(user.idToken, {
    quantity: 5,
  });
  assert.equal(changedRetry.ok, false);
  assert.equal(changedRetry.body.error.status, 'ALREADY_EXISTS');

  const updated = await callUpdateInventoryItem(user.idToken, itemId);
  const updateRetry = await callUpdateInventoryItem(user.idToken, itemId);
  assert.equal(updated.ok, true, JSON.stringify(updated.body.error || {}));
  assert.equal(updated.body.result.updated, true);
  assert.equal(updated.body.result.version, 2);
  assert.deepEqual(updateRetry.body.result, updated.body.result);

  const updatedItem = await db.doc(
    `cafes/${cafeId}/inventory/${itemId}`,
  ).get();
  const movementsAfterUpdate = await db
    .collection(`cafes/${cafeId}/inventory_movements`)
    .get();
  const activitiesAfterUpdate = await db
    .collection(`cafes/${cafeId}/activities`)
    .get();
  assert.equal(updatedItem.data().name, 'Fresh Whole Milk');
  assert.equal(updatedItem.data().quantity, 4);
  assert.equal(updatedItem.data().version, 2);
  assert.equal(movementsAfterUpdate.size, 1);
  assert.equal(activitiesAfterUpdate.size, 2);
  const updateAudit = activitiesAfterUpdate.docs.find(
    (document) => document.data().type === 'inventory_updated',
  );
  assert.ok(updateAudit);
  assert.equal(updateAudit.data().actorUid, user.localId);

  const changedUpdateRetry = await callUpdateInventoryItem(
    user.idToken,
    itemId,
    {name: 'Changed with reused key'},
  );
  assert.equal(changedUpdateRetry.ok, false);
  assert.equal(changedUpdateRetry.body.error.status, 'ALREADY_EXISTS');

  const staleUpdate = await callUpdateInventoryItem(user.idToken, itemId, {
    idempotencyKey: 'integration-update-0002',
    name: 'Stale edit',
  });
  assert.equal(staleUpdate.ok, false);
  assert.equal(staleUpdate.body.error.status, 'ABORTED');

  const stockIn = await callAdjustInventoryStock(user.idToken, itemId);
  const stockInRetry = await callAdjustInventoryStock(user.idToken, itemId);
  assert.equal(stockIn.ok, true, JSON.stringify(stockIn.body.error || {}));
  assert.equal(stockIn.body.result.adjusted, true);
  assert.equal(stockIn.body.result.resultingQuantity, 7);
  assert.equal(stockIn.body.result.version, 3);
  assert.equal(stockInRetry.ok, true);
  assert.equal(stockInRetry.body.result.adjusted, false);
  assert.equal(stockInRetry.body.result.resultingQuantity, 7);
  assert.equal(stockInRetry.body.result.version, 3);

  const changedStockRetry = await callAdjustInventoryStock(
    user.idToken,
    itemId,
    {quantity: 4},
  );
  assert.equal(changedStockRetry.ok, false);
  assert.equal(changedStockRetry.body.error.status, 'ALREADY_EXISTS');

  const stockOut = await callAdjustInventoryStock(user.idToken, itemId, {
    idempotencyKey: 'integration-stock-out-001',
    direction: 'out',
    quantity: 2,
    expectedVersion: 3,
    reason: 'Kitchen use',
  });
  assert.equal(stockOut.ok, true, JSON.stringify(stockOut.body.error || {}));
  assert.equal(stockOut.body.result.resultingQuantity, 5);
  assert.equal(stockOut.body.result.version, 4);

  const staleStock = await callAdjustInventoryStock(user.idToken, itemId, {
    idempotencyKey: 'integration-stale-stock-01',
    direction: 'out',
    quantity: 1,
    expectedVersion: 3,
  });
  assert.equal(staleStock.ok, false);
  assert.equal(staleStock.body.error.status, 'ABORTED');

  const stockedItem = await db.doc(
    `cafes/${cafeId}/inventory/${itemId}`,
  ).get();
  const movementsAfterStock = await db
    .collection(`cafes/${cafeId}/inventory_movements`)
    .get();
  const activitiesAfterStock = await db
    .collection(`cafes/${cafeId}/activities`)
    .get();
  assert.equal(stockedItem.data().quantity, 5);
  assert.equal(stockedItem.data().version, 4);
  assert.equal(movementsAfterStock.size, 3);
  assert.equal(activitiesAfterStock.size, 4);
  assert.equal(
    movementsAfterStock.docs.filter(
      (document) => document.data().type === 'stock_in',
    ).length,
    1,
  );
  assert.ok(
    activitiesAfterStock.docs.find(
      (document) => document.data().type === 'inventory_stock_adjusted',
    ),
  );
  console.log(`EMULATOR_TEST_CAFE_ID=${cafeId}`);
});
