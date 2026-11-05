'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createSecureGroqHandler, SecureGroqError} = require('../src/secure-groq-handler');
const {createAiQuota} = require('../src/ai-quota');
const {AiTransactionStore} = require('./helpers/ai-transaction-store');
const expected = {expectedCafeId: 'a', expectedMembershipGeneration: 0};
const recipe = {title: 'Simple dish', ingredients: [{itemId: 'i1', quantity: 1, unit: 'pcs'}],
  steps: ['Prepare safely.'], whyRecommended: 'Uses available stock.'};
const response = (recipes = [recipe]) => new Response(JSON.stringify({choices: [{finish_reason: 'stop',
  message: {content: JSON.stringify({recipes})}}]}), {status: 200});
const code = value => e => e instanceof SecureGroqError && e.code === value && e.message === 'AI suggestions are unavailable.';
function fixture(options = {}) {
  const store = new AiTransactionStore(); let time = Date.UTC(2026, 10, 6, 12); let calls = 0;
  const accounts = new Map(); let secret = 'unit-test-secret-placeholder';
  for (const cafeId of ['a', 'b']) {
    const ownerUid = `owner-${cafeId}`;
    store.put(`cafes/${cafeId}`, {schemaVersion: 1, status: 'active', ownerUid});
    for (const uid of [ownerUid, ...Array.from({length: 5}, (_, i) => `${cafeId}-staff-${i}`)]) {
      const link = {uid, cafeId, schemaVersion: 1, status: 'active'};
      store.put(`user_cafe_memberships/${uid}`, link);
      store.put(`cafes/${cafeId}/members/${uid}`, {...link, role: uid === ownerUid ? 'owner' : 'staff'});
      accounts.set(uid, {uid, disabled: false, emailVerified: true, tokensValidAfterTime: new Date(time - 20000).toISOString()});
    }
    store.put(`cafes/${cafeId}/inventory/item-1`, {schemaVersion: 1, cafeId, name: 'Ingredient',
      category: 'Food', unit: 'pcs', quantity: 10, expiryDate: new Date(time + 86400000), lifecycleState: 'active'});
  }
  const auth = uid => ({uid, token: {email_verified: true, auth_time: Math.floor(time / 1000) - 10}});
  const q = createAiQuota({store, now: () => time, requirePayloadDigest: true});
  let provider = async () => response();
  const handler = createSecureGroqHandler({store, now: () => time, quota: options.quota?.(q) ?? q,
    getAccount: options.getAccount ?? (async uid => structuredClone(accounts.get(uid))),
    getSecret: () => secret, timeoutMs: options.timeoutMs ?? 15000,
    transport: async (...args) => { calls++; return provider(...args); }});
  const issue = (data = {}, uid = 'a-staff-0') => handler({auth: auth(uid), data: {operation: 'issue', ...expected, ...data}});
  const generate = (ticketId, data = {}, uid = 'a-staff-0') => handler({auth: auth(uid),
    data: {operation: 'generate', ...expected, ticketId, ...data}});
  return {store, q, handler, issue, generate, auth, accounts, advance: ms => { time += ms; },
    provider: fn => { provider = fn; }, secret: value => { secret = value; }, calls: () => calls};
}
test('bound issuance and successful fresh response use opaque IDs, no persisted result', async () => {
  const f = fixture(); let request;
  f.provider(async (url, options) => { request = {url, ...options}; return response(); });
  const ticket = await f.issue(); const result = await f.generate(ticket.ticketId);
  assert.equal(result.status, 'ok'); assert.equal(result.recipes[0].ingredients[0].itemId, 'item-1');
  assert.equal(f.calls(), 1); assert.equal(request.redirect, 'error');
  const body = JSON.parse(request.body); assert.equal(body.model, 'openai/gpt-oss-20b');
  assert.equal(body.max_completion_tokens, 2048); assert.ok(Buffer.byteLength(request.body) <= 32768);
  assert.equal(request.body.includes('a-staff-0'), false); assert.equal(request.body.includes('item-1'), false);
  const stored = JSON.stringify([...f.store.docs.values()]);
  assert.equal(stored.includes('Simple dish'), false); assert.equal(stored.includes('unit-test-secret-placeholder'), false);
  assert.match(f.store.docs.get(`ai_generation_tickets/${ticket.ticketId}`).payloadDigest, /^[a-f0-9]{64}$/);
  assert.equal(f.q.retrieveResult, undefined);
});
test('equivalent omitted/default/reordered payloads share canonical digest', async () => {
  const f = fixture(); const a = await f.issue(); const b = await f.issue({maxRecipes: 1});
  assert.equal(f.store.docs.get(`ai_generation_tickets/${a.ticketId}`).payloadDigest,
    f.store.docs.get(`ai_generation_tickets/${b.ticketId}`).payloadDigest);
  assert.equal((await f.generate(a.ticketId, {maxRecipes: 1})).status, 'ok');
});
test('modified payload fails before admission and on replay after success', async () => {
  const f = fixture(); const ticket = await f.issue();
  await assert.rejects(f.generate(ticket.ticketId, {maxRecipes: 2}), code('failed-precondition'));
  assert.equal(f.calls(), 0); await f.generate(ticket.ticketId);
  await assert.rejects(f.generate(ticket.ticketId, {maxRecipes: 2}), code('failed-precondition'));
  assert.equal(f.calls(), 1);
});
for (const [name, data] of [
  ['client digest', {payloadDigest: 'a'.repeat(64)}], ['client identity', {uid: 'owner-a'}],
  ['client model', {model: 'another-model'}], ['client inventory', {inventory: []}],
  ['oversized', {padding: 'x'.repeat(2200)}], ['fractional maxRecipes', {maxRecipes: 1.5}],
  ['null maxRecipes', {maxRecipes: null}], ['extra field', {quota: 999}],
]) test(name + ' rejected without provider or quota admission', async () => {
  const f = fixture(); await assert.rejects(f.issue(data), code('invalid-argument'));
  assert.equal(f.calls(), 0); assert.equal(f.store.docs.has('ai_usage_users/a-staff-0'), false);
});
for (const [name, auth] of [
  ['missing Auth', null], ['unverified claim', {uid: 'a-staff-0', token: {email_verified: false, auth_time: 1}}],
  ['missing auth_time', {uid: 'a-staff-0', token: {email_verified: true}}],
]) test(name + ' denied', async () => {
  const f = fixture(); await assert.rejects(f.handler({auth, data: {operation: 'issue', ...expected}}), code('unauthenticated'));
});
for (const [name, change] of [
  ['disabled account', user => ({...user, disabled: true})],
  ['unverified current account', user => ({...user, emailVerified: false})],
  ['mismatched current UID', user => ({...user, uid: 'outsider'})],
  ['revoked token', user => ({...user, tokensValidAfterTime: '2099-01-01T00:00:00Z'})],
  ['malformed revocation timestamp', user => ({...user, tokensValidAfterTime: 'bad'})],
]) test(name + ' denied from authoritative lookup', async () => {
  const f = fixture(); f.accounts.set('a-staff-0', change(f.accounts.get('a-staff-0')));
  await assert.rejects(f.issue(), code('unauthenticated')); assert.equal(f.calls(), 0);
});
test('account lookup failure is sanitized', async () => {
  const f = fixture({getAccount: async () => { throw Error('private provider key'); }});
  await assert.rejects(f.issue(), code('unauthenticated'));
});
for (const mode of ['missing', 'inactive', 'stale', 'cross-workspace', 'role-conflict', 'owner-generation']) {
  test(mode + ' authority rejected before provider', async () => {
    const f = fixture(); const ticket = await f.issue(); let input = {};
    if (mode === 'missing') f.store.docs.delete('user_cafe_memberships/a-staff-0');
    if (mode === 'inactive') f.store.put('user_cafe_memberships/a-staff-0', {...f.store.docs.get('user_cafe_memberships/a-staff-0'), status: 'inactive'});
    if (mode === 'stale') input = {expectedMembershipGeneration: 1};
    if (mode === 'cross-workspace') input = {expectedCafeId: 'b'};
    if (mode === 'role-conflict') f.store.put('cafes/a/members/a-staff-0', {...f.store.docs.get('cafes/a/members/a-staff-0'), role: 'owner'});
    if (mode === 'owner-generation') for (const p of ['user_cafe_memberships/owner-a', 'cafes/a/members/owner-a']) f.store.put(p, {...f.store.docs.get(p), membershipGeneration: 1});
    await assert.rejects(f.generate(ticket.ticketId, input), SecureGroqError); assert.equal(f.calls(), 0);
  });
}
test('unbound legacy ticket rejected by secure handler', async () => {
  const f = fixture(); const old = createAiQuota({store: f.store});
  const ticket = await old.issue({auth: f.auth('a-staff-0'), expected});
  await assert.rejects(f.generate(ticket.ticketId), code('failed-precondition'));
  assert.equal(f.calls(), 0);
});
test('expired ticket rejected', async () => {
  const f = fixture(); const ticket = await f.issue(); f.advance(300000);
  await assert.rejects(f.generate(ticket.ticketId), code('failed-precondition')); assert.equal(f.calls(), 0);
});
test('duplicate concurrent generate calls dispatch once; lost response is not retrieved', async () => {
  const f = fixture(); const ticket = await f.issue();
  const results = await Promise.allSettled([f.generate(ticket.ticketId), f.generate(ticket.ticketId)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1); assert.equal(f.calls(), 1);
  await assert.rejects(f.generate(ticket.ticketId), code('already-exists'));
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
});
test('different tickets contend for one workspace reservation across users', async () => {
  const f = fixture(); const a = await f.issue(); const b = await f.issue({}, 'a-staff-1');
  let release; const stalled = new Promise(resolve => { release = resolve; });
  let entered; const started = new Promise(resolve => { entered = resolve; });
  f.provider(async () => { entered(); await stalled; return response(); });
  const first = f.generate(a.ticketId); await started;
  await assert.rejects(f.generate(b.ticketId, {}, 'a-staff-1'), code('resource-exhausted'));
  release(); await first; assert.equal(f.calls(), 1);
});
test('user 10/11 and workspace 30/31 enforced through handler', async () => {
  const f = fixture(); const extra = await f.issue();
  for (let i = 0; i < 10; i++) { const t = await f.issue(); await f.generate(t.ticketId); }
  await assert.rejects(f.generate(extra.ticketId), code('resource-exhausted'));
  const g = fixture(); const last = await g.issue({}, 'owner-a');
  for (let i = 0; i < 30; i++) {
    const uid = `a-staff-${i % 5}`; const t = await g.issue({}, uid); await g.generate(t.ticketId, {}, uid);
  }
  await assert.rejects(g.generate(last.ticketId, {}, 'owner-a'), code('resource-exhausted'));
});
test('timeout uses abort and keeps quarantine without refund', async () => {
  const f = fixture({timeoutMs: 5}); let signal;
  f.provider(async (_, options) => { signal = options.signal; return new Promise(() => {}); });
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('deadline-exceeded'));
  assert.equal(signal.aborted, true); assert.equal(f.calls(), 1);
  assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'quarantined');
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
});
for (const status of [401, 429, 500]) test('provider HTTP ' + status + ' uses safe accounting', async () => {
  const f = fixture(); f.provider(async () => new Response('sensitive error body', {status}));
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code(status === 429 ? 'resource-exhausted' : 'unavailable'));
  assert.equal(f.calls(), 1);
  assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, status === 500 ? 'quarantined' : 'completed');
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
});
test('network failure and forged error outcome hints cannot unlock quarantine', async () => {
  const f = fixture(); f.provider(async () => { const error = Error('unit-test-secret-placeholder'); error.providerRejected = true; throw error; });
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('unavailable'));
  assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'quarantined');
});
test('ambiguous successful dispatch commit does not call provider or retry', async () => {
  const f = fixture({quota: q => ({...q, dispatch: async input => {
    await q.dispatch(input); throw Error('unknown commit acknowledgement');
  }})});
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('unavailable'));
  assert.equal(f.calls(), 0); assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'quarantined');
});
for (const revocation of ['membership', 'account', 'Owner generation', 'inventory']) {
  test(revocation + ' changes during provider withhold fresh result without refund', async () => {
    const f = fixture(); f.provider(async () => {
      if (revocation === 'membership') f.store.put('user_cafe_memberships/a-staff-0', {...f.store.docs.get('user_cafe_memberships/a-staff-0'), status: 'inactive'});
      if (revocation === 'account') f.accounts.set('a-staff-0', {...f.accounts.get('a-staff-0'), disabled: true});
      if (revocation === 'Owner generation') for (const p of ['user_cafe_memberships/owner-a', 'cafes/a/members/owner-a']) f.store.put(p, {...f.store.docs.get(p), membershipGeneration: 1});
      if (revocation === 'inventory') f.store.put('cafes/a/inventory/item-1', {...f.store.docs.get('cafes/a/inventory/item-1'), quantity: 9});
      return response();
    });
    const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), SecureGroqError);
    assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
    assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'completed');
  });
}
for (const mode of ['missing key', 'malformed', 'oversized', 'secret echo', 'invalid quantities', 'incomplete']) {
  test(mode + ' fails safely', async () => {
    const f = fixture();
    if (mode === 'missing key') f.secret('');
    f.provider(async () => {
      if (mode === 'malformed') return new Response('not JSON');
      if (mode === 'oversized') return new Response('x'.repeat(65537));
      if (mode === 'secret echo') return response([{...recipe, title: 'unit-test-secret-placeholder'}]);
      if (mode === 'invalid quantities') return response([{...recipe, ingredients: [{itemId: 'i1', quantity: 100, unit: 'pcs'}]}]);
      return new Response(JSON.stringify({choices: [{finish_reason: 'length', message: {content: '{}'}}]}));
    });
    const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), SecureGroqError);
    if (mode === 'missing key') { assert.equal(f.calls(), 0); assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 0); }
    else assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'quarantined');
  });
}
test('empty inventory returns no suggestions without provider; no results stored', async () => {
  const f = fixture(); f.store.docs.delete('cafes/a/inventory/item-1');
  const t = await f.issue(); const result = await f.generate(t.ticketId);
  assert.equal(result.status, 'no_suggestions'); assert.equal(f.calls(), 0);
});
test('inventory bounds reject >100 and disclose 20-item selection', async () => {
  const f = fixture(); const item = f.store.docs.get('cafes/a/inventory/item-1');
  for (let i = 2; i <= 21; i++) f.store.put(`cafes/a/inventory/item-${i}`, item);
  const t = await f.issue(); const result = await f.generate(t.ticketId);
  assert.deepEqual(result.inventorySelection, {eligibleCount: 21, usedCount: 20});
  const g = fixture(); for (let i = 2; i <= 101; i++) g.store.put(`cafes/a/inventory/item-${i}`, item);
  const next = await g.issue(); await assert.rejects(g.generate(next.ticketId), code('resource-exhausted')); assert.equal(g.calls(), 0);
});
test('no deployed export, direct network default, Gemini integration or result persistence', () => {
  const index = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  assert.equal(index.includes('secure-groq-handler'), false);
  const source = fs.readFileSync(path.join(__dirname, '../src/secure-groq-handler.js'), 'utf8');
  assert.doesNotMatch(source, /globalThis\.fetch|fetch\(|console\.|defineSecret|onCall\(/);
});
test('JSON-escaped provider key is rejected after decoding', async () => {
  const f = fixture(); const content = JSON.stringify({recipes: [{...recipe, title: 'unit-test-secret-placeholder'}]})
    .replaceAll('unit-test-secret-placeholder', '\\u0075nit-test-secret-placeholder');
  f.provider(async () => new Response(JSON.stringify({choices: [{finish_reason: 'stop', message: {content}}]})));
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('unavailable'));
  assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'quarantined');
});
test('body-read stall times out and requests cancellation', async () => {
  const f = fixture({timeoutMs: 5}); let cancelled = false;
  f.provider(async () => ({ok: true, body: {getReader: () => ({
    read: () => new Promise(() => {}), cancel: () => { cancelled = true; return Promise.resolve(); },
  })}}));
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('deadline-exceeded'));
  assert.equal(cancelled, true); assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'quarantined');
});
test('late valid completion cannot release quarantine or deliver recipes', async () => {
  const f = fixture(); f.provider(async () => { f.advance(120000); return response(); });
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('unavailable'));
  assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'quarantined');
});
test('completion storage failure withholds result and never retries transport', async () => {
  const f = fixture({quota: q => ({...q, complete: async () => { throw Error('sensitive failure'); }})});
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('unavailable'));
  await assert.rejects(f.generate(t.ticketId), code('already-exists'));
  assert.equal(f.calls(), 1); assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'dispatched');
});
test('account disabled after admission is denied again before dispatch', async () => {
  let lookups = 0;
  const f = fixture({getAccount: async uid => ({uid, disabled: ++lookups >= 3, emailVerified: true})});
  const t = await f.issue(); await assert.rejects(f.generate(t.ticketId), code('unauthenticated'));
  assert.equal(f.calls(), 0); assert.equal(f.store.docs.get(`ai_generation_requests/${t.ticketId}`).state, 'admitted');
});
test('missing injected transport never falls back to live fetch', () => {
  assert.throws(() => createSecureGroqHandler({store: {}, getAccount: async () => ({}), getSecret: () => ''}), code('failed-precondition'));
});
