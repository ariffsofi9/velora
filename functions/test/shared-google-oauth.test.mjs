import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync, sign, verify} from 'node:crypto';
import {createGoogleOAuth} from '../backend/google-oauth.mjs';
import {OAUTH_URL} from '../backend/google-http.mjs';
import {BackendError} from '../backend/backend-errors.mjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const email = `synthetic@${projectId}.iam.gserviceaccount.com`;
const pair = generateKeyPairSync('rsa', {modulusLength: 2048});
const bind = fn => Object.assign(fn, {projectId});
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function fixture(overrides = {}) {
  let time = Date.UTC(2026, 10, 11), signs = 0;
  const calls = [];
  const options = {projectId, email, now: () => time,
    sign: async bytes => { signs++; return sign('RSA-SHA256', bytes, pair.privateKey); },
    http: bind(async (url, options) => { calls.push({url, options});
      return {status: 200, data: {token_type: 'Bearer', access_token: 'synthetic-token', expires_in: 3600}};
    }), ...overrides};
  return {options, calls, signs: () => signs, advance: ms => { time += ms; }, token: createGoogleOAuth(options)};
}

test('explicit project/principal/dependency configuration and inert construction', () => {
  const f = fixture();
  assert.equal(f.signs(), 0);
  assert.equal(f.calls.length, 0);
  for (const patch of [{projectId: 'velora-73222'}, {email: 'x@other.iam.gserviceaccount.com'}, {email: `${email}\n`},
    {http: Object.assign(async () => {}, {projectId: 'other'})}, {sign: null}, {timeoutMs: 0}]) {
    assert.throws(() => createGoogleOAuth({...f.options, ...patch}), BackendError);
  }
});

test('signed assertion, least scoped token separation, single-flight and conservative cache refresh', async () => {
  const f = fixture();
  const tokens = await Promise.all(Array.from({length: 20}, () => f.token()));
  assert.ok(tokens.every(token => token === 'synthetic-token'));
  assert.equal(f.signs(), 1);
  assert.equal(f.calls.length, 1);
  const {url, options} = f.calls[0];
  assert.equal(url, OAUTH_URL);
  const form = new URLSearchParams(options.body);
  assert.equal(form.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  const jwt = form.get('assertion').split('.');
  assert.deepEqual(JSON.parse(Buffer.from(jwt[0], 'base64url')), {alg: 'RS256', typ: 'JWT'});
  const claims = JSON.parse(Buffer.from(jwt[1], 'base64url'));
  assert.equal(claims.iss, email);
  assert.equal(claims.aud, OAUTH_URL);
  assert.equal(claims.exp - claims.iat, 3600);
  assert.equal(claims.scope, 'https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/identitytoolkit');
  assert.equal(verify('RSA-SHA256', Buffer.from(jwt.slice(0, 2).join('.')), pair.publicKey,
    Buffer.from(jwt[2], 'base64url')), true);
  await f.token();
  assert.equal(f.calls.length, 1);
  f.advance(3540000);
  await f.token();
  assert.equal(f.calls.length, 2);
});

for (const [name, patch] of [
  ['wrong type', {token_type: 'bearer'}], ['missing token', {access_token: undefined}],
  ['token injection', {access_token: 'SECRET\r\n'}], ['wrong token type', {access_token: 12}],
  ['token trailing newline', {access_token: 'SECRET\n'}],
  ['expired', {expires_in: 0}], ['short TTL', {expires_in: 60}],
  ['excess TTL', {expires_in: 3601}], ['fractional TTL', {expires_in: 3600.5}],
  ['string TTL', {expires_in: '3600'}],
]) test(`rejects malformed OAuth ${name} without caching`, async () => {
  let calls = 0;
  const f = fixture({http: bind(async () => { calls++; return {status: 200,
    data: {token_type: 'Bearer', access_token: 'synthetic', expires_in: 3600, ...patch}}; })});
  for (let i = 0; i < 2; i++) await assert.rejects(f.token(), error =>
    error instanceof BackendError && error.kind === 'oauth' && !JSON.stringify(error).includes('SECRET'));
  assert.equal(calls, 2); // Explicit new calls only; no automatic retry.
});

for (const phase of ['sign', 'http']) test(`${phase} timeout rejects and ignores late completion`, async () => {
  let release, calls = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({timeoutMs: 15,
    sign: async bytes => { if (phase === 'sign') await gate; return sign('RSA-SHA256', bytes, pair.privateKey); },
    http: bind(async () => { calls++; if (phase === 'http') await gate;
      return {status: 200, data: {token_type: 'Bearer', access_token: 'late', expires_in: 3600}}; })});
  await assert.rejects(f.token(), {kind: 'oauth', code: 'unavailable'});
  release();
  await delay(10);
  assert.equal(calls, phase === 'sign' ? 0 : 1);
  assert.equal(await f.token(), 'late');
  assert.equal(calls, phase === 'sign' ? 1 : 2);
});

test('clock rollback invalidates cache and factory captures dependencies', async () => {
  const f = fixture();
  await f.token();
  f.advance(-1000);
  await f.token();
  assert.equal(f.calls.length, 2);
  f.advance(3600000);
  f.options.http = null; // Factory captured dependencies, never ambient config.
  await f.token();
  assert.equal(f.calls.length, 3);
});

test('failed refresh discards old token; explicit next call can recover', async () => {
  let calls = 0;
  const f = fixture({http: bind(async () => {
    calls++;
    if (calls === 2) throw Error('SECRET');
    return {status: 200, data: {token_type: 'Bearer', access_token: `token-${calls}`, expires_in: 3600}};
  })});
  assert.equal(await f.token(), 'token-1');
  f.advance(3540000);
  await assert.rejects(f.token(), {kind: 'oauth'});
  assert.equal(calls, 2);
  assert.equal(await f.token(), 'token-3');
});

for (const patch of [
  {sign: async () => { throw Error('SECRET'); }}, {sign: async () => new Uint8Array(10)},
  {http: bind(async () => { throw Error('SECRET'); })},
  {http: bind(async () => ({status: 401, data: {error: 'SECRET'}}))},
  {now: () => NaN},
]) test(`sanitized signer/credential/response failure ${Object.keys(patch)[0]}`, async () => {
  const f = fixture(patch);
  await assert.rejects(f.token(), error => error.kind === 'oauth' && error.message === 'unavailable' &&
    error.cause === undefined && !JSON.stringify(error).includes('SECRET'));
});
