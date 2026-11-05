'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const {initializeApp, deleteApp} = require('firebase-admin/app');
const {getFirestore, Timestamp} = require('firebase-admin/firestore');
const {getAuth} = require('firebase-admin/auth');
const {PROJECT, assertIsolated, createRecipeService} = require('../ai1/recipe-service');
const {verifyRequestIdentity} = require('../ai1/request-identity');

// No default host/project and no clearFirestore/delete/reset/import/export calls.
// Test fixtures are written only after proving the exact disposable environment.
assertIsolated({...process.env, FUNCTIONS_EMULATOR: 'true'});

test('AI-1 callable: authenticated scoped read-only fake recipes', {timeout: 60000}, async (t) => {
  const app = initializeApp({projectId: PROJECT}, 'ai1-test');
  t.after(() => deleteApp(app));
  const db = getFirestore(app);
  const suffix = randomUUID();
  async function signUp() {
    const response = await fetch('http://127.0.0.1:19099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-only', {
      signal: AbortSignal.timeout(8000), redirect: 'error',
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
    const response = await fetch(`http://127.0.0.1:15001/${PROJECT}/asia-southeast1/suggestRecipes`, {
      signal: AbortSignal.timeout(12000), redirect: 'error',
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

test('AI1 real runtime identity/revocation and post-provider rechecks', {timeout: 60000}, async t => {
  assertIsolated({...process.env, FUNCTIONS_EMULATOR: 'true'});
  assert.equal(process.env.AI_RECIPE_PROVIDER, 'fake');
  const hub = await fetch('http://127.0.0.1:14400/emulators', {signal: AbortSignal.timeout(4000)}).then(r => r.json());
  for (const [name, port] of [['auth', 19099], ['firestore', 19080], ['functions', 15001]]) {
    assert.equal(hub[name].host, '127.0.0.1'); assert.equal(hub[name].port, port);
  }
  const app = initializeApp({projectId: PROJECT}, 'ai1-runtime-security');
  t.after(() => deleteApp(app));
  const db = getFirestore(app), auth = getAuth(app);
  const cafeId = `security-${randomUUID()}`;
  const accounts = [];
  for (const role of ['owner', 'staff', 'other-owner']) {
    const response = await fetch('http://127.0.0.1:19099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-only', {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(8000), headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({email: `runtime-${randomUUID()}@example.test`, password: 'disposable-test-password', returnSecureToken: true}),
    });
    assert.equal(response.status, 200); accounts.push({...await response.json(), role});
  }
  const [owner, staff, other] = accounts;
  const batch = db.batch();
  for (const account of accounts) {
    const cafe = account === other ? `${cafeId}-other` : cafeId;
    const link = {uid: account.localId, cafeId: cafe, status: 'active', schemaVersion: 1};
    batch.create(db.doc(`user_cafe_memberships/${account.localId}`), link);
    batch.create(db.doc(`cafes/${cafe}/members/${account.localId}`), {...link, role: account === staff ? 'staff' : 'owner'});
  }
  for (const [id, uid] of [[cafeId, owner.localId], [`${cafeId}-other`, other.localId]]) {
    batch.create(db.doc(`cafes/${id}`), {ownerUid: uid, status: 'active', schemaVersion: 1});
  }
  for (const [id, name] of [['banana', 'Banana'], ['milk', 'Milk']]) batch.create(db.doc(`cafes/${cafeId}/inventory/${id}`), {
    name, category: 'Food', quantity: 2, unit: 'pcs', schemaVersion: 1, version: 1,
    createdAt: Timestamp.now(), expiryDate: Timestamp.fromDate(new Date('2099-01-01Z')),
  });
  await batch.commit();
  // Snapshot the entire fresh disposable database, including updateTime, so
  // same-value writes and unexpected audit/cache/quota writes are detectable.
  async function databaseSnapshot() {
    const rows = [];
    async function visit(collection) {
      const docs = await collection.get();
      for (const doc of docs.docs) {
        rows.push([doc.ref.path, doc.updateTime.toMillis(), doc.data()]);
        for (const child of await doc.ref.listCollections()) await visit(child);
      }
    }
    for (const collection of await db.listCollections()) await visit(collection);
    return JSON.stringify(rows.sort((a, b) => a[0].localeCompare(b[0])));
  }
  async function invoke(account, data = {}) {
    const before = await databaseSnapshot();
    const response = await fetch(`http://127.0.0.1:15001/${PROJECT}/asia-southeast1/suggestRecipes`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(12000),
      headers: {'Content-Type': 'application/json', Authorization: `Bearer ${account.idToken}`},
      body: JSON.stringify({data: {requestId: randomUUID(), ...data}}),
    });
    const body = await response.json();
    assert.equal(await databaseSnapshot(), before, 'Recipe request must not write database records.');
    return body;
  }
  await t.test('valid Owner and Staff callable responses; database unchanged', async () => {
    for (const account of [owner, staff]) {
      const body = await invoke(account);
      assert.equal(body.result?.provider, 'fake'); assert.equal(body.result?.status, 'ok');
      assert.deepEqual(body.result.recipes[0].ingredientItemIds, ['banana', 'milk']);
    }
  });
  await t.test('cross-cafe caller cannot select another cafe or receive its inventory', async () => {
    assert.equal((await invoke(other)).result?.status, 'no_suggestions');
    assert.equal((await invoke(other, {cafeId})).error?.status, 'INVALID_ARGUMENT');
    await db.doc(`cafes/${cafeId}/members/${staff.localId}`).update({cafeId: `${cafeId}-other`});
    assert.equal((await invoke(staff)).error?.status, 'PERMISSION_DENIED');
    await db.doc(`cafes/${cafeId}/members/${staff.localId}`).update({cafeId});
  });
  await t.test('disabled real Auth account rejected by callable', async () => {
    await auth.updateUser(other.localId, {disabled: true});
    assert.equal((await invoke(other)).error?.status, 'UNAUTHENTICATED');
  });
  await t.test('real revoked token rejected by callable and request identity verifier', async () => {
    const claims = await auth.verifyIdToken(other.idToken, false).catch(() => null);
    // Use the active Owner for revocation, independently of disabled-account denial.
    const ownerClaims = await auth.verifyIdToken(owner.idToken, true);
    const wait = Math.max(0, (ownerClaims.auth_time + 1) * 1000 - Date.now() + 100);
    await new Promise(resolve => setTimeout(resolve, wait));
    await auth.revokeRefreshTokens(owner.localId);
    assert.ok(Date.parse((await auth.getUser(owner.localId)).tokensValidAfterTime) > ownerClaims.auth_time * 1000);
    assert.equal((await invoke(owner)).error?.status, 'UNAUTHENTICATED');
    await assert.rejects(verifyRequestIdentity(auth, owner.localId, {uid: owner.localId, bearer: owner.idToken}), {code: 'unauthenticated'});
  });
  const store = {runTransaction: operation => db.runTransaction(tx => operation({
    get: async path => { const doc = await tx.get(db.doc(path)); return doc.exists ? doc.data() : null; },
    inventory: async (path, limit) => (await tx.get(db.collection(path).limit(limit))).docs.map(doc => ({id: doc.id, data: doc.data()})),
  }), {readOnly: true})};
  for (const change of ['membership', 'disabled', 'revoked-token']) {
    await t.test(`real Auth/Firestore post-provider recheck: ${change}`, async () => {
      // The real service is called directly to control the exact provider boundary;
      // no delay/hook is added to the deployed callable. Provider is synthetic.
      let calls = 0, afterFixtureControl;
      const invokeService = createRecipeService({store, env: {...process.env, FUNCTIONS_EMULATOR: 'true'},
        verifyIdentity: (uid, identity) => verifyRequestIdentity(auth, uid, identity),
        provider: async () => {
          calls++;
          if (change === 'membership') await db.doc(`cafes/${cafeId}/members/${staff.localId}`).update({status: 'revoked'});
          if (change === 'disabled') await auth.updateUser(staff.localId, {disabled: true});
          if (change === 'revoked-token') {
            const token = JSON.parse(Buffer.from(staff.idToken.split('.')[1], 'base64url').toString());
            await new Promise(resolve => setTimeout(resolve, Math.max(0, (token.auth_time + 1) * 1000 - Date.now() + 100)));
            await auth.revokeRefreshTokens(staff.localId);
          }
          afterFixtureControl = await databaseSnapshot();
          return [];
        }});
      await assert.rejects(invokeService({auth: {uid: staff.localId, bearer: staff.idToken}, data: {requestId: randomUUID()}}),
        {code: change === 'membership' ? 'permission-denied' : 'unauthenticated'});
      assert.equal(calls, 1);
      assert.equal(await databaseSnapshot(), afterFixtureControl);
      if (change === 'membership') await db.doc(`cafes/${cafeId}/members/${staff.localId}`).update({status: 'active'});
      if (change === 'disabled') await auth.updateUser(staff.localId, {disabled: false});
    });
  }
});
