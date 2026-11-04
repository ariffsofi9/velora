'use strict';

const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {initializeApp} = require('firebase-admin/app');
const {getFirestore} = require('firebase-admin/firestore');
const {getAuth} = require('firebase-admin/auth');
const {PROJECT, RecipeError, assertIsolated, createRecipeService} = require('./recipe-service');
const {fakeProvider} = require('./fake-provider');
const {selectProvider} = require('./groq-provider');

let service;
let auth;
function localService() {
  // Guard before Admin initialization; this source is absent from production config.
  assertIsolated();
  if (!service) {
    const selected = selectProvider({fakeProvider});
    const app = initializeApp({projectId: PROJECT}, 'ai1-demo');
    const db = getFirestore(app);
    auth = getAuth(app);
    service = createRecipeService({
      ...selected,
      verifyIdentity: async (uid) => {
        const user = await auth.getUser(uid);
        if (user.disabled) throw new RecipeError('unauthenticated', 'Disposable identity disabled.');
      },
      store: {runTransaction: (operation) => db.runTransaction(async (transaction) => operation({
        get: async (path) => {
          const doc = await transaction.get(db.doc(path));
          return doc.exists ? doc.data() : null;
        },
        inventory: async (path, limit) => {
          const docs = await transaction.get(db.collection(path).limit(limit));
          return docs.docs.map((doc) => ({id: doc.id, data: doc.data()}));
        },
      }), {readOnly: true})},
    });
  }
  return service;
}

exports.suggestRecipes = onCall({region: 'asia-southeast1', timeoutSeconds: 30,
  maxInstances: 1, cors: [/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/]}, async (request) => {
  try {
    const invoke = localService();
    const header = request.rawRequest.headers.authorization;
    if (!request.auth || typeof header !== 'string' || !header.startsWith('Bearer ')) {
      throw new RecipeError('unauthenticated', 'Authentication required.');
    }
    const token = await auth.verifyIdToken(header.slice(7));
    if (token.uid !== request.auth.uid || token.aud !== PROJECT ||
        token.iss !== `https://securetoken.google.com/${PROJECT}`) {
      throw new RecipeError('unauthenticated', 'Invalid disposable identity.');
    }
    return await invoke({auth: {uid: token.uid}, data: request.data});
  } catch (error) {
    if (error instanceof RecipeError) throw new HttpsError(error.code, error.message);
    // No raw errors, auth tokens, inventory or provider data in logs/responses.
    throw new HttpsError('unavailable', 'AI-1 request could not be verified or completed.');
  }
});
