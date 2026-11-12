import test from 'node:test';
import assert from 'node:assert/strict';
import {createSavedRecipesHttp} from '../https/saved-recipes-http.mjs';
import {createGoogleHttp} from '../backend/google-http.mjs';
import {createFirestoreStore} from '../backend/firestore-store.mjs';
import {createRestFake} from './helpers/shared-firestore-rest-fake.cjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const episode = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const input = (idempotencyKey = 'saved-http-request-0001') => ({...episode, idempotencyKey,
  recipe: {title: 'Rice meal', ingredients: [{itemId: 'item', quantity: 0.125, unit: 'kg'}],
    steps: ['Cook rice safely.'], whyRecommended: 'Uses rice.'},
  attribution: {kind: 'claimed-ai', provider: 'groq', ticketId: null}});
const listing = {...episode, mode: 'active', limit: 1, cursor: null};
const lifecycle = (ack, action = 'archive') => ({...episode, idempotencyKey: `saved-http-${action}-0001`,
  recipeId: ack.recipeId, expectedVersion: ack.version, action});
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; };
function controlledDeadline() {
  let expire;
  return {requestTimeoutMs: 12345, scheduleTimeout(callback, ms) {
    if (ms === 12345) { expire = callback; return () => {}; }
    const timer = setTimeout(callback, ms); return () => clearTimeout(timer);
  }, expire: () => expire()};
}
function fixture(patch = {}) {
  const identity = fakes.fixture(), fake = createRestFake(identity.store.snapshot());
  const store = createFirestoreStore({projectId, http: createGoogleHttp({projectId, transport: fake.transport}),
    sleep: async () => {}, accessToken: Object.assign(async () => 'synthetic-access', {projectId})});
  const verifyIdentity = Object.assign(createIdentity(identity.identity), {projectId});
  const options = {projectId, storeProjectId: projectId, verifyIdentity, store, timestamp: store.timestamp, ...patch};
  const handler = createSavedRecipesHttp(options);
  const request = (operation, data, {uid = 'owner', token = identity.token(uid), raw, signal, body} = {}) =>
    new Request(`https://offline.invalid/recipes/${operation}`, {method: 'POST', signal,
      headers: {'content-type': 'application/json', ...(token === null ? {} : {authorization: `Bearer ${token}`})},
      body: body ?? raw ?? JSON.stringify(data), ...(body ? {duplex: 'half'} : {})});
  const call = async (op, data, auth) => {
    const response = await handler(request(op, data, auth));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return {status: response.status, body: await response.json()};
  };
  return {identity, fake, store, options, handler, request, call};
}
const commits = f => f.fake.calls.filter(c => c.method === 'commit');

test('construction is inert, TEST-only and requires bound dependencies and valid budgets', () => {
  const f = fixture(); assert.equal(f.fake.calls.length, 0);
  for (const patch of [{projectId: 'velora-73222'}, {storeProjectId: 'other'},
    {verifyIdentity: async () => ({})}, {store: {...f.store, projectId: 'other'}},
    {store: {...f.store, capabilities: {}}}, {timestamp: undefined},
    {requestTimeoutMs: 0}, {requestTimeoutMs: 60001}, {verificationTimeoutMs: 0}]) {
    assert.throws(() => createSavedRecipesHttp({...f.options, ...patch}));
  }
});

test('Owner/Staff save, detail, pagination, lifecycle and historical reconciliation preserve E2 results', async () => {
  const f = fixture(), before = f.fake.snapshot();
  const first = await f.call('save', input(), {uid: 'staff'}); assert.equal(first.status, 200);
  assert.equal(first.body.changed, true); assert.equal(first.body.replayed, false);
  assert.deepEqual(Object.keys(first.body).sort(), ['schemaVersion','cafeId','recipeId','contentDigest','version',
    'isArchived','outcome','changed','replayed','requestHash','payloadHash'].sort());
  const get = await f.call('get', {...episode, recipeId: first.body.recipeId});
  assert.equal(get.status, 200); assert.equal(get.body.item.createdBy, 'staff');
  assert.equal(get.body.item.provenanceEvidence, 'unverified-attribution');
  assert.equal(typeof get.body.item.createdAt, 'string');
  const duplicate = await f.call('save', input('saved-other-request-0001'));
  assert.equal(duplicate.body.outcome, 'existing-active'); assert.equal(duplicate.body.changed, false);
  const secondInput = input('saved-second-request-0001'); secondInput.recipe.title = 'Other rice';
  await f.call('save', secondInput);
  const page = await f.call('list', listing, {uid: 'staff'});
  assert.equal(page.body.items.length, 1); assert.ok(page.body.nextCursor);
  const next = await f.call('list', {...listing, cursor: page.body.nextCursor}, {uid: 'staff'});
  assert.equal(next.body.items.length, 1); assert.equal(next.body.nextCursor, null);
  const archive = lifecycle(first.body);
  assert.equal((await f.call('lifecycle', archive, {uid: 'staff'})).status, 403);
  const archived = await f.call('lifecycle', archive); assert.equal(archived.body.version, 2);
  assert.equal((await f.call('get', {...episode, recipeId: first.body.recipeId}, {uid: 'staff'})).body.item.isArchived, true);
  assert.equal((await f.call('reconcile', {operation: 'lifecycle', request: archive}, {uid: 'staff'})).status, 403);
  assert.equal((await f.call('lifecycle', lifecycle(archived.body, 'restore'))).body.version, 3);
  const observed = await f.call('reconcile', {operation: 'save', request: input()}, {uid: 'staff'});
  assert.deepEqual(observed.body, {schemaVersion: 1, status: 'committed', result: {...first.body, replayed: true}});
  assert.deepEqual(f.fake.snapshot()['cafes/cafe/inventory/item'], before['cafes/cafe/inventory/item']);
  assert.ok(commits(f).flatMap(c => c.body.writes).every(w => /\/saved_recipe(s|_requests)\//.test(w.update.name)));
  assert.equal(f.identity.calls.length, 0);
});

for (const mode of ['missing', 'signature', 'project', 'unverified', 'disabled', 'revoked']) {
  test(`identity rejection: ${mode}`, async () => {
    const f = fixture(); let token = f.identity.token();
    if (mode === 'missing') token = null;
    if (mode === 'signature') token = token.slice(0, -8) + 'AAAAAAAA';
    if (mode === 'project') token = f.identity.token('owner', {aud: 'velora-73222'});
    if (mode === 'unverified') token = f.identity.token('owner', {email_verified: false});
    if (mode === 'disabled') f.identity.accounts.owner.disabled = true;
    if (mode === 'revoked') f.identity.accounts.owner.tokensValidAfterTime = new Date(f.identity.now() + 1000).toISOString();
    assert.deepEqual(await f.call('save', input(), {token}), {status: 401, body: {error: 'unauthenticated'}});
    assert.equal(f.fake.calls.length, 0);
  });
}

for (const [name, op, data, status] of [
  ['actor', 'save', {...input(), actorUid: 'owner'}, 400],
  ['cafe', 'save', {...input(), expectedCafeId: 'other'}, 409],
  ['generation', 'save', {...input(), expectedMembershipGeneration: 1}, 409],
  ['cursor', 'list', {...listing, cursor: {afterId: '../other'}}, 400],
  ['limit', 'list', {...listing, limit: 21}, 400],
  ['absent', 'get', {...episode, recipeId: 'recipe_' + 'a'.repeat(64)}, 404],
]) test(`strict request rejection: ${name}`, async () => {
  const f = fixture(); assert.equal((await f.call(op, data)).status, status);
  assert.equal(commits(f).length, 0);
});

test('raw admission rejects malformed UTF-8/JSON and enforces exact 32768-byte limit', async () => {
  const f = fixture();
  for (const raw of ['{', '[]', new Uint8Array([0xff])]) assert.equal((await f.call('save', {}, {raw})).status, 400);
  const raw = JSON.stringify(input());
  assert.equal((await f.call('save', {}, {raw: raw + ' '.repeat(32768 - Buffer.byteLength(raw))})).status, 200);
  const count = commits(f).length;
  assert.equal((await f.call('save', {}, {raw: raw + ' '.repeat(32769 - Buffer.byteLength(raw))})).status, 413);
  assert.equal(commits(f).length, count);
});

test('successful response limit is checked before HTTP 200; unknown mutation remains explicit', async () => {
  const f = fixture();
  for (const size of [65536, 65537]) {
    const result = {value: 'a'.repeat(size - Buffer.byteLength(JSON.stringify({value: ''})))};
    const handler = createSavedRecipesHttp({...f.options, store: {...f.store, runTransaction: async () => result}});
    const response = await handler(f.request('save', input()));
    assert.equal(response.status, size === 65536 ? 200 : 503);
    assert.deepEqual(await response.json(), size === 65536 ? result : {error: 'unavailable', outcomeUnknown: true});
  }
});

test('lost acknowledgement is unknown, never resent, and missing receipt observation is read-only', async () => {
  const f = fixture(); f.fake.commitModes.push('applied-lost');
  assert.deepEqual(await f.call('save', input()), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 1);
  const snapshot = f.fake.snapshot();
  assert.equal((await f.call('reconcile', {operation: 'save', request: input()})).body.status, 'committed');
  assert.deepEqual(await f.call('reconcile', {operation: 'save', request: input('saved-missing-request-0001')}),
    {status: 200, body: {schemaVersion: 1, status: 'unknown'}});
  assert.deepEqual(f.fake.snapshot(), snapshot);
  assert.ok(commits(f).slice(1).every(c => c.body.writes.length === 0));
});

test('same key/payload replay preserves changed; altered payload conflicts without mutation', async () => {
  const f = fixture(), first = await f.call('save', input());
  assert.deepEqual((await f.call('save', input())).body, {...first.body, replayed: true});
  const changed = input(); changed.recipe.title = 'Different';
  assert.equal((await f.call('save', changed)).status, 409);
});

test('concurrent requests retain separate bearer identities and receipt attribution', async () => {
  const f = fixture();
  const results = await Promise.all(['owner', 'staff'].map(uid => f.call('save', input(`saved-${uid}-request-0001`), {uid})));
  assert.ok(results.every(r => r.status === 200));
  const receipts = Object.entries(f.fake.snapshot()).filter(([p]) => p.includes('/saved_recipe_requests/')).map(([,v]) => v);
  assert.deepEqual(receipts.map(r => r.actorUid).sort(), ['owner', 'staff']);
});

test('revocation during delayed body is checked afresh before domain/store dispatch', async () => {
  const f = fixture(), reading = deferred(), release = deferred();
  const body = new ReadableStream({async pull(controller) {
    reading.resolve(); await release.promise;
    controller.enqueue(new TextEncoder().encode(JSON.stringify(input()))); controller.close();
  }});
  const pending = f.call('save', {}, {body}); await reading.promise;
  f.identity.accounts.owner.disabled = true; release.resolve();
  assert.equal((await pending).status, 401); assert.equal(f.fake.calls.length, 0);
});

for (const mode of ['deadline', 'abort']) test(`${mode} before dispatch prevents late verification from entering store`, async () => {
  const f = fixture(), entered = deferred(), release = deferred();
  const verifyIdentity = Object.assign(async token => { entered.resolve(); await release.promise; return f.options.verifyIdentity(token); }, {projectId});
  const controller = new AbortController();
  const clock = controlledDeadline();
  const handler = createSavedRecipesHttp({...f.options, verifyIdentity, ...clock});
  const pending = handler(f.request('save', input(), {signal: controller.signal})); await entered.promise;
  if (mode === 'abort') controller.abort();
  else clock.expire();
  const response = await pending; assert.equal(response.status, 408);
  release.resolve(); await new Promise(r => setImmediate(r));
  assert.equal(f.fake.calls.length, 0);
});

for (const mode of ['deadline', 'abort']) test(`${mode} after mutation dispatch preserves uncertainty and never resends`, async () => {
  const f = fixture(), entered = deferred(), release = deferred();
  const store = {...f.store, runTransaction: async callback => {
    const result = await f.store.runTransaction(callback); entered.resolve(); await release.promise; return result;
  }};
  const controller = new AbortController();
  const clock = controlledDeadline();
  const handler = createSavedRecipesHttp({...f.options, store, ...clock});
  const pending = handler(f.request('save', input(), {signal: controller.signal})); await entered.promise;
  if (mode === 'abort') controller.abort();
  else clock.expire();
  const response = await pending;
  assert.equal(response.status, 503); assert.deepEqual(await response.json(), {error: 'unavailable', outcomeUnknown: true});
  assert.equal(commits(f).length, 1); release.resolve(); await new Promise(r => setImmediate(r));
  assert.equal(commits(f).length, 1);
  assert.equal((await f.call('reconcile', {operation: 'save', request: input()})).body.status, 'committed');
});

test('deadline during post-body fresh verification prevents a late store dispatch', async () => {
  const f = fixture(), entered = deferred(), release = deferred(), clock = controlledDeadline(); let count = 0;
  const verifyIdentity = Object.assign(async token => {
    if (++count === 2) { entered.resolve(); await release.promise; }
    return f.options.verifyIdentity(token);
  }, {projectId});
  const handler = createSavedRecipesHttp({...f.options, verifyIdentity, ...clock});
  const pending = handler(f.request('save', input())); await entered.promise; clock.expire();
  assert.equal((await pending).status, 408);
  release.resolve(); await new Promise(r => setImmediate(r));
  assert.equal(f.fake.calls.length, 0);
});

test('abort during body admission blocks late body completion and domain dispatch', async () => {
  const f = fixture(), reading = deferred(), release = deferred(), controller = new AbortController();
  const body = new ReadableStream({async pull(stream) {
    reading.resolve(); await release.promise;
    stream.enqueue(new TextEncoder().encode(JSON.stringify(input()))); stream.close();
  }});
  const pending = f.call('save', {}, {body, signal: controller.signal}); await reading.promise;
  controller.abort(); assert.equal((await pending).status, 408);
  release.resolve(); await new Promise(r => setImmediate(r)); assert.equal(f.fake.calls.length, 0);
});

test('already aborted requests never verify identity or touch storage', async () => {
  const f = fixture(), controller = new AbortController(); controller.abort(); let verifications = 0;
  const verifyIdentity = Object.assign(async () => { verifications++; throw Error(); }, {projectId});
  const handler = createSavedRecipesHttp({...f.options, verifyIdentity});
  assert.equal((await handler(f.request('save', input(), {signal: controller.signal}))).status, 408);
  assert.equal(verifications, 0); assert.equal(f.fake.calls.length, 0);
});

test('deadline while store is awaiting callback prevents late recipe staging', async () => {
  const f = fixture(), entered = deferred(), release = deferred(), clock = controlledDeadline(); let writes = 0;
  const store = {...f.store, runTransaction: async callback => {
    entered.resolve(); await release.promise;
    return callback({create() { writes++; }, update() { writes++; }});
  }};
  const handler = createSavedRecipesHttp({...f.options, store, ...clock});
  const pending = handler(f.request('save', input())); await entered.promise; clock.expire();
  const response = await pending; assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {error: 'unavailable', outcomeUnknown: true});
  release.resolve(); await new Promise(r => setImmediate(r)); assert.equal(writes, 0);
});

test('dependency errors with forged public codes cannot disclose details or claim definite rejection', async () => {
  const f = fixture();
  const handler = createSavedRecipesHttp({...f.options, store: {...f.store, runTransaction: async () => {
    throw Object.assign(Error('SECRET raw dependency details'), {code: 'permission-denied', outcomeUnknown: false});
  }}});
  const response = await handler(f.request('save', input()));
  assert.equal(response.status, 503); assert.deepEqual(await response.json(), {error: 'unavailable', outcomeUnknown: true});
});
