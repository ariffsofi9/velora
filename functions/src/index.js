'use strict';

const {initializeApp} = require('firebase-admin/app');
const {getFirestore, FieldValue, Timestamp} = require('firebase-admin/firestore');
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {createWorkspace, WorkspaceCreationError} = require('./workspace-creation');
const {
  createInventoryItem,
  InventoryCreationError,
} = require('./inventory-create');
const {
  updateInventoryItem,
  InventoryUpdateError,
} = require('./inventory-update');
const {
  adjustInventoryStock,
  InventoryStockError,
} = require('./inventory-stock');
const {
  setInventoryLifecycle,
  InventoryLifecycleError,
} = require('./inventory-lifecycle');

initializeApp();
const db = getFirestore();

const store = {
  runTransaction: (operation) => db.runTransaction(async (adminTransaction) => {
    const transaction = {
      get: async (path) => {
        const snapshot = await adminTransaction.get(db.doc(path));
        return snapshot.exists ? snapshot.data() : null;
      },
      create: (path, data) => adminTransaction.create(db.doc(path), data),
      update: (path, data) => adminTransaction.update(db.doc(path), data),
    };
    return operation(transaction);
  }),
};

exports.createWorkspace = onCall(
  {region: 'asia-southeast1', timeoutSeconds: 30},
  async (request) => {
    try {
      return await createWorkspace({
        auth: request.auth,
        data: request.data,
        store,
        idFactory: () => db.collection('cafes').doc().id,
        timestamp: () => FieldValue.serverTimestamp(),
      });
    } catch (error) {
      if (error instanceof WorkspaceCreationError) {
        throw new HttpsError(error.code, error.message);
      }
      console.error('Workspace creation failed without exposing input data.', error);
      throw new HttpsError('internal', 'Workspace creation failed.');
    }
  },
);

exports.createInventoryItem = onCall(
  {region: 'asia-southeast1', timeoutSeconds: 30},
  async (request) => {
    try {
      return await createInventoryItem({
        auth: request.auth,
        data: request.data,
        store,
        timestamp: () => FieldValue.serverTimestamp(),
        toTimestamp: (date) => Timestamp.fromDate(date),
      });
    } catch (error) {
      if (error instanceof InventoryCreationError) {
        throw new HttpsError(error.code, error.message);
      }
      console.error(
        'Inventory creation failed without exposing request data.',
        error,
      );
      throw new HttpsError('internal', 'Inventory creation failed.');
    }
  },
);

exports.updateInventoryItem = onCall(
  {region: 'asia-southeast1', timeoutSeconds: 30},
  async (request) => {
    try {
      return await updateInventoryItem({
        auth: request.auth,
        data: request.data,
        store,
        timestamp: () => FieldValue.serverTimestamp(),
        toTimestamp: (date) => Timestamp.fromDate(date),
      });
    } catch (error) {
      if (error instanceof InventoryUpdateError) {
        throw new HttpsError(error.code, error.message);
      }
      console.error(
        'Inventory update failed without exposing request data.',
        error,
      );
      throw new HttpsError('internal', 'Inventory update failed.');
    }
  },
);

exports.adjustInventoryStock = onCall(
  {region: 'asia-southeast1', timeoutSeconds: 30},
  async (request) => {
    try {
      return await adjustInventoryStock({
        auth: request.auth,
        data: request.data,
        store,
        timestamp: () => FieldValue.serverTimestamp(),
      });
    } catch (error) {
      if (error instanceof InventoryStockError) {
        throw new HttpsError(error.code, error.message);
      }
      console.error(
        'Stock adjustment failed without exposing request data.',
        error,
      );
      throw new HttpsError('internal', 'Stock adjustment failed.');
    }
  },
);

exports.setInventoryLifecycle = onCall(
  {region: 'asia-southeast1', timeoutSeconds: 30},
  async (request) => {
    try {
      return await setInventoryLifecycle({
        auth: request.auth,
        data: request.data,
        store,
        timestamp: () => FieldValue.serverTimestamp(),
        deleteValue: () => FieldValue.delete(),
      });
    } catch (error) {
      if (error instanceof InventoryLifecycleError) {
        throw new HttpsError(error.code, error.message);
      }
      console.error('Inventory lifecycle update failed.', error);
      throw new HttpsError('internal', 'Inventory lifecycle update failed.');
    }
  },
);
