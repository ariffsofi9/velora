import test from 'node:test';
import assert from 'node:assert/strict';
import {createWorker} from '../feasibility/shared-backend/worker.mjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';
let networkAttempts = 0;
globalThis.fetch = () => { networkAttempts++; throw Error('Unexpected network'); };
test.after(() => assert.equal(networkAttempts, 0));
function setup() {
  const f = fakes.fixture();
  const worker = createWorker({verifyIdentity: createIdentity(f.identity), backend: f.backend});
  const call = async (path, data = {}, uid = 'owner') => worker.fetch(new Request(`https://offline.invalid${path}`, {
    method: 'POST', headers: {'content-type': 'application/json', authorization: `Bearer ${f.token(uid)}`}, body: JSON.stringify(data)}));
  return {...f, worker, call};
}
const expected = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0, maxRecipes: 1};
async function ticket(f) {
  const response = await f.call('/ai/issue', expected); assert.equal(response.status, 200);
  return (await response.json()).ticketId;
}
test('AI generation uses scoped inventory, validates output and never changes stock', async () => {
  const f = setup(); const before = f.store.snapshot()['cafes/cafe/inventory/item'];
  const response = await f.call('/ai/generate', {...expected, ticketId: await ticket(f)});
  assert.equal(response.status, 200); assert.equal((await response.json()).recipes[0].ingredients[0].itemId, 'item');
  assert.deepEqual(f.store.snapshot()['cafes/cafe/inventory/item'], before);
  assert.equal(f.calls.length, 1); assert.ok(!JSON.stringify(f.calls).includes(f.secret));
});
test('cross-workspace, stale generation and nonmember fail closed', async () => {
  const f = setup();
  for (const data of [{...expected, expectedCafeId: 'other'}, {...expected, expectedMembershipGeneration: 1}]) {
    assert.notEqual((await f.call('/ai/issue', data)).status, 200);
  }
  assert.equal((await f.call('/staff/list', {}, 'outsider')).status, 403);
  assert.equal(f.calls.length, 0);
});
test('malformed canonical role/generation and inactive owner fail closed', async () => {
  for (const patch of [{role: 'owner'}, {membershipGeneration: 1}, {status: 'inactive'}]) {
    const f = setup();
    await f.store.runTransaction(async tx => tx.update('cafes/cafe/members/staff', patch));
    assert.equal((await f.call('/staff/list', {}, 'staff')).status, 403);
  }
});
test('concurrent duplicate AI dispatch occurs once', async () => {
  const f = setup(); const data = {...expected, ticketId: await ticket(f)};
  const results = await Promise.all([f.call('/ai/generate', data), f.call('/ai/generate', data)]);
  assert.equal(results.filter(r => r.status === 200).length, 1); assert.equal(f.calls.length, 1);
});
test('concurrent ticket issuance cannot exceed user allowance', async () => {
  const f = setup(); const results = await Promise.all(Array.from({length: 24}, () => f.call('/ai/issue', expected)));
  assert.equal(results.filter(r => r.status === 200).length, 20);
  assert.equal(f.store.snapshot()['ai_usage_users/owner'].issued, 20);
});
test('workspace and user admitted quota caps reject dispatch', async () => {
  for (const [path, cap] of [['ai_usage_users/owner', 10], ['ai_usage_workspaces/cafe', 30]]) {
    const f = setup(); const id = await ticket(f);
    await f.store.runTransaction(async tx => tx.update(path, {admitted: cap}));
    assert.equal((await f.call('/ai/generate', {...expected, ticketId: id})).status, 429);
    assert.equal(f.calls.length, 0);
  }
});
test('Staff issuance, privacy, concurrent redemption, removal and historical replay', async () => {
  const f = setup();
  assert.equal((await f.call('/staff/create', {email: 'joiner@example.test', requestId: 'request_123456789'}, 'staff')).status, 403);
  const response = await f.call('/staff/create', {email: 'joiner@example.test', requestId: 'request_123456789'});
  assert.equal(response.status, 200); const invite = await response.json();
  assert.ok(!JSON.stringify(f.store.snapshot()).includes(invite.code));
  assert.equal((await f.call('/staff/redeem', {code: invite.code}, 'outsider')).status, 403);
  const results = await Promise.all([f.call('/staff/redeem', {code: invite.code}, 'joiner'), f.call('/staff/redeem', {code: invite.code}, 'joiner')]);
  assert.equal(results.filter(r => r.status === 200).length, 1);
  const data = {targetUid: 'joiner', expectedCafeId: 'cafe', expectedGeneration: 0,
    expectedActorGeneration: 0, idempotencyKey: 'removal_123456789'};
  assert.equal((await f.call('/staff/remove', data)).status, 200);
  assert.equal(f.store.snapshot()['user_cafe_memberships/joiner'].membershipGeneration, 1);
  assert.equal((await f.call('/staff/list', {}, 'joiner')).status, 403);
  const replay = await f.call('/staff/remove', data); assert.equal((await replay.json()).changed, false);
});
test('revoked and expired invitations cannot admit membership', async () => {
  for (const expired of [false, true]) {
    const f = setup();
    const invite = await (await f.call('/staff/create', {email: 'joiner@example.test', requestId: 'request_123456789'})).json();
    if (expired) f.advance(86400001);
    else assert.equal((await f.call('/staff/revoke', {invitationId: invite.invitationId})).status, 200);
    // Advance expiry directly in the store to avoid also expiring the synthetic ID token.
    if (expired) f.advance(-86400001);
    if (expired) await f.store.runTransaction(async tx => tx.update(`workspace_invitations/${invite.invitationId}`, {expiresAt: new Date(0)}));
    assert.notEqual((await f.call('/staff/redeem', {code: invite.code}, 'joiner')).status, 200);
    assert.equal(f.store.snapshot()['user_cafe_memberships/joiner'], undefined);
  }
});
test('transaction commit failure rolls back staged writes', async () => {
  const f = setup(); const before = f.store.snapshot();
  // Exercise the transaction store directly: shared scope uses a read transaction first.
  f.store.failCommit = true;
  await assert.rejects(f.store.runTransaction(async tx => {
    tx.create('synthetic/first', {value: 1}); tx.create('synthetic/second', {value: 2});
  }));
  assert.deepEqual(f.store.snapshot(), before);
});
test('invitation transaction failure cannot publish partial records', async () => {
  const f = setup(); const before = f.store.snapshot();
  const original = f.store.runTransaction.bind(f.store); let count = 0;
  f.store.runTransaction = async action => {
    if (++count === 2) f.store.failCommit = true;
    return original(action);
  };
  assert.equal((await f.call('/staff/create', {email: 'joiner@example.test', requestId: 'request_123456789'})).status, 503);
  assert.deepEqual(f.store.snapshot(), before);
});
test('payload conflict and client operation injection do not dispatch', async () => {
  const f = setup(); const id = await ticket(f);
  assert.equal((await f.call('/ai/generate', {...expected, maxRecipes: 2, ticketId: id})).status, 409);
  assert.equal((await f.call('/ai/issue', {...expected, operation: 'generate'})).status, 400);
  assert.equal(f.calls.length, 0);
});
test('chunked request exceeds limit regardless of claimed content length', async () => {
  const f = setup(); let cancelled = false;
  const body = new ReadableStream({start(controller) {
    controller.enqueue(new Uint8Array(1024)); controller.enqueue(new Uint8Array(1025));
  }, cancel() { cancelled = true; }});
  const request = new Request('https://offline.invalid/ai/issue', {method: 'POST', duplex: 'half', body,
    headers: {'content-type': 'application/json', 'content-length': '1'}});
  assert.equal((await f.worker.fetch(request)).status, 413); assert.equal(cancelled, true);
});
for (const mode of ['invalid', 'throw', 'timeout']) test(`provider ${mode} quarantines without replay or secret leakage`, async () => {
  const f = setup(); f.mode(mode); const data = {...expected, ticketId: await ticket(f)};
  const logs = []; const original = console.error; console.error = (...args) => logs.push(args);
  try {
    const response = await f.call('/ai/generate', data);
    assert.notEqual(response.status, 200); assert.ok(!(await response.text()).includes(f.secret));
    assert.notEqual((await f.call('/ai/generate', data)).status, 200);
    assert.equal(f.calls.length, 1);
    assert.equal(f.store.snapshot()[`ai_generation_tickets/${data.ticketId}`].state, 'quarantined');
    assert.ok(!JSON.stringify(logs).includes(f.secret));
  } finally { console.error = original; }
});
test('request bounds, malformed JSON, missing identity and output bounds', async () => {
  const f = setup();
  for (const [body, status] of [['x'.repeat(2050), 413], ['{', 400], ['[]', 400]]) {
    const response = await f.worker.fetch(new Request('https://offline.invalid/ai/issue', {
      method: 'POST', headers: {'content-type': 'application/json'}, body}));
    assert.equal(response.status, status);
  }
  assert.equal((await f.worker.fetch(new Request('https://offline.invalid', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'}))).status, 401);
  const worker = createWorker({verifyIdentity: async () => ({}), backend: async () => ({data: 'x'.repeat(65537)})});
  assert.equal((await worker.fetch(new Request('https://offline.invalid', {method: 'POST', headers: {'content-type': 'application/json', authorization: 'Bearer synthetic'}, body: '{}'}))).status, 503);
});
