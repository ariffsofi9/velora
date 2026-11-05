'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {HttpsError} = require('firebase-functions/v2/https');
const {createSecureAiCallableAdapters, NAMES} = require('../src/secure-ai-callable-adapter');
const {assertResponseBytes, MAX_RESPONSE_BYTES} = require('../src/secure-ai-callable-contract');
const {SecureGroqError, createSecureGroqHandler} = require('../src/secure-groq-handler');
const {createAiQuota} = require('../src/ai-quota');
const {AiTransactionStore} = require('./helpers/ai-transaction-store');
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, '../../test/fixtures/secure_ai_callable_contract.json')));

test('shared names/limits and unwrapped success data match', async () => {
  assert.deepEqual(NAMES, fixture.names); assert.equal(MAX_RESPONSE_BYTES, fixture.maxResponseBytes);
  const auth = {uid: 'trusted'};
  const wrappers = createSecureAiCallableAdapters({handler: async request => {
    assert.equal(request.auth, auth);
    return structuredClone(fixture[request.data.operation === 'issue' ? 'issueResponse' : 'generateResponse']);
  }});
  for (const operation of ['issue', 'generate']) {
    const data = await wrappers[NAMES[operation]]({auth, data: fixture[operation + 'Request']});
    assert.deepEqual(data, fixture[operation + 'Response']); assert.equal(data.data, undefined);
  }
});
for (const entry of fixture.errors) test('safe HttpsError ' + entry.code + '/' + entry.reason, async () => {
  const adapters = createSecureAiCallableAdapters({handler: async () => { throw new SecureGroqError(entry.code, entry.reason); }});
  await assert.rejects(adapters[NAMES.issue]({data: fixture.issueRequest}), error => {
    assert.ok(error instanceof HttpsError); assert.equal(error.code, entry.code);
    assert.deepEqual(error.details, {reason: entry.reason}); assert.equal(error.message, 'AI suggestions are unavailable.');
    assert.equal(JSON.stringify(error.toJSON()).includes('stack'), false); return true;
  });
});
test('unknown exception and forged error properties cannot leak or choose code', async () => {
  const adapters = createSecureAiCallableAdapters({handler: async () => {
    const error = Error('secret/path/provider-body'); error.code = 'permission-denied'; error.reason = 'secret/path'; throw error;
  }});
  await assert.rejects(adapters[NAMES.issue]({data: fixture.issueRequest}), error => {
    assert.equal(error.code, 'internal'); assert.equal(JSON.stringify(error.toJSON()).includes('secret/path'), false); return true;
  });
});
test('wrong operation cannot use the issuance route for generation', async () => {
  let calls = 0; const adapters = createSecureAiCallableAdapters({handler: async () => { calls++; }});
  await assert.rejects(adapters[NAMES.issue]({data: fixture.generateRequest}), e => e.code === 'invalid-argument');
  assert.equal(calls, 0);
});
for (const value of [null, [], {schemaVersion: 2}, {...fixture.issueResponse, unexpected: true},
  {...fixture.issueResponse, expiresAt: NaN}]) test('invalid response envelope fails closed ' + JSON.stringify(value), async () => {
  const adapters = createSecureAiCallableAdapters({handler: async () => value});
  await assert.rejects(adapters[NAMES.issue]({data: fixture.issueRequest}), e => e.code === 'data-loss');
});
test('UTF-8 response-data boundary accepts exact limit and rejects one byte over', () => {
  const exact = {padding: 'é'.repeat((MAX_RESPONSE_BYTES - Buffer.byteLength(JSON.stringify({padding: ''}))) / 2)};
  assert.equal(Buffer.byteLength(JSON.stringify(exact)), MAX_RESPONSE_BYTES);
  assert.doesNotThrow(() => assertResponseBytes(exact));
  assert.throws(() => assertResponseBytes({padding: exact.padding + 'a'}));
  assert.doesNotThrow(() => assertResponseBytes({value: '🥐 café'}));
  for (const value of [NaN, undefined, {value: Infinity}, {value: '\ud800'}]) assert.throws(() => assertResponseBytes(value));
});
test('real isolated handler produces shared success fixtures with no network', async () => {
  const store = new AiTransactionStore(); const now = fixture.issueResponse.expiresAt - 300000;
  for (const uid of ['owner', 'staff']) {
    const link = {uid, cafeId: 'a', schemaVersion: 1, status: 'active'};
    store.put(`user_cafe_memberships/${uid}`, link); store.put(`cafes/a/members/${uid}`, {...link, role: uid});
  }
  store.put('cafes/a', {ownerUid: 'owner', schemaVersion: 1, status: 'active'});
  store.put('cafes/a/inventory/item-1', {cafeId: 'a', schemaVersion: 1, name: 'Egg', category: 'Food',
    quantity: 10, unit: 'pcs', expiryDate: new Date(now + 86400000), lifecycleState: 'active'});
  const quota = createAiQuota({store, now: () => now, requirePayloadDigest: true, random: () => fixture.issueResponse.ticketId});
  let calls = 0;
  const handler = createSecureGroqHandler({store, quota, now: () => now, getSecret: () => 'unit-test-placeholder',
    getAccount: async uid => ({uid, disabled: false, emailVerified: true}), transport: async () => {
      calls++; const recipes = structuredClone(fixture.generateResponse.recipes); recipes[0].ingredients[0].itemId = 'i1';
      return new Response(JSON.stringify({choices: [{finish_reason: 'stop', message: {content: JSON.stringify({recipes})}}]}));
    }});
  const adapters = createSecureAiCallableAdapters({handler});
  const auth = {uid: 'staff', token: {email_verified: true, auth_time: Math.floor(now / 1000)}};
  await assert.rejects(adapters[NAMES.issue]({data: fixture.issueRequest}), e => e.code === 'unauthenticated');
  await assert.rejects(adapters[NAMES.issue]({auth, data: {...fixture.issueRequest, payloadDigest: 'forged'}}), e => e.code === 'invalid-argument');
  await assert.rejects(adapters[NAMES.issue]({auth, data: {...fixture.issueRequest, maxRecipes: '1'}}), e => e.code === 'invalid-argument');
  const issued = await adapters[NAMES.issue]({auth, data: fixture.issueRequest}); assert.deepEqual(issued, fixture.issueResponse);
  const generated = await adapters[NAMES.generate]({auth, data: fixture.generateRequest}); assert.deepEqual(generated, fixture.generateResponse);
  await assert.rejects(adapters[NAMES.generate]({auth, data: fixture.generateRequest}), e => e.code === 'already-exists');
  assert.equal(calls, 1);
});
test('deployed entrypoint does not import or export adapters', () => {
  const index = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  for (const value of ['secure-ai-callable-adapter', ...Object.values(NAMES)]) assert.equal(index.includes(value), false);
});
