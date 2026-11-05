'use strict';
// Disposable manual acceptance setup ONLY. Never starts/stops emulators.
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {randomUUID} = require('node:crypto');
const {CONNECTIVITY_PROJECT: PROJECT, CONNECTIVITY_HOSTS: HOSTS,
  assertConnectivity} = require('../ai1/recipe-service');
const CAFE = 'recipe-manual-acceptance';
const MARKER = 'recipe-manual-acceptance-v1';
// Explicitly public disposable local test credentials, never real credentials.
const ACCOUNTS = [
  {role: 'owner', email: 'ariff@gmail.com', uid: 'recipe-manual-owner'},
  {role: 'staff', email: 'staff1@gmail.com', uid: 'recipe-manual-staff'},
];
const PASSWORD = '123456';
const EXPECTED = {hub: 44400, auth: 49099, firestore: 48080, functions: 45001, ui: 44001};
function requireSafe(condition, message) { if (!condition) throw Error(message); }
async function request(url, options = {}) {
  requireSafe(new URL(url).hostname === '127.0.0.1' &&
    ['44400', '49099', '48080', '45001'].includes(new URL(url).port), 'Non-fixture target rejected.');
  const response = await fetch(url, {...options, redirect: 'error', signal: AbortSignal.timeout(8000)});
  return {status: response.status, data: await response.json()};
}
function command(pid) {
  requireSafe(Number.isInteger(pid) && pid > 0, 'Missing emulator process identity.');
  return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    `(Get-CimInstance Win32_Process -Filter 'ProcessId = ${pid}').CommandLine`],
  {encoding: 'utf8', windowsHide: true, timeout: 8000}).trim();
}
async function verifyTarget() {
  const hub = await request('http://127.0.0.1:44400/');
  const listing = await request('http://127.0.0.1:44400/emulators');
  requireSafe(hub.status === 200 && listing.status === 200, 'Emulator hub unavailable.');
  for (const [name, port] of Object.entries(EXPECTED)) {
    const service = listing.data[name];
    requireSafe(service?.host === '127.0.0.1' && service.port === port &&
      (!service.listen || service.listen.every(endpoint => endpoint.address === '127.0.0.1' && endpoint.port === port)),
    `Wrong ${name} loopback target.`);
  }
  const hubCommand = command(hub.data.pid);
  requireSafe(hubCommand.includes('run-recipe-connectivity.js --cli ') &&
    hubCommand.includes('emulators:start --config firebase.recipe-connectivity-emulator.json --project '+PROJECT+' '),
  'Running launcher project/config mismatch.');
  const firestoreCommand = command(listing.data.firestore.pid);
  requireSafe(firestoreCommand.includes('--project_id '+PROJECT+' ') &&
    firestoreCommand.includes('--host 127.0.0.1 --port 48080 '), 'Running Firestore project/port mismatch.');
  // Guard executes before authentication; this probes fake-only runtime readiness
  // without authenticating, touching inventory, or dispatching a provider request.
  const probe = await request(`http://127.0.0.1:45001/${PROJECT}/asia-southeast1/suggestRecipes`, {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({data: {requestId: randomUUID()}}),
  });
  requireSafe(probe.data?.error?.status === 'UNAUTHENTICATED', 'Fake callable isolation/readiness probe failed.');
}
async function main() {
  const mode = process.argv[2] ?? 'check';
  requireSafe(['check', 'apply'].includes(mode) && process.argv.length <= 3, 'Use check or apply only.');
  for (const [key, expected] of Object.entries({GCLOUD_PROJECT: PROJECT, GOOGLE_CLOUD_PROJECT: PROJECT,
    ...HOSTS, FIREBASE_EMULATOR_HUB: '127.0.0.1:44400', AI_RECIPE_PROVIDER: 'fake'})) {
    requireSafe(!process.env[key] || process.env[key] === expected, `Conflicting ${key}.`);
  }
  requireSafe(!process.env.GOOGLE_APPLICATION_CREDENTIALS && !process.env.AI2_PROVIDER_PIPE &&
    !process.env.FIREBASE_CONFIG, 'External credential/configuration overrides are forbidden.');
  await verifyTarget(); // Before loading Admin SDK or performing any fixture write.
  Object.assign(process.env, HOSTS, {GCLOUD_PROJECT: PROJECT, GOOGLE_CLOUD_PROJECT: PROJECT,
    FUNCTIONS_EMULATOR: 'true', AI_RECIPE_PROVIDER: 'fake'});
  // Do not let proxy configuration redirect emulator SDK traffic externally.
  for (const key of ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']) delete process.env[key];
  process.env.NO_PROXY = '127.0.0.1,localhost';
  assertConnectivity();
  const {initializeApp, deleteApp} = require('firebase-admin/app');
  const {getAuth} = require('firebase-admin/auth');
  const {getFirestore, Timestamp} = require('firebase-admin/firestore');
  const app = initializeApp({projectId: PROJECT}, 'recipe-manual-fixtures');
  const auth = getAuth(app), db = getFirestore(app);
  const created = [], verified = [];
  try {
    async function optionalUser(lookup) {
      try { return await lookup(); } catch (error) { if (error.code === 'auth/user-not-found') return null; throw error; }
    }
    const accounts = [];
    for (const fixture of ACCOUNTS) {
      const user = await optionalUser(() => auth.getUserByEmail(fixture.email));
      if (user) {
        requireSafe(!user.disabled && user.email === fixture.email &&
          user.providerData.some(provider => provider.providerId === 'password'), `Conflicting ${fixture.role} Auth identity.`);
      } else {
        requireSafe(!await optionalUser(() => auth.getUser(fixture.uid)), `Reserved ${fixture.role} UID conflict.`);
      }
      accounts.push({...fixture, uid: user?.uid ?? fixture.uid, existing: user});
    }
    requireSafe(accounts[0].uid !== accounts[1].uid, 'Owner/Staff identities overlap.');
    const now = Timestamp.now();
    const cafe = {ownerUid: accounts[0].uid, name: 'Recipe Manual Acceptance Cafe',
      status: 'active', schemaVersion: 1, fixtureMarker: MARKER};
    const expected = new Map([[`cafes/${CAFE}`, cafe]]);
    for (const account of accounts) {
      const link = {uid: account.uid, cafeId: CAFE, status: 'active', schemaVersion: 1};
      expected.set(`user_cafe_memberships/${account.uid}`, link);
      expected.set(`cafes/${CAFE}/members/${account.uid}`, {...link, role: account.role});
    }
    for (const [id, name] of [['banana', 'Banana'], ['milk', 'Milk']]) {
      expected.set(`cafes/${CAFE}/inventory/${id}`, {name, category: 'Food', quantity: 2, unit: 'pcs',
        version: 1, schemaVersion: 1, lifecycleState: 'active', cafeId: CAFE, fixtureMarker: MARKER,
        expiryDate: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z'))});
    }
    function matches(snapshot, value) {
      if (!snapshot.exists) return;
      const data = snapshot.data();
      for (const [key, expectedValue] of Object.entries(value)) {
        requireSafe(expectedValue instanceof Timestamp ? data[key]?.isEqual?.(expectedValue) : data[key] === expectedValue,
          `Conflicting fixture document: ${snapshot.ref.path} (${key}).`);
      }
      if (snapshot.ref.path.includes('/inventory/')) {
        requireSafe(data.createdAt instanceof Timestamp && data.archivedAt == null && data.archivedBy == null,
          'Conflicting inventory dates/lifecycle.');
      }
    }
    // Validate *all* planned records and unexpected member/inventory documents
    // before any Auth changes. Existing records are never overwritten.
    async function inspect() {
      const rows = await db.getAll(...[...expected.keys()].map(name => db.doc(name)));
      rows.forEach(row => matches(row, expected.get(row.ref.path)));
      for (const collection of ['members', 'inventory']) {
        const rows = await db.collection(`cafes/${CAFE}/${collection}`).get();
        requireSafe(rows.docs.every(row => expected.has(row.ref.path)), `Unexpected ${collection} in reserved cafe.`);
      }
      return rows.filter(row => !row.exists).map(row => row.ref.path);
    }
    const missing = await inspect();
    console.log(`PASS: running ${PROJECT}; exact loopback ports; fake callable guard.`);
    console.log(`PLAN: ${accounts.filter(account => !account.existing).length} Auth creates; `+
      `${accounts.filter(account => account.existing && !account.existing.emailVerified).length} email-verification updates; `+
      `${missing.length} Firestore creates; no document overwrites.`);
    if (mode === 'check') return;
    async function signIn(account) {
      // demo-only is an emulator placeholder, never an external API credential.
      const response = await request('http://127.0.0.1:49099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({email: account.email, password: PASSWORD, returnSecureToken: true}),
      });
      requireSafe(response.status === 200 && response.data.localId === account.uid && response.data.idToken,
        `Existing ${account.role} password/identity conflict; no password reset performed.`);
      const token = response.data.idToken;
      const claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
      requireSafe(claims.aud === PROJECT && claims.iss === `https://securetoken.google.com/${PROJECT}` &&
        claims.sub === account.uid, 'Emulator token project mismatch.');
      return token;
    }
    for (const account of accounts) if (account.existing) await signIn(account);
    await verifyTarget();
    for (const account of accounts) {
      if (!account.existing) {
        await auth.createUser({uid: account.uid, email: account.email, password: PASSWORD, emailVerified: true,
          displayName: `Recipe Manual ${account.role}`});
        created.push(`Auth ${account.role}`);
      } else if (!account.existing.emailVerified) {
        await auth.updateUser(account.uid, {emailVerified: true});
        verified.push(account.role);
      }
    }
    await db.runTransaction(async transaction => {
      const rows = await transaction.getAll(...[...expected.keys()].map(name => db.doc(name)));
      rows.forEach(row => matches(row, expected.get(row.ref.path)));
      for (const row of rows) if (!row.exists) {
        transaction.create(row.ref, {...expected.get(row.ref.path), createdAt: now, updatedAt: now});
      }
    }, {maxAttempts: 1});
    console.log(`APPLIED: ${created.length} Auth creates; ${verified.length} verification updates; ${missing.length} fixture documents created.`);
    await inspect();
    const before = JSON.stringify((await db.collection(`cafes/${CAFE}/inventory`).get()).docs.map(row => [row.id, row.data()]));
    for (const account of accounts) {
      const user = await auth.getUser(account.uid);
      requireSafe(user.emailVerified && !user.disabled && user.email === account.email, 'Auth verification failed.');
      const token = await signIn(account);
      const response = await request(`http://127.0.0.1:45001/${PROJECT}/asia-southeast1/suggestRecipes`, {
        method: 'POST', headers: {'Content-Type': 'application/json', Authorization: `Bearer ${token}`},
        body: JSON.stringify({data: {requestId: randomUUID(), maxRecipes: 1}}),
      });
      const result = response.data?.result;
      requireSafe(response.status === 200 && result?.provider === 'fake' && result.schemaVersion === 1 &&
        result.status === 'ok' && result.recipes?.length === 1, `${account.role} fake callable verification failed.`);
      assert.deepEqual(result.recipes[0].ingredientItemIds, ['banana', 'milk']);
      console.log(`PASS: ${account.role} (${account.email}); email verified; canonical access; authenticated fake callable.`);
    }
    const after = JSON.stringify((await db.collection(`cafes/${CAFE}/inventory`).get()).docs.map(row => [row.id, row.data()]));
    assert.equal(before, after);
    console.log(`PASS: Banana/Milk eligible and unchanged. Cafe: ${CAFE}. Running emulators/app untouched.`);
  } catch (error) {
    console.error(`STOP: ${created.length} Auth accounts created; ${verified.length} verification updates before stop; no rollback/deletes attempted.`);
    throw error;
  } finally { await db.terminate(); await deleteApp(app); }
}
const deadline = setTimeout(() => { console.error('STOP: fixture setup exceeded 90 seconds; inspect before retry.'); process.exit(1); }, 90000);
main().then(() => clearTimeout(deadline)).catch(error => {
  clearTimeout(deadline);
  // SDK/raw Auth errors can contain sensitive request details; never print them.
  const safe = typeof error.message === 'string' && /^(Conflicting|Wrong |Running |Missing |Non-fixture|Emulator |Fake callable|Reserved |Owner\/Staff|Unexpected |Existing |External |Use |Auth verification|Emulator token)/.test(error.message);
  console.error(safe ? error.message : 'STOP: fixture operation failed; no raw credentials or SDK errors logged.');
  process.exitCode = 1;
});
