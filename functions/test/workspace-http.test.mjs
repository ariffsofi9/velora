import test from 'node:test';
import assert from 'node:assert/strict';
import {createWorkspaceHttp} from '../https/workspace-http.mjs';
import {createGoogleHttp} from '../backend/google-http.mjs';
import {createFirestoreStore} from '../backend/firestore-store.mjs';
import {createRestFake} from './helpers/shared-firestore-rest-fake.cjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const data = {businessName: 'New cafe', businessType: 'cafe', address: 'Test street',
  inventoryUnit: 'kg', lowStockAlerts: true, expiryReminders: true, reminderDays: 3};
function fixture(overrides = {}) {
  const identity = fakes.fixture(), fake = createRestFake();
  const http = createGoogleHttp({projectId, transport: fake.transport});
  const store = createFirestoreStore({projectId, http, sleep: async () => {},
    accessToken: Object.assign(async () => 'synthetic-access', {projectId})});
  let ids = 0;
  const options = {projectId, storeProjectId: projectId, verifyIdentity: createIdentity(identity.identity), store,
    timestamp: store.timestamp, idFactory: () => { ids++; return 'new-cafe'; }, ...overrides};
  const handler = createWorkspaceHttp(options);
  const call = async (body = data, {token = identity.token('joiner'), path = '/workspace/create', method = 'POST', raw} = {}) => {
    const response = await handler(new Request(`https://offline.invalid${path}`, {method,
      headers: {'content-type': 'application/json', ...(token === null ? {} : {authorization: `Bearer ${token}`})},
      ...(method === 'POST' ? {body: raw ?? JSON.stringify(body)} : {})}));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return {status: response.status, body: await response.json()};
  };
  return {identity, fake, store, options, call, ids: () => ids};
}
const commits = f => f.fake.calls.filter(call => call.method === 'commit');

test('requires compatible project/store/transform and validates without I/O', () => {
  const f = fixture(); assert.equal(f.fake.calls.length, 0);
  for (const patch of [{storeProjectId: 'velora-73222'}, {store: {...f.store, projectId: 'velora-73222'}},
    {timestamp: undefined}, {idFactory: null}, {store: {runTransaction() {}}}]) {
    assert.throws(() => createWorkspaceHttp({...f.options, ...patch}));
  }
});

test('verified user without membership atomically creates canonical workspace and bootstrap pair', async () => {
  const f = fixture();
  assert.deepEqual(await f.call(), {status: 200, body: {cafeId: 'new-cafe', created: true}});
  const state = f.fake.snapshot();
  assert.equal(Object.keys(state).length, 3);
  assert.equal(state['cafes/new-cafe'].ownerUid, 'joiner');
  assert.equal(state['cafes/new-cafe'].businessType, 'Café');
  assert.equal(state['cafes/new-cafe/members/joiner'].role, 'owner');
  assert.equal(state['user_cafe_memberships/joiner'].cafeId, 'new-cafe');
  assert.equal(Object.hasOwn(state['user_cafe_memberships/joiner'], 'membershipGeneration'), false);
  assert.equal(commits(f)[0].body.writes.length, 3);
  assert.ok(commits(f)[0].body.writes.every(write => write.currentDocument.exists === false && write.updateTransforms.length));
});

test('duplicate unchanged onboarding is read-only; changed ownership input never replaces data', async () => {
  const f = fixture(); await f.call();
  const before = f.fake.snapshot();
  assert.deepEqual(await f.call(), {status: 200, body: {cafeId: 'new-cafe', created: false}});
  assert.deepEqual(commits(f).at(-1).body.writes, []);
  assert.deepEqual(await f.call({...data, businessName: 'Another cafe'}), {status: 409, body: {error: 'already-exists'}});
  assert.deepEqual(f.fake.snapshot(), before);
});

test('native contention keeps the ID stable across callback retries', async () => {
  const f = fixture(); f.fake.commitModes.push('abort');
  assert.equal((await f.call()).status, 200); assert.equal(f.ids(), 1);
  assert.deepEqual(commits(f)[0].body.writes, commits(f)[1].body.writes);
});

test('concurrent onboarding creates one workspace; the other request observes canonical prior ownership', async () => {
  const f = fixture();
  const results = await Promise.all([f.call(), f.call()]);
  assert.ok(results.every(result => result.status === 200));
  assert.equal(results.filter(result => result.body.created).length, 1);
  assert.equal(Object.keys(f.fake.snapshot()).length, 3);
});

for (const mode of ['lost', 'applied-lost', 'malformed']) test(`onboarding ${mode} commit is unknown and never automatically replayed`, async () => {
  const f = fixture(); f.fake.commitModes.push(mode);
  assert.deepEqual(await f.call(), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 1); assert.equal(f.ids(), 1);
});

for (const kind of ['missing', 'unverified', 'disabled', 'revoked', 'project', 'email']) test(`rejects ${kind} identity before ID allocation/store`, async () => {
  const f = fixture(); let token = f.identity.token('joiner');
  if (kind === 'missing') token = null;
  if (kind === 'unverified') token = f.identity.token('joiner', {email_verified: false});
  if (kind === 'disabled') f.identity.accounts.joiner.disabled = true;
  if (kind === 'revoked') f.identity.accounts.joiner.tokensValidAfterTime = new Date(f.identity.now() + 1000).toISOString();
  if (kind === 'project') token = f.identity.token('joiner', {aud: 'velora-73222'});
  if (kind === 'email') token = f.identity.token('joiner', {email: 'wrong@example.test'});
  assert.deepEqual(await f.call(data, {token}), {status: 401, body: {error: 'unauthenticated'}});
  assert.equal(f.ids(), 0); assert.equal(f.fake.calls.length, 0);
});

for (const body of [{...data, ownerUid: 'other'}, {...data, cafeId: 'other'}, {...data, role: 'owner'},
  {...data, businessName: ''}, {...data, businessType: 'unknown'}]) test(`strict onboarding rejects ${JSON.stringify(body)}`, async () => {
  const f = fixture(); assert.deepEqual(await f.call(body), {status: 400, body: {error: 'invalid-argument'}});
  assert.equal(f.fake.calls.length, 0);
});

test('existing Staff and malformed Owner linkage cannot create or overwrite a workspace', async () => {
  const f = fixture();
  f.fake.replace('user_cafe_memberships/joiner', {uid: 'joiner', cafeId: 'existing', status: 'active', schemaVersion: 1});
  f.fake.replace('cafes/existing', {ownerUid: 'other', status: 'active', schemaVersion: 1});
  f.fake.replace('cafes/existing/members/joiner', {uid: 'joiner', cafeId: 'existing', role: 'staff', status: 'active', schemaVersion: 1});
  const before = f.fake.snapshot();
  assert.deepEqual(await f.call(), {status: 409, body: {error: 'already-exists'}});
  assert.deepEqual(f.fake.snapshot(), before); assert.equal(commits(f).length, 0);
});

test('methods, unknown routes and 2048-byte boundary reject without domain execution', async () => {
  const f = fixture();
  assert.equal((await f.call(data, {method: 'GET'})).status, 405);
  assert.equal((await f.call(data, {path: '/workspace/delete'})).status, 404);
  assert.equal((await f.call(data, {raw: ' '.repeat(2049)})).status, 413);
  assert.equal(f.fake.calls.length, 0);
});
