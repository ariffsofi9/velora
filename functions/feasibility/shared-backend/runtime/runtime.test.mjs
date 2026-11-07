import test, {before, after} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {Miniflare, createFetchMock} from 'miniflare';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
const directory = fileURLToPath(new URL('.', import.meta.url));
let mf; let outbound = 0;
before(async () => {
  await mkdir(new URL('.tmp/', import.meta.url), {recursive: true});
  await build({entryPoints: [fileURLToPath(new URL('entry.mjs', import.meta.url))],
    outfile: fileURLToPath(new URL('.tmp/worker.mjs', import.meta.url)), bundle: true,
    format: 'esm', platform: 'browser', external: ['node:*'],
    banner: {js: 'import * as cryptoModule from "node:crypto"; const require = name => { if (name === "node:crypto") return cryptoModule; throw Error("Unexpected module: " + name); };'}});
  const fetchMock = createFetchMock(); fetchMock.disableNetConnect();
  // Explicitly mock no destinations: every outbound Worker fetch is denied.
  mf = new Miniflare({modules: true, scriptPath: directory + '.tmp/worker.mjs',
    compatibilityDate: '2026-06-11', compatibilityFlags: ['nodejs_compat'], fetchMock});
  await mf.ready;
});
after(async () => { await mf?.dispose(); });
const options = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0, maxRecipes: 1};
const issue = {path: '/ai/issue', data: options};
const generate = {path: '/ai/generate', data: options, ticket: true};
async function run(input) {
  const response = await mf.dispatchFetch('http://localhost/', {method: 'POST', body: JSON.stringify(input)});
  assert.equal(response.status, 200); const result = await response.json();
  assert.equal(result.secretLeak ?? false, false); return result;
}
test('workerd loads entrypoint, verifies RSA JWT, generates scoped AI and preserves stock', async () => {
  const r = await run({steps: [issue, generate]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200]); assert.equal(r.calls, 1);
  assert.equal(r.state['cafes/cafe/inventory/item'].quantity, 5);
});
for (const [name, change] of [['wrong project', {aud: 'other'}], ['expired', {exp: 1}]]) {
  test(`workerd rejects ${name}`, async () => {
    const r = await run({steps: [{...issue, claims: change}]}); assert.equal(r.results[0].status, 401);
  });
}
test('workerd rejects revoked and disabled accounts', async () => {
  for (const account of [{disabled: true}, {tokensValidAfterTime: '2099-01-01T00:00:00Z'}]) {
    const r = await run({account, steps: [issue]}); assert.equal(r.results[0].status, 401);
  }
});
test('workerd denies cross-workspace and stale generation', async () => {
  const r = await run({steps: [{...issue, data: {...options, expectedCafeId: 'other'}},
    {...issue, data: {...options, expectedMembershipGeneration: 1}}]});
  assert.ok(r.results.every(x => x.status !== 200)); assert.equal(r.calls, 0);
});
test('workerd concurrent replay dispatches at most once', async () => {
  const r = await run({steps: [issue, {parallel: [generate, generate]}]});
  assert.equal(r.calls, 1); assert.equal(r.results.slice(1).filter(x => x.status === 200).length, 1);
});
test('workerd enforces issuance quota concurrently', async () => {
  const r = await run({steps: [{parallel: Array.from({length: 22}, () => issue)}]});
  assert.equal(r.results.filter(x => x.status === 200).length, 20);
});
test('workerd Staff create, redeem, remove and revoked access', async () => {
  const r = await run({steps: [{path: '/staff/create', data: {email: 'joiner@example.test', requestId: 'request_123456789'}},
    {path: '/staff/redeem', uid: 'joiner', invite: true},
    {path: '/staff/remove', data: {targetUid: 'joiner', expectedCafeId: 'cafe', expectedGeneration: 0,
      expectedActorGeneration: 0, idempotencyKey: 'removal_123456789'}}, {path: '/staff/list', uid: 'joiner'}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200, 200, 403]);
});
test('workerd revoked invitation cannot admit', async () => {
  const r = await run({steps: [{path: '/staff/create', data: {email: 'joiner@example.test', requestId: 'request_123456789'}},
    {path: '/staff/revoke', revoke: true}, {path: '/staff/redeem', uid: 'joiner', invite: true}]});
  assert.deepEqual(r.results.map(x => x.status), [200, 200, 409]);
});
for (const mode of ['timeout', 'invalid', 'throw']) test(`workerd ${mode} preserves uncertain outcome without redispatch`, async () => {
  const r = await run({mode, steps: [issue, generate, generate]});
  assert.notEqual(r.results[1].status, 200); assert.equal(r.calls, 1);
  assert.ok(Object.values(r.state).some(x => x.state === 'quarantined'));
});
test('workerd request size and malformed JSON rejection', async () => {
  const r = await run({steps: [{path: '/ai/issue', raw: 'x'.repeat(2049)}, {path: '/ai/issue', raw: '{'}]});
  assert.deepEqual(r.results.map(x => x.status), [413, 400]);
});
test('workerd deliberately attempted egress is blocked', async () => {
  const r = await run({scenario: 'egress'}); assert.equal(r.blocked, true); outbound++;
  assert.equal(outbound, 1);
});
test('workerd response byte ceiling rejects oversized backend output', async () => {
  const response = await mf.dispatchFetch('http://localhost/', {method: 'POST', body: JSON.stringify({scenario: 'output-limit'})});
  assert.equal(response.status, 503); assert.deepEqual(await response.json(), {error: 'unavailable'});
});
