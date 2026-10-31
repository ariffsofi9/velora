'use strict';

const {initializeApp} = require('firebase-admin/app');
const {getFirestore, FieldValue} = require('firebase-admin/firestore');
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {createWorkspace, WorkspaceCreationError} = require('./workspace-creation');

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
