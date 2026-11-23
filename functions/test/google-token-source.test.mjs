import assert from 'node:assert/strict';
import {generateKeyPairSync, verify} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {createRequire, registerHooks} from 'node:module';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {createRealWorkerAccess} from '../backend/backend-errors.mjs';
import {createWorkloadAccessToken} from '../backend/workload-access-token.mjs';

const workerFile = new URL('../runtime/google-token-source.mjs', import.meta.url);
const project = 'velora-73222';
const endpoint = 'https://oauth2.googleapis.com/token';
const token = 'synthetic-access-token';
const {privateKey, publicKey} = generateKeyPairSync('rsa', {modulusLength: 2048});
const credential = {type: 'service_account', project_id: project,
  private_key: privateKey.export({type: 'pkcs8', format: 'pem'})};
const googleToken = {access_token: token, token_type: 'Bearer', expires_in: 300};

const hooks = registerHooks({resolve(specifier, context, next) {
  if (specifier !== 'cloudflare:workers') return next(specifier, context);
  return {shortCircuit: true, url: 'data:text/javascript,export class WorkerEntrypoint {}'};
}});
let GoogleTokenSource;
try {
  ({GoogleTokenSource} = await import(workerFile.href));
} finally {
  hooks.deregister();
}

let fixtureId = 0;
function fixture(overrides = {}) {
  const identity = {...credential, client_email: `synthetic-${++fixtureId}@${project}.iam.gserviceaccount.com`, ...overrides};
  const worker = new GoogleTokenSource();
  worker.env = {VELORA_GOOGLE_SERVICE_ACCOUNT_KEY: JSON.stringify(identity)};
  return {worker, identity};
}

function response(data = googleToken) {
  return Object.defineProperty(Response.json(data), 'url', {value: endpoint});
}

function assertUnavailable(error) {
  assert.equal(error.message, 'unavailable');
  assert.equal(error.cause, undefined);
  assert.deepEqual(Object.keys(error), []);
  assert.doesNotMatch(error.stack, /PRIVATE KEY|synthetic-access-token|google-error-detail/);
  return true;
}

function checkAssertion(body, email) {
  const parameters = new URLSearchParams(body);
  assert.deepEqual([...parameters.keys()], ['grant_type', 'assertion']);
  assert.equal(parameters.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  const [header, claims, signature, extra] = parameters.get('assertion').split('.');
  assert.equal(extra, undefined);
  const decode = value => JSON.parse(Buffer.from(value, 'base64url'));
  assert.deepEqual(decode(header), {alg: 'RS256', typ: 'JWT'});
  const {iat, exp, ...binding} = decode(claims);
  assert.ok(Number.isInteger(iat) && Math.abs(Date.now() / 1000 - iat) < 10);
  assert.equal(exp - iat, 300);
  assert.deepEqual(binding, {iss: email, aud: endpoint,
    scope: 'https://www.googleapis.com/auth/identitytoolkit https://www.googleapis.com/auth/datastore'});
  assert.equal(verify('RSA-SHA256', Buffer.from(`${header}.${claims}`), publicKey,
    Buffer.from(signature, 'base64url')), true);
}

test('accepts REAL and sends a verifiable RS256 assertion with exact audience and scopes', async t => {
  const {worker, identity} = fixture();
  const fetch = t.mock.method(globalThis, 'fetch', async () => response());
  const result = await worker.acquire(project);
  assert.deepEqual(Object.keys(result), ['projectId', 'access_token', 'token_type', 'expires_in']);
  assert.equal(result.projectId, project);
  assert.equal(result.access_token, token);
  assert.equal(result.token_type, 'Bearer');
  assert.ok(result.expires_in >= 61 && result.expires_in <= 300);
  assert.equal(fetch.mock.callCount(), 1);
  const [url, request] = fetch.mock.calls[0].arguments;
  assert.equal(url, endpoint);
  assert.equal(request.method, 'POST');
  assert.equal(request.redirect, 'manual');
  assert.equal(request.headers['content-type'], 'application/x-www-form-urlencoded');
  checkAssertion(request.body, identity.client_email);
});

test('rejects wrong project before reading the secret, signing or fetching', async t => {
  const {worker} = fixture();
  const read = t.mock.fn();
  Object.defineProperty(worker, 'env', {get: read});
  const sign = t.mock.method(crypto.subtle, 'sign', async () => { throw Error('unexpected sign'); });
  const fetch = t.mock.method(globalThis, 'fetch', async () => { throw Error('unexpected fetch'); });
  for (const wrong of ['velora-spark-test', `${project} `, undefined, {projectId: project}]) {
    await assert.rejects(worker.acquire(wrong), assertUnavailable);
  }
  for (const mock of [read, sign, fetch]) assert.equal(mock.mock.callCount(), 0);
});

const invalidCredentials = [
  ['missing secret', undefined],
  ['invalid secret JSON', '{google-error-detail'],
  ['wrong service-account project', {project_id: 'other-project'}],
  ['wrong service-account email', {client_email: 'synthetic@other-project.iam.gserviceaccount.com'}],
  ['missing private key', {private_key: undefined}],
  ['malformed RSA key', {private_key: '-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n'}],
];
for (const [label, value] of invalidCredentials) {
  test(`${label} fails closed without network access`, async t => {
    const {worker} = fixture(typeof value === 'object' ? value : {});
    if (typeof value !== 'object') worker.env.VELORA_GOOGLE_SERVICE_ACCOUNT_KEY = value;
    const fetch = t.mock.method(globalThis, 'fetch', async () => { throw Error('unexpected fetch'); });
    await assert.rejects(worker.acquire(project), assertUnavailable);
    assert.equal(fetch.mock.callCount(), 0);
  });
}

const invalidResponses = [
  ['missing token', () => response({token_type: 'Bearer', expires_in: 300})],
  ['invalid token syntax', () => response({...googleToken, access_token: `${token}\n`})],
  ['wrong token type', () => response({...googleToken, token_type: 'bearer'})],
  ['expiry at the reserve', () => response({...googleToken, expires_in: 60})],
  ['non-integer expiry', () => response({...googleToken, expires_in: 120.5})],
  ['excessive expiry', () => response({...googleToken, expires_in: 3601})],
  ['redirect', () => Response.redirect('https://example.invalid/', 307)],
  ['different response URL', () => Object.defineProperty(response(), 'url', {value: 'https://example.invalid/'})],
  ['oversized response', () => response({...googleToken, extra: 'x'.repeat(16_384)})],
  ['malformed JSON', () => Object.defineProperty(new Response('{google-error-detail'), 'url', {value: endpoint})],
  ['network failure', () => { throw Error(`google-error-detail ${token}`); }],
];
for (const [label, invalid] of invalidResponses) {
  test(`${label} produces a generic error and does not populate the cache`, async t => {
    const {worker} = fixture();
    let called = false;
    const fetch = t.mock.method(globalThis, 'fetch', async () => {
      if (called) return response();
      called = true;
      return invalid();
    });
    await assert.rejects(worker.acquire(project), assertUnavailable);
    assert.equal((await worker.acquire(project)).access_token, token);
    assert.equal(fetch.mock.callCount(), 2);
  });
}

test('returns remaining lifetime, reuses the cache and refreshes ahead of expiry', async t => {
  const {worker} = fixture();
  let now = Date.now();
  t.mock.method(Date, 'now', () => now);
  const fetch = t.mock.method(globalThis, 'fetch', async () => response({...googleToken, expires_in: 120}));
  const initial = await worker.acquire(project);
  now += 20_000;
  const cached = await worker.acquire(project);
  assert.ok(initial.expires_in - cached.expires_in >= 19);
  assert.ok(cached.expires_in <= 100);
  assert.equal(fetch.mock.callCount(), 1);
  now += 35_500;
  assert.ok((await worker.acquire(project)).expires_in >= 119);
  assert.equal(fetch.mock.callCount(), 2);
  now += 120_000;
  assert.ok((await worker.acquire(project)).expires_in >= 119);
  assert.equal(fetch.mock.callCount(), 3);
});

test('secret replacement invalidates the previous cached token', async t => {
  const {worker, identity} = fixture();
  let exchange = 0;
  t.mock.method(globalThis, 'fetch', async () => response({...googleToken, access_token: `synthetic-${++exchange}`}));
  assert.equal((await worker.acquire(project)).access_token, 'synthetic-1');
  worker.env.VELORA_GOOGLE_SERVICE_ACCOUNT_KEY = JSON.stringify({...identity, private_key_id: 'replacement'});
  assert.equal((await worker.acquire(project)).access_token, 'synthetic-2');
  delete worker.env.VELORA_GOOGLE_SERVICE_ACCOUNT_KEY;
  await assert.rejects(worker.acquire(project), assertUnavailable);
  assert.equal(exchange, 2);
});

test('two cold invocations own independent I/O and a third fails closed at capacity', async t => {
  const {worker} = fixture();
  const bothStarted = Promise.withResolvers();
  const release = Promise.withResolvers();
  const signals = [];
  t.mock.method(globalThis, 'fetch', async (_url, {signal}) => {
    signals.push(signal);
    if (signals.length === 2) bothStarted.resolve();
    await release.promise;
    return response();
  });
  const first = worker.acquire(project);
  const second = worker.acquire(project);
  const results = Promise.all([first, second]);
  try {
    await bothStarted.promise;
    assert.notEqual(signals[0], signals[1]);
    await assert.rejects(worker.acquire(project), assertUnavailable);
    assert.equal(signals.length, 2);
  } finally {
    release.resolve();
    assert.deepEqual((await results).map(value => value.access_token), [token, token]);
  }
  assert.equal((await worker.acquire(project)).access_token, token);
  assert.equal(signals.length, 2);
});

test('upstream timeout aborts fetch, discards a late success and recovers', async t => {
  const {worker} = fixture();
  const started = Promise.withResolvers();
  const late = Promise.withResolvers();
  let count = 0;
  t.mock.method(globalThis, 'fetch', async (_url, {signal}) => {
    if (++count > 1) return response({...googleToken, access_token: 'synthetic-fresh'});
    started.resolve(signal);
    return late.promise;
  });
  const before = performance.now();
  const failure = assert.rejects(worker.acquire(project), assertUnavailable);
  const signal = await started.promise;
  try {
    await failure;
    assert.equal(signal.aborted, true);
    assert.ok(performance.now() - before < 5000);
  } finally {
    late.resolve(response());
  }
  assert.equal((await worker.acquire(project)).access_token, 'synthetic-fresh');
  assert.equal(count, 2);
});

test('existing REAL token consumer accepts the private result without a contract change', async t => {
  const {worker} = fixture();
  const fetch = t.mock.method(globalThis, 'fetch', async () => response());
  const acquire = Object.assign(async ({signal}) => {
    signal.throwIfAborted();
    return worker.acquire(project);
  }, {projectId: project});
  const admission = {projectId: project, acquire() { throw Error('unexpected admission'); }};
  const realWorker = createRealWorkerAccess({projectId: project, acquire, admission});
  const accessToken = createWorkloadAccessToken({projectId: project, realWorker, acquire});
  assert.equal(await accessToken(), token);
  assert.equal(await accessToken(), token);
  assert.equal(fetch.mock.callCount(), 1);
});

const localRequire = createRequire(new URL('../feasibility/shared-backend/runtime/package.json', import.meta.url));

test('Wrangler resolves the named private binding in REAL only and the source has no HTTP route', () => {
  const {unstable_readConfig: readConfig} = localRequire('wrangler');
  const config = name => fileURLToPath(new URL(`../runtime/${name}`, import.meta.url));
  const broker = readConfig({config: config('google-token-source.wrangler.jsonc')});
  assert.equal(broker.name, 'velora-google-token-source-real');
  assert.equal(broker.main, fileURLToPath(workerFile));
  assert.equal(broker.workers_dev, false);
  assert.equal(broker.preview_urls, false);
  assert.equal(broker.route, undefined);
  assert.equal(broker.routes, undefined);
  assert.deepEqual(broker.vars, {});
  const real = readConfig({config: config('wrangler.jsonc'), env: 'real'});
  assert.equal(real.name, 'rest-api');
  assert.equal(real.workers_dev, true);
  assert.equal(real.preview_urls, false);
  assert.equal(real.vars.VELORA_FIREBASE_PROJECT, 'velora-73222');
  assert.equal(real.vars.VELORA_PUBLIC_ORIGIN, 'https://rest-api.velora-smart-inventory.workers.dev');
  assert.deepEqual(real.durable_objects.bindings, [{name: 'ADMISSION', class_name: 'AdmissionCoordinator'}]);
  assert.deepEqual(real.services, [{binding: 'VELORA_GOOGLE_TOKEN_SOURCE', service: broker.name,
    entrypoint: 'GoogleTokenSource'}]);
  const testConfig = readConfig({config: config('wrangler.jsonc'), env: 'test'});
  assert.equal(testConfig.workers_dev, false);
  assert.deepEqual(testConfig.services, []);
});

test('local Workers runtime calls the named entrypoint over a private Service Binding', async () => {
  const {Miniflare} = localRequire('miniflare');
  const email = `synthetic-rpc@${project}.iam.gserviceaccount.com`;
  const requests = [];
  const runtime = new Miniflare({host: '127.0.0.1', cf: false, workers: [
    {name: 'caller', modules: true, compatibilityDate: '2026-06-11',
      script: `export default {async fetch(request, env) {
        try { return Response.json(await env.SOURCE.acquire(new URL(request.url).pathname.slice(1))); }
        catch { return Response.json({error: 'unavailable'}, {status: 503}); }
      }};`,
      serviceBindings: {SOURCE: {name: 'broker', entrypoint: 'GoogleTokenSource'}},
      outboundService: () => new Response(null, {status: 403})},
    {name: 'broker', modulesRoot: fileURLToPath(new URL('..', import.meta.url)), modules: [
      {type: 'ESModule', path: fileURLToPath(workerFile), contents: readFileSync(workerFile, 'utf8')},
      {type: 'ESModule', path: fileURLToPath(new URL('../backend/pre-auth-settlement.mjs', import.meta.url)),
        contents: readFileSync(new URL('../backend/pre-auth-settlement.mjs', import.meta.url), 'utf8')},
    ], compatibilityDate: '2026-06-11',
      bindings: {VELORA_GOOGLE_SERVICE_ACCOUNT_KEY: JSON.stringify({...credential, client_email: email})},
      async outboundService(request) {
        requests.push({url: request.url, method: request.method, body: await request.text()});
        return request.url === endpoint ? Response.json(googleToken) : new Response(null, {status: 403});
      }},
  ]});
  try {
    const wrong = await runtime.dispatchFetch('http://localhost/velora-spark-test');
    assert.equal(wrong.status, 503);
    assert.equal(requests.length, 0);
    const result = await runtime.dispatchFetch(`http://localhost/${project}`);
    assert.equal(result.status, 200);
    assert.equal((await result.json()).access_token, token);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, endpoint);
    assert.equal(requests[0].method, 'POST');
    checkAssertion(requests[0].body, email);
  } finally {
    await runtime.dispose();
  }
});
