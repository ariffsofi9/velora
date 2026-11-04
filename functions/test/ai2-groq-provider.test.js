'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {randomBytes} = require('node:crypto');
const {PROJECT, HOSTS, validateRecipes, createRecipeService} = require('../ai1/recipe-service');
const {createGroqProvider, selectProvider, serveProvider, pipeProvider} = require('../ai1/groq-provider');
const {childEnvironment} = require('../ai1/run-emulators');

const secret = 'synthetic-ai2-credential';
const environment = () => ({GCLOUD_PROJECT: PROJECT, FUNCTIONS_EMULATOR: 'true', ...HOSTS,
  AI_RECIPE_PROVIDER: 'groq', GROQ_API_KEY: secret});
const items = [{id: 'private-banana-id', name: 'Banana', quantity: 2, unit: 'pcs',
  category: 'PRIVATE_CATEGORY', version: 123, expiryDate: '2099-01-01'},
{id: 'private-milk-id', name: 'Milk', quantity: 1, unit: 'L'}];
const input = {items, maxRecipes: 1};
test('launcher environment never reads or forwards secrets, provider opt-in or debug flags', () => {
  const source = {PATH: 'synthetic-path', TEMP: 'synthetic-temp', DEBUG: 'verbose',
    NODE_OPTIONS: 'unsafe', AI_RECIPE_PROVIDER: 'groq', AI2_PROVIDER_PIPE: 'untrusted'};
  Object.defineProperty(source, 'GROQ_API_KEY', {get() { assert.fail('Do not read key'); }});
  Object.defineProperty(source, 'GOOGLE_APPLICATION_CREDENTIALS', {get() { assert.fail('Do not read credentials'); }});
  assert.deepEqual(childEnvironment(source), {PATH: 'synthetic-path', TEMP: 'synthetic-temp', CI: '1'});
});
const recipe = () => ({title: 'Banana Milk Smoothie', ingredients: [
  {itemId: 'i1', quantity: 1, unit: 'pcs'}, {itemId: 'i2', quantity: 0.25, unit: 'L'},
], steps: ['Peel banana.', 'Blend banana with milk.'], whyRecommended: 'Uses available stock.'});
const envelope = (recipes = [recipe()], changes = {}) => ({choices: [{finish_reason: 'stop',
  message: {content: JSON.stringify({recipes})}, ...changes}]});
const response = (data) => new Response(JSON.stringify(data), {status: 200});
const code = (expected) => (error) => error.code === expected &&
  !`${error.message}${error.stack}`.includes(secret) && !error.message.includes('PRIVATE');

test('explicit isolation and live opt-in; fake selection never accesses key', () => {
  const fake = () => [];
  const env = {GCLOUD_PROJECT: PROJECT, FUNCTIONS_EMULATOR: 'true', ...HOSTS};
  Object.defineProperty(env, 'GROQ_API_KEY', {get() { assert.fail('Fake mode must not access key'); }});
  assert.equal(selectProvider({env, fakeProvider: fake}).provider, fake);
  for (const changes of [{AI_RECIPE_PROVIDER: 'fake'}, {AI_RECIPE_PROVIDER: undefined},
    {GROQ_API_KEY: ''}, {GCLOUD_PROJECT: 'velora-73222'}, {FIRESTORE_EMULATOR_HOST: ''}]) {
    assert.throws(() => createGroqProvider({env: {...environment(), ...changes}}), code('failed-precondition'));
  }
  assert.throws(() => selectProvider({env: {...environment(), AI_RECIPE_PROVIDER: 'unknown'},
    fakeProvider: fake}), code('failed-precondition'));
  assert.throws(() => selectProvider({env: environment(), fakeProvider: fake}), code('failed-precondition'));
});
test('bounded private request, supported strict schema and alias mapping', async () => {
  let calls = 0;
  const provider = createGroqProvider({env: environment(), fetchImpl: async (url, options) => {
    calls++;
    assert.equal(url, 'https://api.groq.com/openai/v1/chat/completions');
    assert.equal(options.method, 'POST'); assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, `Bearer ${secret}`);
    assert.ok(options.signal instanceof AbortSignal);
    assert.ok(Buffer.byteLength(options.body) <= 32768);
    for (const sensitive of [secret, 'private-banana-id', 'private-milk-id', 'PRIVATE_CATEGORY', '2099-01-01']) {
      assert.ok(!options.body.includes(sensitive));
    }
    const body = JSON.parse(options.body);
    assert.equal(body.model, 'openai/gpt-oss-20b');
    assert.equal(body.response_format.type, 'json_schema');
    assert.equal(body.response_format.json_schema.strict, true);
    assert.equal(body.include_reasoning, false); assert.equal(body.reasoning_effort, 'low');
    assert.equal(body.max_completion_tokens, 2048);
    assert.deepEqual(JSON.parse(body.messages[1].content).inventory,
      [{id: 'i1', name: 'Banana', quantity: 2, unit: 'pcs'}, {id: 'i2', name: 'Milk', quantity: 1, unit: 'L'}]);
    return response(envelope());
  }});
  const result = await provider(input);
  assert.equal(calls, 1);
  assert.deepEqual(result[0].ingredients, [
    {itemId: 'private-banana-id', quantity: 1, unit: 'pcs'},
    {itemId: 'private-milk-id', quantity: 0.25, unit: 'L'},
  ]);
  assert.deepEqual(validateRecipes(result, items, 1, 'groq'), result);
});
test('inventory exposure capped at 20; invalid request boundaries never call fetch', async () => {
  let calls = 0;
  const provider = createGroqProvider({env: environment(), fetchImpl: async (_, options) => {
    calls++; assert.equal(JSON.parse(JSON.parse(options.body).messages[1].content).inventory.length, 20);
    return response(envelope([]));
  }});
  const many = Array.from({length: 100}, (_, n) => ({id: `stock${n}`, name: 'Rice', quantity: 2, unit: 'kg'}));
  assert.deepEqual(await provider({items: many, maxRecipes: 3}), []);
  for (const invalid of [{items: [], maxRecipes: 1}, {items: [...many, many[0]], maxRecipes: 1},
    {...input, maxRecipes: 4}, {...input, maxRecipes: 1.5},
    {items: [items[0], items[0]], maxRecipes: 1},
    {items: [{...items[0], name: 'bad\nlabel'}], maxRecipes: 1},
    {items: [{...items[0], name: 'bad\u202elabel'}], maxRecipes: 1},
    {items: [{...items[0], quantity: 0}], maxRecipes: 1}]) {
    await assert.rejects(provider(invalid), code('internal'));
  }
  assert.equal(calls, 1);
});
for (const [name, mutate] of [
  ['fabricated item ID', (r) => { r.ingredients[0].itemId = 'salt'; }],
  ['real ID instead of alias', (r) => { r.ingredients[0].itemId = items[0].id; }],
  ['excess quantity', (r) => { r.ingredients[0].quantity = 3; }],
  ['zero quantity', (r) => { r.ingredients[0].quantity = 0; }],
  ['negative quantity', (r) => { r.ingredients[0].quantity = -1; }],
  ['string quantity', (r) => { r.ingredients[0].quantity = '1'; }],
  ['fractional pieces', (r) => { r.ingredients[0].quantity = 0.5; }],
  ['unit conversion', (r) => { r.ingredients[1].unit = 'ml'; }],
  ['duplicate ingredient', (r) => { r.ingredients.push(r.ingredients[0]); }],
  ['missing ingredients', (r) => { delete r.ingredients; }],
  ['unknown fields', (r) => { r.reasoning = 'PRIVATE'; }],
  ['empty steps', (r) => { r.steps = []; }],
  ['oversized steps', (r) => { r.steps = ['x'.repeat(301)]; }],
]) {
  test(`rejects ${name}`, async () => {
    const value = recipe(); mutate(value);
    const provider = createGroqProvider({env: environment(), fetchImpl: async () => response(envelope([value]))});
    await assert.rejects(provider(input), code('internal'));
  });
}
test('incomplete, malformed, reasoning-only and secret-bearing replies never return text', async () => {
  for (const data of [null, {}, {choices: []}, envelope([recipe(), recipe()]),
    envelope([], {finish_reason: 'length'}), envelope([], {finish_reason: 'tool_calls'}),
    envelope([], {finish_reason: secret}),
    envelope([], {message: {reasoning: 'PRIVATE', content: null}}),
    envelope([], {message: {content: 'not json'}}),
    envelope([], {message: {content: JSON.stringify({recipes: [], extra: 'PRIVATE'})}}),
    envelope([{...recipe(), title: secret}])]) {
    const provider = createGroqProvider({env: environment(), fetchImpl: async () => response(data)});
    await assert.rejects(provider(input), code('internal'));
  }
  const provider = createGroqProvider({env: environment(), fetchImpl: async () => new Response('invalid JSON')});
  await assert.rejects(provider(input), code('internal'));
});
for (const status of [400, 401, 403, 404, 429, 500, 503]) {
  test(`HTTP ${status} returns fixed safe error without reading body or retrying`, async () => {
    let calls = 0; let reads = 0;
    const provider = createGroqProvider({env: environment(), fetchImpl: async () => {
      calls++; return {ok: false, status, get body() { reads++; throw Error(secret); }};
    }});
    await assert.rejects(provider(input), code(status === 429 ? 'resource-exhausted' : 'unavailable'));
    assert.equal(reads, 0); assert.equal(calls, 1);
  });
}
test('network and timeout failures are bounded, safe and never retried', async () => {
  const provider = createGroqProvider({env: environment(), fetchImpl: async () => { throw Error(secret); }});
  await assert.rejects(provider(input), code('unavailable'));
  let calls = 0;
  const stalled = createGroqProvider({env: environment(), timeoutMs: 15,
    fetchImpl: () => { calls++; return new Promise(() => {}); }});
  await assert.rejects(stalled(input), code('deadline-exceeded')); assert.equal(calls, 1);
  const bodyStall = createGroqProvider({env: environment(), timeoutMs: 15, fetchImpl: async () => ({
    ok: true, body: {getReader: () => ({read: () => new Promise(() => {}), cancel: async () => {}})},
  })});
  await assert.rejects(bodyStall(input), code('deadline-exceeded'));
});
test('oversized response is stopped and cancelled', async () => {
  let cancelled = false;
  const provider = createGroqProvider({env: environment(), fetchImpl: async () => ({ok: true,
    body: {getReader: () => ({read: async () => ({done: false, value: Buffer.alloc(65537)}),
      cancel: async () => { cancelled = true; }})}})});
  await assert.rejects(provider(input), code('internal')); assert.equal(cancelled, true);
});
test('live selection and Windows pipe relay use only validated recipes, never key', async (t) => {
  const pipe = '\\\\.\\pipe\\velora-ai2-' + randomBytes(16).toString('hex');
  const provider = createGroqProvider({env: environment(), fetchImpl: async () => response(envelope())});
  const server = serveProvider(pipe, provider);
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(pipe, resolve); });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const selected = selectProvider({env: {...environment(), AI2_PROVIDER_PIPE: pipe}, fakeProvider: () => []});
  assert.equal(selected.providerName, 'groq');
  const result = await selected.provider(input);
  assert.equal(result[0].ingredients[0].itemId, items[0].id);
  assert.ok(!JSON.stringify(result).includes(secret));
  assert.throws(() => pipeProvider('http://external-host'), code('failed-precondition'));
});

test('Groq service uses full authorization/rechecks and validates quantities independently', async () => {
  const link = (uid, role) => ({uid, cafeId: 'cafe', status: 'active', schemaVersion: 1,
    ...(role ? {role} : {})});
  const docs = {'user_cafe_memberships/staff': link('staff'),
    'user_cafe_memberships/owner': link('owner'),
    'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1},
    'cafes/cafe/members/staff': link('staff', 'staff'),
    'cafes/cafe/members/owner': link('owner', 'owner')};
  const stock = items.map((i) => ({id: i.id, data: {...i, category: 'Food',
    createdAt: new Date('2029-01-01Z'), expiryDate: new Date('2099-01-01Z')}}));
  const store = {runTransaction: async (fn) => fn({get: async (p) => docs[p],
    inventory: async (p) => { assert.equal(p, 'cafes/cafe/inventory'); return stock; }})};
  const invokeArgs = {auth: {uid: 'staff'}, data: {requestId: 'ai2-service-request-001'}};
  const settings = {env: environment(), store, providerName: 'groq', verifyIdentity: async () => {}};
  const provider = createGroqProvider({env: environment(), fetchImpl: async () => response(envelope())});
  const result = await createRecipeService({...settings, provider})(invokeArgs);
  assert.equal(result.schemaVersion, 2); assert.equal(result.provider, 'groq');
  assert.equal(result.recipes[0].ingredients[0].itemId, items[0].id);
  await assert.rejects(createRecipeService({...settings, provider: async () => [{...result.recipes[0],
    ingredients: [{itemId: items[0].id, quantity: 100, unit: 'pcs'}]}]})(invokeArgs), code('internal'));
  let calls = 0;
  const revoking = createRecipeService({...settings, provider: async (input) => {
    calls++; const recipes = await provider(input);
    docs['cafes/cafe/members/staff'].status = 'revoked'; return recipes;
  }});
  await assert.rejects(revoking(invokeArgs), (e) => e.code === 'permission-denied');
  assert.equal(calls, 1);
  await assert.rejects(createRecipeService({...settings, provider: async () => {
    assert.fail('Revoked user must not call provider');
  }})(invokeArgs), (e) => e.code === 'permission-denied');
});
