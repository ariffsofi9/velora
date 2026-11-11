import test from 'node:test';
import assert from 'node:assert/strict';
import {createAiHttp} from '../https/ai-http.mjs';
import {createGoogleHttp} from '../backend/google-http.mjs';
import {createFirestoreStore} from '../backend/firestore-store.mjs';
import {createRestFake} from './helpers/shared-firestore-rest-fake.cjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test', secret = 'SYNTHETIC_SECRET_SENTINEL';
const expected = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const recipe = {title: 'Rice dish', ingredients: [{itemId: 'i1', quantity: 1, unit: 'pcs'}],
  steps: ['Cook rice safely.'], whyRecommended: 'Uses available rice.'};
const completion = (recipes = [recipe]) => Response.json({choices: [{finish_reason: 'stop',
  message: {content: JSON.stringify({recipes})}}]});
function fixture(overrides = {}) {
  const identity = fakes.fixture(), fake = createRestFake(identity.store.snapshot()), providers = [];
  const http = createGoogleHttp({projectId, transport: fake.transport});
  const store = createFirestoreStore({projectId, http, now: identity.now, sleep: async () => {},
    accessToken: Object.assign(async () => 'synthetic-access', {projectId})});
  let provider = async () => completion();
  const getAccount = Object.assign(async uid => structuredClone(identity.accounts[uid]), {projectId});
  const options = {projectId, storeProjectId: projectId, verifyIdentity: createIdentity(identity.identity), store,
    now: identity.now, getAccount, getSecret: () => secret,
    transport: async (url, request) => { providers.push({url, ...request}); return provider(url, request); }, ...overrides};
  const handler = createAiHttp(options);
  const call = async (op, data = {}, {uid = 'owner', token = identity.token(uid), method = 'POST', raw} = {}) => {
    const result = await handler(new Request(`https://offline.invalid/ai/${op}`, {method,
      headers: {'content-type': 'application/json', ...(token === null ? {} : {authorization: `Bearer ${token}`})},
      ...(method === 'POST' ? {body: raw ?? JSON.stringify(data)} : {})}));
    assert.equal(result.headers.get('cache-control'), 'no-store');
    const body = await result.json(); assert.equal(JSON.stringify(body).includes(secret), false);
    return {status: result.status, body};
  };
  const issue = (data = {}, auth) => call('issue', {...expected, ...data}, auth);
  const generate = (ticketId, data = {}, auth) => call('generate', {...expected, ticketId, ...data}, auth);
  return {identity, fake, store, options, call, issue, generate, providers, provider: fn => { provider = fn; }};
}
const commits = f => f.fake.calls.filter(c => c.method === 'commit');
const ticket = (f, id) => f.fake.snapshot()[`ai_generation_tickets/${id}`];
const receipt = (f, id) => f.fake.snapshot()[`ai_generation_requests/${id}`];
const workspace = f => f.fake.snapshot()['ai_usage_workspaces/cafe'];
const writesState = (call, state) => call.body.writes.some(w => w.update?.fields?.state?.stringValue === state);

test('construction is inert, TEST/project-bound and requires injected provider, secret and account dependencies', () => {
  const f = fixture(); assert.equal(f.fake.calls.length, 0); assert.equal(f.providers.length, 0);
  for (const patch of [{projectId: 'velora-73222'}, {storeProjectId: 'other'}, {store: {...f.store, projectId: 'other'}},
    {getAccount: async () => ({})}, {transport: undefined}, {getSecret: undefined}, {timeoutMs: 15001},
    {accountTimeoutMs: 0}, {now: null}]) assert.throws(() => createAiHttp({...f.options, ...patch}));
});

for (const uid of ['owner', 'staff']) test(`${uid} issue/generate uses atomic quota and scoped inventory; replay never redispatches`, async () => {
  const f = fixture(), before = f.fake.snapshot();
  const issued = await f.issue({}, {uid}); assert.equal(issued.status, 200);
  const id = issued.body.ticketId;
  assert.match(id, /^[a-f0-9]{64}$/); assert.match(ticket(f, id).payloadDigest, /^[a-f0-9]{64}$/);
  assert.equal(commits(f)[0].body.writes.length, 3);
  f.provider(async () => {
    assert.equal(ticket(f, id).state, 'dispatched');
    assert.equal(receipt(f, id).state, 'dispatched');
    return completion();
  });
  const generated = await f.generate(id, {}, {uid}); assert.equal(generated.status, 200);
  assert.equal(generated.body.recipes[0].ingredients[0].itemId, 'item');
  assert.equal(generated.body.schemaVersion, 2); assert.equal(generated.body.provider, 'groq');
  assert.equal(ticket(f, id).state, 'completed'); assert.equal(workspace(f).lock, null);
  assert.equal(f.fake.snapshot()[`ai_usage_users/${uid}`].admitted, 1);
  assert.equal(workspace(f).admitted, 1);
  assert.equal((await f.generate(id, {}, {uid})).status, 409); assert.equal(f.providers.length, 1);
  const request = f.providers[0], body = JSON.parse(request.body);
  assert.equal(request.url, 'https://api.groq.com/openai/v1/chat/completions');
  assert.equal(request.redirect, 'error'); assert.equal(request.headers.Authorization, `Bearer ${secret}`);
  assert.equal(body.model, 'openai/gpt-oss-20b'); assert.equal(body.max_completion_tokens, 2048);
  assert.equal(JSON.parse(body.messages[1].content).inventory[0].id, 'i1');
  assert.equal(request.body.includes(secret), false); assert.equal(request.body.includes('cafe'), false);
  assert.ok(f.fake.calls.filter(c => c.method === 'runQuery').every(c => c.url.endsWith('/cafes/cafe:runQuery') &&
    c.body.structuredQuery.limit === 101));
  assert.deepEqual(f.fake.snapshot()['cafes/cafe/inventory/item'], before['cafes/cafe/inventory/item']);
  const persisted = JSON.stringify(f.fake.snapshot()); assert.equal(persisted.includes('Rice dish'), false);
  assert.equal(persisted.includes(secret), false);
});

for (const data of [{operation: 'generate'}, {model: 'other'}, {url: 'https://evil.invalid'}, {uid: 'staff'},
  {payloadDigest: 'a'.repeat(64)}, {inventory: []}, {maxRecipes: 0}, {maxRecipes: 4},
  {maxRecipes: 1.5}, {expectedCafeId: '../other'}, {expectedMembershipGeneration: -1}]) {
  test(`strict AI request rejects ${JSON.stringify(data)}`, async () => {
    const f = fixture(); assert.equal((await f.issue(data)).status, 400);
    assert.equal(commits(f).length, 0); assert.equal(f.providers.length, 0);
  });
}
test('default payload digest matches explicit default and modified generation payload cannot admit', async () => {
  const f = fixture(), a = await f.issue(), b = await f.issue({maxRecipes: 1});
  assert.equal(ticket(f, a.body.ticketId).payloadDigest, ticket(f, b.body.ticketId).payloadDigest);
  assert.equal((await f.generate(a.body.ticketId, {maxRecipes: 2})).status, 409);
  assert.equal(ticket(f, a.body.ticketId).state, 'issued'); assert.equal(f.providers.length, 0);
});

for (const mode of ['outsider', 'cafe', 'generation', 'owner-link']) test(`${mode} authority rejects before issuance`, async () => {
  const f = fixture();
  if (mode === 'owner-link') f.fake.replace('cafes/cafe/members/owner', undefined);
  const result = await f.issue(mode === 'cafe' ? {expectedCafeId: 'other'} : mode === 'generation' ?
    {expectedMembershipGeneration: 1} : {}, {uid: mode === 'outsider' ? 'outsider' : 'staff'});
  assert.equal(result.status, ['cafe', 'generation'].includes(mode) ? 409 : 403);
  assert.equal(commits(f).length, 0); assert.equal(f.providers.length, 0);
});
for (const mode of ['missing', 'project', 'disabled', 'revoked', 'unverified']) test(`rejects ${mode} identity`, async () => {
  const f = fixture(); let token = f.identity.token();
  if (mode === 'missing') token = null;
  if (mode === 'project') token = f.identity.token('owner', {aud: 'velora-73222'});
  if (mode === 'disabled') f.identity.accounts.owner.disabled = true;
  if (mode === 'revoked') f.identity.accounts.owner.tokensValidAfterTime = new Date(f.identity.now() + 1000).toISOString();
  if (mode === 'unverified') token = f.identity.token('owner', {email_verified: false});
  assert.equal((await f.issue({}, {token})).status, 401); assert.equal(f.fake.calls.length, 0);
});
test('ticket identity and owner generation are bound across issue/generate', async () => {
  const f = fixture(), id = (await f.issue()).body.ticketId;
  assert.equal((await f.generate(id, {}, {uid: 'staff'})).status, 403);
  for (const path of ['user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 1});
  }
  assert.equal((await f.generate(id, {expectedMembershipGeneration: 1})).status, 403);
  assert.equal(f.providers.length, 0);
});
test('expired ticket cannot be admitted', async () => {
  const f = fixture(), id = (await f.issue()).body.ticketId; f.identity.advance(300000);
  assert.equal((await f.generate(id)).status, 409); assert.equal(ticket(f, id).state, 'issued');
  assert.equal(f.providers.length, 0);
});

for (const subject of ['user', 'workspace']) test(`${subject} durable quota exhaustion blocks issue`, async () => {
  const f = fixture(), day = Math.floor(f.identity.now() / 86400000);
  f.fake.replace(subject === 'user' ? 'ai_usage_users/owner' : 'ai_usage_workspaces/cafe',
    {schemaVersion: 1, subject: subject === 'user' ? 'owner' : 'cafe', day,
      admitted: subject === 'user' ? 10 : 30, issued: 0, lock: null});
  assert.equal((await f.issue()).status, 429); assert.equal(f.providers.length, 0);
});
test('native issue contention retries with one stable ticket ID and one durable issuance charge', async () => {
  const f = fixture(); f.fake.commitModes.push('abort');
  const result = await f.issue(); assert.equal(result.status, 200);
  assert.deepEqual(commits(f)[0].body.writes, commits(f)[1].body.writes);
  assert.equal(workspace(f).issued, 1);
});
test('concurrent generation and another ticket cannot duplicate provider dispatch or overcharge', async () => {
  const f = fixture(), a = (await f.issue()).body.ticketId, b = (await f.issue()).body.ticketId;
  let release, entered;
  const gate = new Promise(resolve => { release = resolve; });
  const dispatched = new Promise(resolve => { entered = resolve; });
  f.provider(async () => { entered(); await gate; return completion(); });
  const running = f.generate(a); await dispatched;
  assert.equal((await f.generate(a)).status, 409);
  assert.equal((await f.generate(b)).status, 429); assert.equal((await f.issue()).status, 429);
  release(); assert.equal((await running).status, 200);
  assert.equal(workspace(f).admitted, 1); assert.equal(f.providers.length, 1);
});

for (const phase of ['issue', 'admit', 'dispatch', 'complete']) for (const mode of ['lost', 'applied-lost', 'malformed']) {
  test(`${phase} ${mode} commit never causes automatic provider retry or evidence removal`, async () => {
    const f = fixture(); let armed = true;
    f.fake.hooks.commit = call => {
      const matches = phase === 'issue' ? writesState(call, 'issued') : phase === 'admit' ? writesState(call, 'admitted') :
        phase === 'dispatch' ? writesState(call, 'dispatched') : writesState(call, 'completed');
      if (armed && matches) { armed = false; f.fake.commitModes.push(mode); }
    };
    const issued = await f.issue();
    if (phase === 'issue') {
      assert.equal(issued.status, 503); assert.equal(f.providers.length, 0); assert.equal(commits(f).length, 1); return;
    }
    const id = issued.body.ticketId;
    assert.deepEqual(await f.generate(id), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
    assert.equal(f.providers.length, phase === 'complete' ? 1 : 0);
    if (!(phase === 'admit' && mode === 'lost')) {
      const count = f.providers.length;
      assert.notEqual((await f.generate(id)).status, 200); assert.equal(f.providers.length, count);
      assert.ok(ticket(f, id)); assert.ok(receipt(f, id));
    }
    if (phase === 'dispatch') assert.ok(workspace(f).lock);
  });
}

for (const mode of ['throw', 'timeout', 'http500', 'http429', 'bad-json', 'wrong-id', 'quantity', 'unit', 'secret', 'oversized']) {
  test(`provider ${mode} is bounded/sanitized and cannot redispatch`, async () => {
    const f = fixture({timeoutMs: 15}), id = (await f.issue()).body.ticketId;
    f.provider(async () => {
      if (mode === 'throw') throw Object.assign(Error(secret), {providerRejected: true});
      if (mode === 'timeout') return new Promise(() => {});
      if (mode === 'http500') return new Response(secret, {status: 500});
      if (mode === 'http429') return new Response(secret, {status: 429});
      if (mode === 'bad-json') return Response.json({choices: []});
      if (mode === 'secret') return completion([{...recipe, title: secret}]);
      if (mode === 'oversized') return new Response('x'.repeat(65537));
      return completion([{...recipe, ingredients: [{itemId: mode === 'wrong-id' ? 'foreign' : 'i1',
        quantity: mode === 'quantity' ? 999 : 1, unit: mode === 'unit' ? 'kg' : 'pcs'}]}]);
    });
    assert.equal((await f.generate(id)).status, mode === 'http429' ? 429 : 503);
    assert.equal(ticket(f, id).state, mode === 'http429' ? 'completed' : 'quarantined');
    assert.equal(workspace(f).lock === null, mode === 'http429');
    assert.equal((await f.generate(id)).status, 409); assert.equal(f.providers.length, 1);
    assert.equal(workspace(f).admitted, 1);
  });
}
test('late provider result after timeout cannot release quarantined lock or return recipes', async () => {
  const f = fixture({timeoutMs: 5}), id = (await f.issue()).body.ticketId; let release;
  f.provider(() => new Promise(resolve => { release = resolve; }));
  assert.equal((await f.generate(id)).status, 503); release(completion());
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ticket(f, id).state, 'quarantined'); assert.ok(workspace(f).lock);
  assert.equal((await f.generate(id)).status, 409); assert.equal(f.providers.length, 1);
});

for (const mode of ['account', 'membership', 'inventory', 'fence']) test(`post-provider ${mode} change fails closed without another dispatch`, async () => {
  const f = fixture(), id = (await f.issue()).body.ticketId;
  f.provider(async () => {
    if (mode === 'account') f.identity.accounts.owner.disabled = true;
    if (mode === 'membership') f.fake.replace('user_cafe_memberships/owner', undefined);
    if (mode === 'inventory') f.fake.replace('cafes/cafe/inventory/item', {...f.fake.snapshot()['cafes/cafe/inventory/item'], quantity: 4, version: 2});
    if (mode === 'fence') f.fake.replace('ai_usage_workspaces/cafe', {...workspace(f), lock: {...workspace(f).lock, fence: 'f'.repeat(64)}});
    return completion();
  });
  assert.equal((await f.generate(id)).status, mode === 'account' ? 401 : mode === 'membership' ? 403 : 409);
  assert.equal(f.providers.length, 1); assert.notEqual((await f.generate(id)).status, 200);
  assert.equal(f.providers.length, 1);
  if (mode === 'fence') assert.equal(workspace(f).lock.fence, 'f'.repeat(64));
});
for (const mode of ['malformed', 'foreign', 'capacity']) test(`inventory ${mode} prevents provider dispatch`, async () => {
  const f = fixture(), id = (await f.issue()).body.ticketId;
  if (mode === 'malformed') f.fake.replace('cafes/cafe/inventory/item', {...f.fake.snapshot()['cafes/cafe/inventory/item'], quantity: -1});
  if (mode === 'foreign') f.fake.hooks.runQuery = () => f.fake.json([{document: f.fake.doc('cafes/other/inventory/item',
    {...f.fake.snapshot()['cafes/cafe/inventory/item'], cafeId: 'other'}), readTime: f.fake.instant}]);
  if (mode === 'capacity') for (let i = 0; i < 100; i++) {
    f.fake.replace(`cafes/cafe/inventory/extra-${i}`, f.fake.snapshot()['cafes/cafe/inventory/item']);
  }
  assert.equal((await f.generate(id)).status, mode === 'malformed' ? 409 : mode === 'capacity' ? 429 : 503);
  assert.equal(f.providers.length, 0); assert.ok(workspace(f).lock);
});
test('empty eligible inventory completes without provider or stock consumption', async () => {
  const f = fixture(); f.fake.replace('cafes/cafe/inventory/item', {...f.fake.snapshot()['cafes/cafe/inventory/item'], quantity: 0});
  const id = (await f.issue()).body.ticketId, result = await f.generate(id);
  assert.equal(result.status, 200); assert.equal(result.body.status, 'no_suggestions');
  assert.deepEqual(result.body.recipes, []); assert.equal(f.providers.length, 0); assert.equal(workspace(f).lock, null);
});
test('bounded account lookup cannot resume late dispatch', async () => {
  let release;
  const f = fixture({accountTimeoutMs: 5, getAccount: Object.assign(() => new Promise(resolve => { release = resolve; }), {projectId})});
  assert.equal((await f.issue()).status, 401); release(f.identity.accounts.owner);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(f.fake.calls.length, 0);
});
test('missing secret and non-public routes never dispatch provider or expose maintenance', async () => {
  const f = fixture({getSecret: () => { throw Error(secret); }}), id = (await f.issue()).body.ticketId;
  assert.equal((await f.generate(id)).status, 409); assert.equal(ticket(f, id).state, 'issued');
  for (const path of ['cleanup', 'recover', 'reset-quota', 'generate?model=other']) assert.equal((await f.call(path)).status, 404);
  assert.equal((await f.call('issue', {}, {method: 'GET'})).status, 405);
  assert.equal((await f.call('issue', {}, {raw: '{'})).status, 400);
  assert.equal((await f.call('issue', {}, {raw: ' '.repeat(2049)})).status, 413);
  assert.equal(f.providers.length, 0);
});

test('admission contention rereads authority before any provider work', async () => {
  const f = fixture(), id = (await f.issue()).body.ticketId; let first = true;
  f.fake.hooks.commit = call => {
    if (first && writesState(call, 'admitted')) {
      first = false; f.fake.replace('user_cafe_memberships/owner', undefined);
    }
  };
  assert.equal((await f.generate(id)).status, 403); assert.equal(f.providers.length, 0);
  assert.equal(ticket(f, id).state, 'issued'); assert.equal(workspace(f).admitted, 0);
});

test('post-admission account disablement retains claim and prevents dispatch', async () => {
  const f = fixture(), id = (await f.issue()).body.ticketId;
  f.fake.hooks.runQuery = () => { f.identity.accounts.owner.disabled = true; };
  assert.equal((await f.generate(id)).status, 401); assert.equal(f.providers.length, 0);
  assert.equal(ticket(f, id).state, 'admitted'); assert.ok(workspace(f).lock);
});
