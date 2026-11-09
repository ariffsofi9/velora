import test, {before, after} from 'node:test';
import assert from 'node:assert/strict';
import controller from './entry.mjs';
import {names, scenario} from '../integration/scenarios.mjs';
// Ordinary Node unit tests: no bundler, runtime simulator, filesystem or child process.
const originalFetch = globalThis.fetch;
let outbound = 0;
before(() => {
  globalThis.fetch = async () => { outbound++; throw Error('Network forbidden in offline tests'); };
});
after(() => {
  globalThis.fetch = originalFetch;
  assert.equal(outbound, 1, 'only the deliberate guard probe may reach global fetch');
});
const options = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0, maxRecipes: 1};
const issue = {path: '/ai/issue', data: options};
const generate = {path: '/ai/generate', data: options, ticket: true};
async function run(input) {
  const response = await controller.fetch(new Request('https://offline.invalid/', {method: 'POST', body: JSON.stringify(input)}));
  assert.equal(response.status, 200); const result = await response.json();
  assert.equal(result.secretLeak ?? false, false); return result;
}
test('Node handler verifies RSA JWT, generates scoped AI and preserves stock', async () => {
  const r = await run({steps: [issue, generate]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200]); assert.equal(r.calls, 1);
  assert.equal(r.state['cafes/cafe/inventory/item'].quantity, 5);
});
for (const [name, change] of [['wrong project', {aud: 'other'}], ['expired', {exp: 1}]]) {
  test(`Node handler rejects ${name}`, async () => {
    const r = await run({steps: [{...issue, claims: change}]}); assert.equal(r.results[0].status, 401);
  });
}
test('Node handler rejects revoked and disabled accounts', async () => {
  for (const account of [{disabled: true}, {tokensValidAfterTime: '2099-01-01T00:00:00Z'}]) {
    const r = await run({account, steps: [issue]}); assert.equal(r.results[0].status, 401);
  }
});
test('Node handler denies cross-workspace and stale generation', async () => {
  const r = await run({steps: [{...issue, data: {...options, expectedCafeId: 'other'}},
    {...issue, data: {...options, expectedMembershipGeneration: 1}}]});
  assert.ok(r.results.every(x => x.status !== 200)); assert.equal(r.calls, 0);
});
test('Node handler concurrent replay dispatches at most once', async () => {
  const r = await run({steps: [issue, {parallel: [generate, generate]}]});
  assert.equal(r.calls, 1); assert.equal(r.results.slice(1).filter(x => x.status === 200).length, 1);
});
test('Node handler enforces issuance quota concurrently', async () => {
  const r = await run({steps: [{parallel: Array.from({length: 22}, () => issue)}]});
  assert.equal(r.results.filter(x => x.status === 200).length, 20);
});
test('Node handler Staff create, redeem, remove and revoked access', async () => {
  const r = await run({steps: [{path: '/staff/create', data: {email: 'joiner@example.test', requestId: 'request_123456789', expectedCafeId: 'cafe', expectedMembershipGeneration: 0}},
    {path: '/staff/redeem', uid: 'joiner', invite: true},
    {path: '/staff/remove', data: {targetUid: 'joiner', expectedCafeId: 'cafe', expectedGeneration: 0,
      expectedActorGeneration: 0, idempotencyKey: 'removal_123456789'}}, {path: '/staff/list', uid: 'joiner'}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200, 200, 403]);
});
test('Node handler revoked invitation cannot admit', async () => {
  const r = await run({steps: [{path: '/staff/create', data: {email: 'joiner@example.test', requestId: 'request_123456789', expectedCafeId: 'cafe', expectedMembershipGeneration: 0}},
    {path: '/staff/revoke', data: {expectedCafeId: 'cafe', expectedMembershipGeneration: 0}, revoke: true}, {path: '/staff/redeem', uid: 'joiner', invite: true}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200, 409]);
});
for (const mode of ['timeout', 'invalid', 'throw']) test(`Node handler ${mode} preserves uncertain outcome without redispatch`, async () => {
  const r = await run({mode, steps: [issue, generate, generate]});
  assert.notEqual(r.results[1].status, 200); assert.equal(r.calls, 1);
  assert.ok(Object.values(r.state).some(x => x.state === 'quarantined'));
});
test('Node handler request size and malformed JSON rejection', async () => {
  const r = await run({steps: [{path: '/ai/issue', raw: 'x'.repeat(2049)}, {path: '/ai/issue', raw: '{'}]});
  assert.deepEqual(r.results.map(x => x.status), [413, 400]);
});
test('Node offline guard rejects deliberate global fetch without sending a request', async () => {
  await assert.rejects(globalThis.fetch('https://unexpected.invalid/'), /Network forbidden/);
  assert.equal(outbound, 1);
});
test('Node handler response byte ceiling rejects oversized backend output', async () => {
  const response = await controller.fetch(new Request('https://offline.invalid/', {method: 'POST', body: JSON.stringify({scenario: 'output-limit'})}));
  assert.equal(response.status, 503); assert.deepEqual(await response.json(), {error: 'unavailable'});
});

const invitation = {email: 'joiner@example.test', requestId: 'request_123456789',
  expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const create = data => ({path: '/staff/create', data});
const business = op => /^(workspace_invitations|workspace_invite_requests|workspace_invite_limits)\//.test(op.path);
const inviteRows = state => Object.entries(state).filter(([path]) => path.startsWith('workspace_invitations/'));

for (const generation of [0, 7]) test(`explicit generation ${generation} binds issuance and code-only redemption`, async () => {
  const data = {...invitation, expectedMembershipGeneration: generation};
  const r = await run({ownerGeneration: generation, steps: [create(data), {path: '/staff/redeem', uid: 'joiner', invite: true}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200]);
  assert.deepEqual(r.requests[0].data, data);
  assert.deepEqual(r.requests[1].data, {code: r.results[0].body.code});
  const [row] = inviteRows(r.state).map(([, row]) => row);
  assert.equal(row.issuerBindingVersion, 1); assert.equal(row.issuerMembershipGeneration, generation);
  assert.equal(r.results[1].body.joined, true); assert.equal(r.results[1].body.cafeId, 'cafe');
  assert.match(r.results[0].body.invitationId, /^[a-f0-9]{32}$/);
  assert.match(r.results[0].body.code, new RegExp('^' + r.results[0].body.invitationId + '\\.[a-f0-9]{64}$'));
  assert.ok(Number.isFinite(Date.parse(r.results[0].body.expiresAt)));
});

const invalidContexts = [
  ['missing cafe', {expectedMembershipGeneration: 0}, 400],
  ['missing generation', {expectedCafeId: 'cafe'}, 400],
  ...[null, '0', -1, 0.5, Number.MAX_SAFE_INTEGER + 1].map(value => ['malformed ' + JSON.stringify(value), {expectedCafeId: 'cafe', expectedMembershipGeneration: value}, 400]),
  ['wrong workspace', {expectedCafeId: 'other', expectedMembershipGeneration: 0}, 409],
  ['stale generation', {expectedCafeId: 'cafe', expectedMembershipGeneration: 1}, 409],
];
for (const [label, context, status] of invalidContexts) test(`create and revoke reject ${label} before business operations`, async () => {
  const data = {email: invitation.email, requestId: invitation.requestId, ...context};
  const r = await run({steps: [create(data), {path: '/staff/revoke', data: {invitationId: 'a'.repeat(32), ...context}}]});
  assert.deepEqual(r.results.map(x => x.status), [status, status]);
  assert.deepEqual(r.requests[0].data, data, 'captured context must not be repaired');
  assert.ok(r.results.every(x => x.operations.filter(business).length === 0));
  assert.equal(inviteRows(r.state).length, 0);
});

test('current Owner revokes historical issuer binding; stale context cannot revoke it', async () => {
  const r = await run({steps: [create(invitation),
    {path: '/staff/revoke', revoke: true, ownerGeneration: 7, data: {expectedCafeId: 'cafe', expectedMembershipGeneration: 0}},
    {path: '/staff/revoke', revoke: true, data: {expectedCafeId: 'cafe', expectedMembershipGeneration: 7}}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 409, 200]);
  assert.equal(r.results[1].operations.filter(business).length, 0);
  assert.deepEqual(r.results[2].body, {revoked: true});
  assert.equal(inviteRows(r.state)[0][1].status, 'revoked');
  assert.equal(inviteRows(r.state)[0][1].issuerMembershipGeneration, 0);
});

for (const [patch, omitted] of [
  [{issuerBindingVersion: 2}, []], [{issuerBindingVersion: '1'}, []],
  [{issuerMembershipGeneration: '0'}, []], [{issuerMembershipGeneration: -1}, []],
  [{}, ['issuerBindingVersion']], [{}, ['issuerMembershipGeneration']],
  [{}, ['issuerBindingVersion', 'issuerMembershipGeneration']],
]) {
  test(`malformed or missing issuer binding rejects redemption: ${JSON.stringify({patch, omitted})}`, async () => {
    const r = await run({steps: [create(invitation), {path: '/staff/redeem', uid: 'joiner', invite: true,
      invitationPatch: patch, omitInvitationFields: omitted}]});
    assert.deepEqual(r.results.map(x => x.status), [200, 403]);
    assert.equal(r.state['user_cafe_memberships/joiner'], undefined);
    assert.equal(inviteRows(r.state)[0][1].status, 'pending');
  });
}

test('new Owner generation cannot redeem an older invitation', async () => {
  const r = await run({steps: [create(invitation), {path: '/staff/redeem', uid: 'joiner', invite: true, ownerGeneration: 7}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 403]);
  assert.equal(r.state['user_cafe_memberships/joiner'], undefined);
});

test('canonical Staff cannot forge Owner authority or supply issuer fields', async () => {
  for (const step of [{...create(invitation), uid: 'staff'}, create({...invitation, issuerMembershipGeneration: 0})]) {
    const r = await run({steps: [step]});
    assert.equal(r.results[0].status, step.uid ? 403 : 400);
    assert.equal(r.results[0].operations.filter(business).length, 0);
  }
});

test('redeemed and removed Staff cannot rejoin through the default backend', async () => {
  const r = await run({steps: [create(invitation), {path: '/staff/redeem', uid: 'joiner', invite: true},
    {path: '/staff/remove', data: {targetUid: 'joiner', expectedCafeId: 'cafe', expectedGeneration: 0,
      expectedActorGeneration: 0, idempotencyKey: 'removal_123456789'}},
    create({...invitation, requestId: 'request_987654321'}),
    {path: '/staff/redeem', uid: 'joiner', invite: true, invitationResultIndex: 3}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200, 200, 200, 409]);
  assert.equal(r.state['user_cafe_memberships/joiner'].status, 'inactive');
});

// The REST adapter is exercised with mock HTTP responses in ordinary Node only.
for (const name of names) test(`offline mock HTTP: ${name}`, async () => {
  const evidence = await scenario(name);
  assert.equal(evidence.ok, true);
});
