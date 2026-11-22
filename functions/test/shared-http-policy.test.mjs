import test from 'node:test';
import assert from 'node:assert/strict';
import {createHttpPolicy} from '../backend/http-policy.mjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test', publicOrigin = 'https://backend.invalid', origin = 'https://frontend.invalid';
const routes = ['/inventory/create', '/staff/redeem'];
function setup(overrides = {}) {
  let calls = 0;
  const options = {projectId, publicOrigin, allowedOrigins: [origin], routes: [...routes],
    handler: async () => { calls++; return Response.json({ok: true}); }, ...overrides};
  return {options, policy: createHttpPolicy(options), calls: () => calls};
}
function request({path = '/inventory/create', method = 'POST', from = origin, headers = {}} = {}) {
  return new Request(publicOrigin + path, {method,
    headers: {...(from === undefined || from === null ? {} : {origin: from}), ...headers}});
}
function secure(response, expectedOrigin) {
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.ok(response.headers.get('vary').split(',').some(v => v.trim().toLowerCase() === 'origin'));
  assert.equal(response.headers.get('access-control-allow-origin'), expectedOrigin ?? null);
  assert.equal(response.headers.get('access-control-allow-credentials'), null);
}

test('inert explicit project/origin/route/admission configuration', () => {
  const f = setup(); assert.equal(f.calls(), 0);
  for (const patch of [{projectId: 'velora-73222'}, {publicOrigin: 'http://backend.invalid'},
    {publicOrigin: `${publicOrigin}/path`}, {allowedOrigins: ['*']}, {allowedOrigins: ['null']},
    {allowedOrigins: [`${origin}/`]}, {allowedOrigins: [origin, origin]}, {allowedOrigins: []},
    {maxConcurrent: 0}, {maxConcurrent: 101}, {routes: ['bad']}, {routes: [routes[0], routes[0]]}, {handler: null}]) {
    assert.throws(() => createHttpPolicy({...f.options, ...patch}));
  }
});

test('copies configuration; allowed and native POSTs retain secure headers', async () => {
  const f = setup(); f.options.allowedOrigins.push('https://evil.invalid'); f.options.routes.push('/ai/generate');
  for (const from of [origin, null]) {
    const response = await f.policy(request({from}));
    assert.equal(response.status, 200); secure(response, from);
  }
  assert.equal((await f.policy(request({from: 'https://evil.invalid'}))).status, 403);
  assert.equal((await f.policy(request({path: '/ai/generate'}))).status, 404);
  assert.equal(f.calls(), 2);
});

for (const from of ['null', 'https://evil.invalid', 'https://frontend.invalid.evil.invalid', `${origin}/`,
  `${origin}:444`, `${origin}, https://evil.invalid`]) test(`disallowed Origin ${from} never reaches handler`, async () => {
  const f = setup(), response = await f.policy(request({from}));
  assert.equal(response.status, 403); secure(response); assert.equal(f.calls(), 0);
});

for (const path of routes) test(`known-route preflight ${path} does no authentication or mutation`, async () => {
  const f = setup();
  const response = await f.policy(request({path, method: 'OPTIONS', headers: {
    'access-control-request-method': 'POST', 'access-control-request-headers': 'Authorization, Content-Type'}}));
  assert.equal(response.status, 204); assert.equal(await response.text(), ''); secure(response, origin);
  assert.equal(response.headers.get('access-control-allow-methods'), 'POST');
  assert.equal(response.headers.get('access-control-allow-headers'), 'authorization, content-type');
  assert.ok(response.headers.get('vary').includes('Access-Control-Request-Headers'));
  assert.equal(f.calls(), 0);
});

for (const [name, patch] of [
  ['missing origin', {from: null}], ['null origin', {from: 'null'}], ['disallowed origin', {from: 'https://evil.invalid'}],
  ['wrong method', {headers: {'access-control-request-method': 'GET'}}],
  ['forbidden header', {headers: {'access-control-request-method': 'POST', 'access-control-request-headers': 'x-role'}}],
  ['empty header token', {headers: {'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization,,content-type'}}],
  ['oversized headers', {headers: {'access-control-request-method': 'POST', 'access-control-request-headers': 'x'.repeat(257)}}],
]) test(`rejects malformed preflight: ${name}`, async () => {
  const f = setup();
  const response = await f.policy(request({method: 'OPTIONS', headers: {'access-control-request-method': 'POST'}, ...patch}));
  assert.equal(response.status, 403); assert.equal(f.calls(), 0);
});

for (const path of ['/inventory/reconcile', '/staff/remove', '/ai/generate', '/inventory/create?x=1', '/inventory/create#x']) {
  test(`unknown or extended route ${path} has no preflight or POST dispatch`, async () => {
    const f = setup();
    for (const method of ['OPTIONS', 'POST']) {
      const response = await f.policy(request({path, method}));
      assert.equal(response.status, 404); secure(response, origin);
    }
    assert.equal(f.calls(), 0);
  });
}

for (const method of ['GET', 'PUT', 'PATCH', 'DELETE']) test(`${method} is never a mutation alias`, async () => {
  const f = setup(), response = await f.policy(request({method}));
  assert.equal(response.status, 405); secure(response, origin); assert.equal(f.calls(), 0);
});

test('public endpoint binding rejects another host before dispatch', async () => {
  const f = setup();
  const response = await f.policy(new Request('https://other.invalid/inventory/create', {method: 'POST', headers: {origin}}));
  assert.equal(response.status, 404); assert.equal(f.calls(), 0);
});

test('Fetch ingress passes only route headers, the original stream and the cancellation signal', async () => {
  const inbound = new Request(publicOrigin + routes[0], {method: 'POST', body: '{}', headers: {
    host: 'BACKEND.INVALID:443', authorization: 'Bearer synthetic', 'content-type': 'application/json',
    'x-forwarded-for': '192.0.2.1', 'x-real-ip': '192.0.2.2', 'cf-connecting-ip': '192.0.2.3',
    forwarded: 'proto=http;host=other.invalid', 'x-forwarded-host': 'other.invalid',
    'x-forwarded-proto': 'http', 'x-client-uid': 'other-user', 'x-role': 'owner',
  }});
  const f = setup({handler: async accepted => {
    assert.equal(accepted.url, inbound.url);
    assert.equal(accepted.body, inbound.body);
    assert.equal(accepted.signal, inbound.signal);
    assert.deepEqual([...accepted.headers], [
      ['authorization', 'Bearer synthetic'], ['content-type', 'application/json'],
    ]);
    return Response.json({ok: true});
  }});
  assert.equal((await f.policy(inbound)).status, 200);
});

test('ambiguous authority and connection-nominated security headers never reach the handler', async () => {
  const f = setup();
  for (const headers of [{host: 'other.invalid'}, {host: 'backend.invalid, backend.invalid'},
    {host: 'backend.invalid:444'}, {connection: 'keep-alive, Authorization'}]) {
    const response = await f.policy(request({headers}));
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), {error: 'invalid-argument'});
  }
  assert.equal(f.calls(), 0);
});

test('a canceled POST does not consume a dispatch slot', async () => {
  const f = setup({maxConcurrent: 1});
  const controller = new AbortController();
  controller.abort();
  const canceled = new Request(publicOrigin + routes[0], {method: 'POST', signal: controller.signal});
  const response = await f.policy(canceled);
  assert.equal(response.status, 408);
  assert.deepEqual(await response.json(), {error: 'deadline-exceeded'});
  assert.equal(f.calls(), 0);
  assert.equal((await f.policy(request())).status, 200);
});

test('admission has no queue; preflight bypasses occupancy and capacity releases only on completion', async () => {
  let release, entered;
  const gate = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  let calls = 0;
  const f = setup({maxConcurrent: 1, handler: async () => { calls++; entered(); await gate; return Response.json({ok: true}); }});
  const first = f.policy(request()); await started;
  const denied = await f.policy(request());
  assert.equal(denied.status, 429); secure(denied, origin);
  assert.deepEqual(await denied.json(), {error: 'resource-exhausted'});
  assert.equal((await f.policy(request({method: 'OPTIONS', headers: {'access-control-request-method': 'POST'}}))).status, 204);
  assert.equal(calls, 1); release(); await first;
  assert.equal((await f.policy(request())).status, 200); assert.equal(calls, 2);
});

test('handler failures remain uncertain and release admission without leaking details', async () => {
  let first = true;
  const f = setup({maxConcurrent: 1, handler: async () => {
    if (first) { first = false; throw Error('SECRET'); }
    return Response.json({ok: true});
  }});
  const response = await f.policy(request());
  assert.equal(response.status, 503); secure(response, origin);
  assert.deepEqual(await response.json(), {error: 'unavailable', outcomeUnknown: true});
  assert.equal((await f.policy(request())).status, 200);
});

test('CORS override removes wildcard/credentials while preserving safe domain status/body', async () => {
  const f = setup({handler: async () => Response.json({error: 'permission-denied'}, {status: 403,
    headers: {'access-control-allow-origin': '*', 'access-control-allow-credentials': 'true', vary: 'Accept-Encoding'}})});
  const response = await f.policy(request());
  assert.equal(response.status, 403); secure(response, origin);
  assert.deepEqual(await response.json(), {error: 'permission-denied'});
  assert.equal(response.headers.get('vary'), 'Accept-Encoding, Origin');
});
