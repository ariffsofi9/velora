'use strict';

const {randomUUID} = require('node:crypto');
const {isDeepStrictEqual} = require('node:util');
const {PROJECT, assertIsolated, validateRecipes} = require('./recipe-service');
const PREFIX = 'AI2_SMOKE_RESULT ';
const SAFE_CODES = ['UNAUTHENTICATED', 'PERMISSION_DENIED', 'FAILED_PRECONDITION',
  'RESOURCE_EXHAUSTED', 'DEADLINE_EXCEEDED', 'UNAVAILABLE', 'INTERNAL', 'ABORTED'];
function ensure(value) { if (!value) throw Error('SMOKE_VALIDATION_FAILED'); }
function assertSmokeEnvironment(env) {
  assertIsolated({...env, FUNCTIONS_EMULATOR: 'true'});
  ensure(env.AI2_LIVE_SMOKE === 'true' && env.AI_RECIPE_PROVIDER === 'groq');
}
function safeTitles(value) {
  ensure(Array.isArray(value) && value.length >= 1 && value.length <= 3);
  return value.map((title) => {
    // Only short printable title text; no terminal controls or arbitrary metadata.
    ensure(typeof title === 'string' && title.length <= 100 && title.trim().length > 0 &&
      /^[\p{L}\p{N} ,.'()&-]+$/u.test(title));
    return title;
  });
}
function validateSmokeResult(result, requestId, stock) {
  ensure(result && Object.keys(result).sort().join(',') === 'provider,recipes,requestId,schemaVersion,status');
  ensure(result.schemaVersion === 2 && result.provider === 'groq' &&
    result.requestId === requestId && result.status === 'ok');
  const recipes = validateRecipes(result.recipes, stock, 1, 'groq');
  ensure(recipes.length === 1);
  return safeTitles(recipes.map((recipe) => recipe.title));
}

// No API-key access here. The live adapter remains in the parent launcher's memory.
async function runSmoke({env = process.env, fetchImpl = globalThis.fetch,
  openStore, emit = (result) => console.log(PREFIX + JSON.stringify(result))} = {}) {
  let app;
  try {
    assertSmokeEnvironment(env); // Before Firebase initialization or any I/O.
    const opened = openStore ? await openStore() : await openDemoStore();
    const {db, timestamp} = opened; app = opened;
    async function signUp() {
      const response = await fetchImpl('http://127.0.0.1:19099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-only', {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10000),
        headers: {'Content-Type': 'application/json'}, body: JSON.stringify({
          email: `ai2-smoke-${randomUUID()}@example.test`,
          password: 'disposable-smoke-password', returnSecureToken: true,
        }),
      });
      ensure(response.ok);
      const user = await response.json();
      ensure(typeof user.localId === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(user.localId) &&
        typeof user.idToken === 'string' && user.idToken.length > 0);
      return user;
    }
    const owner = await signUp();
    const staff = await signUp();
    const cafeId = `ai2-smoke-${randomUUID()}`;
    const inventoryPath = `cafes/${cafeId}/inventory`;
    const link = (uid, role) => ({uid, cafeId, status: 'active', schemaVersion: 1,
      ...(role ? {role} : {})});
    const stock = [{id: 'banana', name: 'Banana', quantity: 6, unit: 'pcs'},
      {id: 'milk', name: 'Milk', quantity: 2, unit: 'L'},
      {id: 'oats', name: 'Oats', quantity: 500, unit: 'g'}];
    const batch = db.batch();
    batch.set(db.doc(`cafes/${cafeId}`), {ownerUid: owner.localId, status: 'active', schemaVersion: 1});
    for (const [user, role] of [[owner, 'owner'], [staff, 'staff']]) {
      batch.set(db.doc(`user_cafe_memberships/${user.localId}`), link(user.localId));
      batch.set(db.doc(`cafes/${cafeId}/members/${user.localId}`), link(user.localId, role));
    }
    for (const item of stock) {
      const {id, ...fields} = item;
      batch.set(db.doc(`${inventoryPath}/${id}`), {...fields, category: 'Food',
        schemaVersion: 1, version: 1, lifecycleState: 'active',
        createdAt: timestamp(new Date()), expiryDate: timestamp(new Date('2099-01-01T00:00:00Z'))});
    }
    await batch.commit(); // Synthetic fixtures only; never reset/clear existing data.
    const snapshot = async () => (await db.collection(inventoryPath).get()).docs.map((d) => [d.id, d.data()]);
    const before = await snapshot();
    const requestId = randomUUID();
    const response = await fetchImpl(`http://127.0.0.1:15001/${PROJECT}/asia-southeast1/suggestRecipes`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(25000),
      headers: {'Content-Type': 'application/json', Authorization: `Bearer ${staff.idToken}`},
      body: JSON.stringify({data: {requestId, maxRecipes: 1}}),
    });
    const body = await response.json();
    if (!response.ok || body.error) {
      const status = body.error?.status;
      emit({ok: false, code: SAFE_CODES.includes(status) ? status : 'CALLABLE_FAILED'});
      return 1;
    }
    const titles = validateSmokeResult(body.result, requestId, stock);
    ensure(isDeepStrictEqual(await snapshot(), before));
    emit({ok: true, titles});
    return 0;
  } catch (_) {
    emit({ok: false, code: 'SMOKE_VALIDATION_FAILED'});
    return 1;
  } finally { await app?.close().catch(() => {}); }
}
async function openDemoStore() {
  // Lazy imports ensure failed isolation never initializes the Admin SDK.
  const {initializeApp, deleteApp} = require('firebase-admin/app');
  const {getFirestore, Timestamp} = require('firebase-admin/firestore');
  const app = initializeApp({projectId: PROJECT}, `ai2-smoke-${randomUUID()}`);
  const db = getFirestore(app);
  return {db, timestamp: (date) => Timestamp.fromDate(date), close: () => deleteApp(app)};
}
if (require.main === module) {
  // Outer deadline covers SDK operations as well as HTTP calls. Parent owns emulator cleanup.
  const deadline = setTimeout(() => {
    console.log(PREFIX + JSON.stringify({ok: false, code: 'DEADLINE_EXCEEDED'}));
    process.exit(1);
  }, 60000);
  runSmoke().then((code) => { clearTimeout(deadline); process.exitCode = code; });
}
module.exports = {PREFIX, SAFE_CODES, assertSmokeEnvironment, validateSmokeResult, safeTitles, runSmoke};
