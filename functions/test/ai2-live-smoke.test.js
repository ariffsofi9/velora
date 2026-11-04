'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {PROJECT, HOSTS} = require('../ai1/recipe-service');
const {runSmoke, validateSmokeResult, safeTitles, PREFIX} = require('../ai1/live-smoke');
const {parseSmokeLine} = require('../ai1/run-emulators');
const env = () => ({GCLOUD_PROJECT: PROJECT, ...HOSTS,
  AI_RECIPE_PROVIDER: 'groq', AI2_LIVE_SMOKE: 'true'});
const token = 'synthetic-disposable-token';

function fixture({provider = 'groq', mutated = false, failure = false} = {}) {
  const docs = new Map(); const results = []; let closes = 0; let requests = 0;
  let auth = 0; let reads = 0;
  const db = {
    doc: (p) => p,
    batch: () => ({set: (p, value) => docs.set(p, value), commit: async () => {}}),
    collection: (p) => ({get: async () => ({docs: [...docs.entries()]
      .filter(([key]) => key.startsWith(p + '/')).map(([key, value]) => ({
        id: key.split('/').at(-1), data: () => ({...value,
          ...(mutated && reads > 0 ? {quantity: 999} : {})}),
      }))})}),
  };
  const fetchImpl = async (url, options) => {
    assert.equal(options.redirect, 'error');
    assert.ok(options.signal instanceof AbortSignal);
    if (url.startsWith('http://127.0.0.1:19099/')) {
      auth++; return {ok: true, json: async () => ({localId: `test-user-${auth}`, idToken: token})};
    }
    assert.equal(url, `http://127.0.0.1:15001/${PROJECT}/asia-southeast1/suggestRecipes`);
    requests++; reads++;
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    const {data} = JSON.parse(options.body);
    assert.deepEqual(Object.keys(data).sort(), ['maxRecipes', 'requestId']);
    if (failure) return {ok: false, json: async () => ({error: {status: 'PRIVATE_SECRET', message: token}})};
    return {ok: true, json: async () => ({result: {
      schemaVersion: 2, requestId: data.requestId, provider, status: 'ok', recipes: [{
        title: 'Banana Oat Smoothie', ingredients: [{itemId: 'banana', quantity: 1, unit: 'pcs'},
          {itemId: 'milk', quantity: 0.2, unit: 'L'}],
        steps: ['Peel the banana.', 'Blend with the milk.'], whyRecommended: 'Uses available ingredients.',
      }],
    }})};
  };
  return {results, docs, requests: () => requests, closes: () => closes,
    settings: {env: env(), fetchImpl, emit: (value) => results.push(value),
      openStore: async () => ({db, timestamp: (date) => date, close: async () => { closes++; }})}};
}

test('live smoke workflow can be tested offline with synthetic identity and in-memory fixtures', async () => {
  const f = fixture();
  assert.equal(await runSmoke(f.settings), 0);
  assert.equal(f.requests(), 1); assert.equal(f.closes(), 1);
  assert.deepEqual(f.results, [{ok: true, titles: ['Banana Oat Smoothie']}]);
  assert.ok(!JSON.stringify(f.results).includes(token));
  assert.ok([...f.docs.keys()].every((p) => p.startsWith('cafes/ai2-smoke-') || p.startsWith('user_cafe_memberships/')));
});
test('production project, wrong hosts, fake mode and missing opt-in fail before I/O', async () => {
  for (const change of [{GCLOUD_PROJECT: 'velora-73222'}, {FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080'},
    {FIREBASE_AUTH_EMULATOR_HOST: ''}, {AI_RECIPE_PROVIDER: 'fake'}, {AI2_LIVE_SMOKE: undefined}]) {
    let opened = false;
    const result = [];
    assert.equal(await runSmoke({env: {...env(), ...change},
      openStore: async () => { opened = true; throw Error(token); }, emit: (v) => result.push(v)}), 1);
    assert.equal(opened, false);
    assert.deepEqual(result, [{ok: false, code: 'SMOKE_VALIDATION_FAILED'}]);
  }
});
test('fake fallback, inventory mutation and provider error all fail with sanitized output', async () => {
  for (const options of [{provider: 'fake'}, {mutated: true}, {failure: true}]) {
    const f = fixture(options);
    assert.equal(await runSmoke(f.settings), 1); assert.equal(f.closes(), 1);
    assert.equal(f.results[0].ok, false);
    assert.ok(!JSON.stringify(f.results).includes(token));
    assert.ok(!JSON.stringify(f.results).includes('PRIVATE_SECRET'));
  }
});
test('strict live response checks validate ingredient quantities, units, instructions and provenance', () => {
  const stock = [{id: 'banana', quantity: 2, unit: 'pcs'}];
  const valid = {schemaVersion: 2, requestId: 'id', provider: 'groq', status: 'ok',
    recipes: [{title: 'Banana', ingredients: [{itemId: 'banana', quantity: 1, unit: 'pcs'}],
      steps: ['Peel banana.'], whyRecommended: 'Uses banana.'}]};
  assert.deepEqual(validateSmokeResult(valid, 'id', stock), ['Banana']);
  for (const changes of [{provider: 'fake'}, {schemaVersion: 1}, {requestId: 'wrong'},
    {status: 'no_suggestions'}, {recipes: []}, {reasoning: token},
    {recipes: [{...valid.recipes[0], steps: []}]},
    {recipes: [{...valid.recipes[0], ingredients: [{itemId: 'salt', quantity: 1, unit: 'pcs'}]}]},
    {recipes: [{...valid.recipes[0], ingredients: [{itemId: 'banana', quantity: 3, unit: 'pcs'}]}]},
    {recipes: [{...valid.recipes[0], ingredients: [{itemId: 'banana', quantity: 1, unit: 'kg'}]}]}]) {
    assert.throws(() => validateSmokeResult({...valid, ...changes}, 'id', stock));
  }
});
test('output parser never forwards raw messages, tokens, reasoning or terminal controls', () => {
  assert.equal(parseSmokeLine('untrusted provider text'), null);
  assert.deepEqual(parseSmokeLine(PREFIX + JSON.stringify({ok: false, code: token, reasoning: token})),
    {ok: false, code: 'SMOKE_FAILED'});
  assert.deepEqual(parseSmokeLine(PREFIX + '{invalid'), {ok: false, code: 'SMOKE_OUTPUT_INVALID'});
  assert.throws(() => safeTitles(['bad\x1b[31m']));
  assert.throws(() => safeTitles(['bad\u202etitle']));
  assert.deepEqual(parseSmokeLine(PREFIX + JSON.stringify({ok: true, titles: ['Banana Smoothie'], token})),
    {ok: true, titles: ['Banana Smoothie']});
});
