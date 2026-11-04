'use strict';

const {initializeApp} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const invitations = require('./workspace-invitations');
const {listTeamMembers, TeamMembersError} = require('./team-members');
const {getFirestore, FieldValue, Timestamp, FieldPath} = require('firebase-admin/firestore');
const {menuOperation} = require('./menu-service');
const {MenuError} = require('./menu-model');
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
      members: async (cafeId, limit) => {
        const snapshot = await adminTransaction.get(db.collection(`cafes/${cafeId}/members`).limit(limit));
        return snapshot.docs.map(doc => ({id: doc.id, data: doc.data()}));
      },
      menuItems: async (cafeId, input) => {
        let query = db.collection(`cafes/${cafeId}/menu_items`);
        if (!input.includeArchived) query = query.where('isArchived', '==', false);
        query = query.orderBy(FieldPath.documentId()).limit(input.limit + 1);
        if (input.cursor) query = query.startAfter(input.cursor);
        const snapshot = await adminTransaction.get(query);
        return snapshot.docs.map(doc => ({id: doc.id, data: doc.data()}));
      },
    };
    return operation(transaction);
  }),
};

for (const [name, operation] of Object.entries({createMenuItem: 'create', getMenuItem: 'get',
  listMenuItems: 'list', updateMenuItem: 'update', setMenuItemLifecycle: 'lifecycle'})) {
  exports[name] = onCall({region: 'asia-southeast1', timeoutSeconds: 30}, async request => {
    try {
      if (!request.auth) throw new MenuError('unauthenticated', 'Sign in to continue.');
      const account = await getAuth().getUser(request.auth.uid);
      if (account.disabled) throw new MenuError('unauthenticated', 'Sign in to continue.');
      return await menuOperation({operation, auth: request.auth, data: request.data, store,
        timestamp: () => FieldValue.serverTimestamp()});
    } catch (error) {
      if (error instanceof MenuError) throw new HttpsError(error.code, error.message);
      throw new HttpsError('unavailable', 'Menu operation unavailable. Please retry.');
    }
  });
}

exports.listTeamMembers = onCall({region: 'asia-southeast1', timeoutSeconds: 30}, async request => {
  try {
    return await listTeamMembers({auth: request.auth, data: request.data, store,
      accounts: async uids => (await getAuth().getUsers(uids.map(uid => ({uid})))).users});
  } catch (error) {
    if (error instanceof TeamMembersError) throw new HttpsError(error.code, error.message);
    throw new HttpsError('unavailable', 'Team members are unavailable. Please retry.');
  }
});

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


for (const name of ['createStaffInvitation', 'revokeStaffInvitation', 'redeemStaffInvitation']) {
  exports[name] = onCall({region: 'asia-southeast1', timeoutSeconds: 30}, async (request) => {
    try {
      if (!request.auth) throw new invitations.InvitationError('unauthenticated', 'Sign in to continue.');
      // Fresh account state supplements the verified callable token claims.
      const user = await getAuth().getUser(request.auth.uid);
      if (user.disabled) throw new invitations.InvitationError('unauthenticated', 'Sign in to continue.');
      if (name === 'redeemStaffInvitation' && (!user.emailVerified ||
          user.email?.trim().toLowerCase() !== request.auth.token.email?.trim().toLowerCase())) {
        throw new invitations.InvitationError('failed-precondition', 'Verify your email and refresh your sign-in.');
      }
      return await invitations[name]({auth: request.auth, data: request.data, store,
        toTimestamp: (date) => Timestamp.fromDate(date)});
    } catch (error) {
      if (error instanceof invitations.InvitationError) throw new HttpsError(error.code, error.message);
      // Never log request data, codes, emails or provider/internal exception objects.
      throw new HttpsError('unavailable', 'Invitation operation could not be completed.');
    }
  });
}
