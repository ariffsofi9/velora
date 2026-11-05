'use strict';
// Test-only schema-v2 provider. No Groq adapter, key, relay or external I/O.
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {initializeApp} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const {getFirestore} = require('firebase-admin/firestore');
const {PROJECT, RecipeError, assertIsolated, createRecipeService} = require('./recipe-service');
const {verifyRequestIdentity} = require('./request-identity');
function assertMock(env = process.env) {
  assertIsolated(env);
  if (env.AI1_MOCK_RECIPES !== 'true' || env.AI_RECIPE_PROVIDER !== 'fake' || env.AI2_PROVIDER_PIPE || env.AI2_RELAY_CREDENTIAL) {
    throw new RecipeError('failed-precondition', 'Isolated AI1 mock profile required.');
  }
}
async function mockProvider({items}) {
  const banana = items.find(i => i.name.toLowerCase() === 'banana');
  const milk = items.find(i => i.name.toLowerCase() === 'milk');
  if (!banana || !milk) return [];
  return [{title: 'Mock Banana Milk Smoothie', ingredients: [
    {itemId: banana.id, quantity: Math.min(banana.quantity, 1), unit: banana.unit},
    {itemId: milk.id, quantity: Math.min(milk.quantity, milk.unit === 'L' ? 0.25 : 1), unit: milk.unit}],
    steps: ['Combine the synthetic fixture ingredients.'], whyRecommended: 'Mock fixture only; not real Groq output.'}];
}
let service;
function localService() {
  assertMock();
  if (!service) {
    const app = initializeApp({projectId: PROJECT}, 'ai1-mock-v2');
    const auth = getAuth(app), db = getFirestore(app);
    service = createRecipeService({providerName: 'groq', provider: mockProvider,
      verifyIdentity: (uid, identity) => verifyRequestIdentity(auth, uid, identity),
      store: {runTransaction: operation => db.runTransaction(tx => operation({
        get: async path => { const row = await tx.get(db.doc(path)); return row.exists ? row.data() : null; },
        inventory: async (path, limit) => (await tx.get(db.collection(path).limit(limit))).docs.map(row => ({id: row.id, data: row.data()})),
      }), {readOnly: true})}});
  }
  return service;
}
const suggestMockRecipesV2 = onCall({region: 'asia-southeast1', timeoutSeconds: 30, maxInstances: 1,
  cors: [/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/]}, async request => {
  try {
    const invoke = localService();
    const header = request.rawRequest.headers.authorization;
    if (!request.auth || typeof header !== 'string' || !header.startsWith('Bearer ')) throw new RecipeError('unauthenticated', 'Authentication required.');
    return await invoke({auth: {uid: request.auth.uid, bearer: header.slice(7)}, data: request.data});
  } catch (error) {
    if (error instanceof RecipeError) throw new HttpsError(error.code, error.message);
    throw new HttpsError('unavailable', 'Mock recipe request unavailable.');
  }
});
module.exports = {suggestMockRecipesV2, assertMock, mockProvider};
