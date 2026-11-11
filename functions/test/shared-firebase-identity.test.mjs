import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync, sign, X509Certificate} from 'node:crypto';
import {createFirebaseIdentity, createFirebaseAccounts} from '../backend/firebase-identity.mjs';
import {createGoogleHttp, CERTIFICATE_URL, OAUTH_URL} from '../backend/google-http.mjs';
import {createGoogleOAuth} from '../backend/google-oauth.mjs';
import creation from '../src/inventory-create.js';
import fakes from './helpers/shared-backend-fakes.cjs';
import {BackendError} from '../backend/backend-errors.mjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const initial = Date.UTC(2026, 10, 11);
const bind = fn => Object.assign(fn, {projectId});
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// Minimal DER fixture builder: generate and self-sign synthetic X509 certificates
// entirely in memory using Node crypto, without openssl, files or dependencies.
function der(tag, ...values) {
  const data = Buffer.concat(values.map(value => Buffer.from(value)));
  let hex = data.length.toString(16);
  if (hex.length % 2) hex = `0${hex}`;
  const size = Buffer.from(hex, 'hex');
  return Buffer.concat([Buffer.from([tag]), data.length < 128 ? Buffer.from([data.length]) :
    Buffer.concat([Buffer.from([128 + size.length]), size]), data]);
}
function certFixture({bits = 2048, from = initial - 86400000, until = initial + 86400000, ec = false} = {}) {
  const pair = ec ? generateKeyPairSync('ec', {namedCurve: 'prime256v1'}) :
    generateKeyPairSync('rsa', {modulusLength: bits});
  const algorithm = ec ? der(0x30, der(6, Buffer.from('2a8648ce3d040302', 'hex'))) :
    der(0x30, der(6, Buffer.from('2a864886f70d01010b', 'hex')), der(5, []));
  const name = der(0x30, der(0x31, der(0x30, der(6, [0x55, 4, 3]), der(0x0c, Buffer.from('SYNTHETIC OFFLINE')))));
  const utc = time => der(0x17, Buffer.from(new Date(time).toISOString().replace(/[-:T]/g, '').slice(2, 14) + 'Z'));
  const tbs = der(0x30, der(0xa0, der(2, [2])), der(2, [1]), algorithm, name,
    der(0x30, utc(from), utc(until)), name, pair.publicKey.export({format: 'der', type: 'spki'}));
  const bytes = der(0x30, tbs, algorithm, der(3, [0], sign('sha256', tbs, pair.privateKey)));
  const pem = `-----BEGIN CERTIFICATE-----\n${bytes.toString('base64').match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`;
  assert.equal(new X509Certificate(pem).verify(pair.publicKey), true);
  return {...pair, pem};
}
const primary = certFixture();
const rotated = certFixture();
const weak = certFixture({bits: 1024});
const nonRsa = certFixture({ec: true});
const expired = certFixture({from: initial - 172800000, until: initial - 1000});
const future = certFixture({from: initial + 1000, until: initial + 86400000});

function token({claims = {}, header = {}, pair = primary} = {}) {
  const head = Buffer.from(JSON.stringify({alg: 'RS256', kid: 'primary', typ: 'JWT', ...header})).toString('base64url');
  const body = Buffer.from(JSON.stringify({sub: 'owner', aud: projectId,
    iss: `https://securetoken.google.com/${projectId}`, iat: initial / 1000,
    auth_time: initial / 1000, exp: initial / 1000 + 3600,
    email_verified: true, email: 'owner@example.test', ...claims})).toString('base64url');
  return `${head}.${body}.${sign('RSA-SHA256', Buffer.from(`${head}.${body}`), pair.privateKey).toString('base64url')}`;
}
function fixture(overrides = {}) {
  let time = initial, certificateCalls = 0, accountCalls = 0;
  const account = {uid: 'owner', disabled: false, emailVerified: true, email: 'owner@example.test',
    tokensValidAfterTime: new Date(initial - 1000).toISOString()};
  const options = {projectId, now: () => time,
    http: bind(async url => {
      certificateCalls++;
      assert.equal(url, CERTIFICATE_URL);
      return {status: 200, headers: new Headers({'cache-control': 'public, max-age=3600'}), data: {primary: primary.pem}};
    }),
    getAccount: bind(async () => { accountCalls++; return {...account}; }), ...overrides};
  return {options, account, verify: createFirebaseIdentity(options), advance: ms => { time += ms; },
    certificateCalls: () => certificateCalls, accountCalls: () => accountCalls};
}
const identityFailure = error => error instanceof BackendError && error.kind === 'identity' &&
  error.code === 'unauthenticated' && error.cause === undefined && !JSON.stringify(error).includes('SECRET');

test('inert explicit TEST-bound configuration', () => {
  const f = fixture();
  assert.equal(f.certificateCalls(), 0);
  assert.equal(f.accountCalls(), 0);
  for (const patch of [{projectId: 'velora-73222'}, {http: async () => {}},
    {getAccount: Object.assign(async () => {}, {projectId: 'other'})}, {timeoutMs: 0}]) {
    assert.throws(() => createFirebaseIdentity({...f.options, ...patch}), BackendError);
  }
});

test('RSA/X509 verification, concurrent refresh single-flight, fresh account on every call', async () => {
  const f = fixture();
  const results = await Promise.all(Array.from({length: 12}, () => f.verify(token())));
  assert.ok(results.every(result => result.uid === 'owner' && result.token.sub === 'owner'));
  assert.equal(f.certificateCalls(), 1);
  assert.equal(f.accountCalls(), 12);
  assert.ok(Object.isFrozen(results[0].token));
  f.account.disabled = true;
  await assert.rejects(f.verify(token()), identityFailure);
  assert.equal(f.accountCalls(), 13);
});

for (const [name, claims] of [
  ['wrong project', {aud: 'velora-73222'}], ['wrong issuer', {iss: 'https://evil.invalid'}],
  ['missing UID', {sub: undefined}], ['UID traversal', {sub: '..'}], ['UID slash', {sub: 'a/b'}],
  ['empty UID', {sub: ''}], ['UID padded', {sub: ' owner '}],
  ['expired', {exp: initial / 1000}], ['future issuance', {iat: initial / 1000 + 1}],
  ['negative issuance', {iat: -1}], ['unsafe expiry', {exp: Number.MAX_SAFE_INTEGER + 1}],
  ['fractional expiry', {exp: initial / 1000 + 1.5}], ['string expiry', {exp: '9999999999'}],
  ['future auth', {auth_time: initial / 1000 + 1}], ['negative auth', {auth_time: -1}],
  ['missing auth', {auth_time: undefined}], ['auth after issuance', {iat: initial / 1000 - 1}],
  ['expiry before issuance', {exp: initial / 1000 - 1}], ['future nbf', {nbf: initial / 1000 + 1}],
  ['negative nbf', {nbf: -1}], ['string nbf', {nbf: '0'}],
  ['unverified email', {email_verified: false}], ['missing email', {email: undefined}],
  ['invalid email', {email: 'invalid'}], ['mismatched email', {email: 'other@example.test'}],
  ['email trailing newline', {email: 'owner@example.test\n'}],
]) test(`rejects signed claims: ${name}`, async () => {
  const f = fixture();
  await assert.rejects(f.verify(token({claims})), identityFailure);
});

for (const header of [{alg: 'none'}, {alg: 'HS256'}, {kid: ''}, {kid: 'primary\n'}, {kid: 'a'.repeat(129)},
  {jku: 'https://evil.invalid'}, {jwk: {}}, {x5u: 'https://evil.invalid'}, {crit: []}, {typ: 'CUSTOM'}]) {
  test(`rejects unsupported token header ${JSON.stringify(header)}`, async () => {
    const f = fixture();
    await assert.rejects(f.verify(token({header})), identityFailure);
    assert.equal(f.certificateCalls(), 0);
  });
}

test('wrong signatures, malformed encoding and unsupported token kinds rejected', async () => {
  const f = fixture();
  const original = token();
  const parts = original.split('.');
  const bytes = Buffer.from(parts[2], 'base64url'); bytes[0] ^= 1;
  for (const bad of ['', 'a.b', 'x'.repeat(8193), `${parts[0]}.${parts[1]}.${bytes.toString('base64url')}`,
    `${parts[0]}=.${parts[1]}.${parts[2]}`, token({pair: rotated}),
    token({claims: {aud: 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit'}})]) {
    await assert.rejects(f.verify(bad), identityFailure);
  }
  assert.equal(f.accountCalls(), 0);
});

for (const [name, patch] of [
  ['disabled', {disabled: true}], ['missing disabled', {disabled: undefined}],
  ['unverified', {emailVerified: false}], ['mismatched UID', {uid: 'other'}],
  ['mismatched email', {email: 'other@example.test'}], ['missing cutoff', {tokensValidAfterTime: undefined}],
  ['bad cutoff', {tokensValidAfterTime: 'SECRET'}],
  ['invalid calendar cutoff', {tokensValidAfterTime: '2026-02-30T00:00:00.000Z'}],
  ['revoked', {tokensValidAfterTime: new Date(initial + 1).toISOString()}],
]) test(`fresh account rejects ${name}`, async () => {
  const f = fixture(); Object.assign(f.account, patch);
  await assert.rejects(f.verify(token()), identityFailure);
});

test('revocation boundary equals auth_time accepted; nbf now accepted', async () => {
  const f = fixture(); f.account.tokensValidAfterTime = new Date(initial).toISOString();
  assert.equal((await f.verify(token({claims: {nbf: initial / 1000}}))).uid, 'owner');
});

for (const account of [null, {}, [], undefined]) test(`missing/malformed account ${JSON.stringify(account)}`, async () => {
  const f = fixture({getAccount: bind(async () => account)});
  await assert.rejects(f.verify(token()), identityFailure);
});

test('account exception sanitized and no authorization published', async () => {
  const f = fixture({getAccount: bind(async () => { throw Error('SECRET'); })});
  await assert.rejects(f.verify(token()), identityFailure);
});

test('account lookup freshness: token expires while lookup is pending', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({getAccount: bind(async () => { await gate; return {...f.account}; })});
  const assertion = assert.rejects(f.verify(token()), identityFailure);
  // Wait for lookup entry without relying on test-runner scheduling speed.
  await delay(10);
  f.advance(3600000);
  release();
  await assertion;
});

test('account timeout bounds verifier and late account cannot publish success', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({timeoutMs: 20, getAccount: bind(async () => { await gate; return {...f.account}; })});
  await assert.rejects(f.verify(token()), identityFailure);
  release(); await delay(5);
});

test('unknown kid refresh cooldown and rotation use single-flight', async () => {
  let certs = {primary: primary.pem}, calls = 0;
  const f = fixture({http: bind(async () => { calls++; return {status: 200,
    headers: new Headers({'cache-control': 'max-age=3600'}), data: certs}; })});
  await f.verify(token());
  await Promise.all(Array.from({length: 10}, () => assert.rejects(
    f.verify(token({header: {kid: 'rotated'}, pair: rotated})), identityFailure)));
  assert.equal(calls, 1);
  f.advance(30000);
  certs = {rotated: rotated.pem};
  const jwt = token({header: {kid: 'rotated'}, pair: rotated});
  await Promise.all(Array.from({length: 10}, () => f.verify(jwt)));
  assert.equal(calls, 2);
  await assert.rejects(f.verify(token()), identityFailure);
});

test('unknown-key failure is rate-limited even when key source fails', async () => {
  let calls = 0;
  const f = fixture({http: bind(async () => { calls++; throw Error('SECRET'); })});
  for (let i = 0; i < 5; i++) await assert.rejects(f.verify(token()), identityFailure);
  assert.equal(calls, 1);
  f.advance(30000);
  await assert.rejects(f.verify(token()), identityFailure);
  assert.equal(calls, 2);
});

test('cache age is subtracted; expired keys never fall back after failed refresh', async () => {
  let calls = 0;
  const f = fixture({http: bind(async () => {
    if (++calls > 1) throw Error('SECRET');
    return {status: 200, headers: new Headers({'cache-control': 'max-age=60', age: '30'}), data: {primary: primary.pem}};
  })});
  await f.verify(token());
  f.advance(30000);
  await assert.rejects(f.verify(token()), identityFailure);
  assert.equal(calls, 2);
});

test('certificate validity caps HTTP lifetime', async () => {
  const short = certFixture({until: initial + 30000});
  let calls = 0;
  const f = fixture({http: bind(async () => { calls++; return {status: 200,
    headers: new Headers({'cache-control': 'max-age=86400'}), data: {primary: short.pem}}; })});
  await f.verify(token({pair: short}));
  f.advance(30000);
  await assert.rejects(f.verify(token({pair: short})), identityFailure);
  assert.equal(calls, 2);
});

for (const [name, cert] of [['weak RSA', weak], ['non-RSA', nonRsa], ['expired', expired], ['future', future],
  ['malformed', {pem: 'SECRET'}]]) test(`rejects ${name} certificate`, async () => {
  const f = fixture({http: bind(async () => ({status: 200,
    headers: new Headers({'cache-control': 'max-age=3600'}), data: {primary: cert.pem}}))});
  await assert.rejects(f.verify(token()), identityFailure);
  assert.equal(f.accountCalls(), 0);
});

for (const policy of ['', 'max-age=0', 'max-age=no', 'no-store, max-age=3600',
  'max-age=3600, max-age=1']) test(`rejects invalid key cache policy ${policy}`, async () => {
  const f = fixture({http: bind(async () => ({status: 200,
    headers: new Headers({'cache-control': policy}), data: {primary: primary.pem}}))});
  await assert.rejects(f.verify(token()), identityFailure);
});

test('bounded HTTP and verifier compose using only injected transport and account OAuth', async () => {
  const destinations = [];
  const http = createGoogleHttp({projectId, transport: async (url, options) => {
    destinations.push(url);
    if (url === CERTIFICATE_URL) return Response.json({primary: primary.pem},
      {headers: {'cache-control': 'max-age=3600'}});
    if (url === OAUTH_URL) return Response.json({token_type: 'Bearer', access_token: 'server-only', expires_in: 3600});
    assert.equal(options.headers.authorization, 'Bearer server-only');
    assert.deepEqual(JSON.parse(options.body), {localId: ['owner']});
    return Response.json({users: [{localId: 'owner', email: 'owner@example.test', emailVerified: true,
      validSince: String(initial / 1000 - 1)}]});
  }});
  const accessToken = createGoogleOAuth({projectId, http, email: `synthetic@${projectId}.iam.gserviceaccount.com`,
    sign: async bytes => sign('RSA-SHA256', bytes, primary.privateKey), now: () => initial});
  const getAccount = createFirebaseAccounts({projectId, http, accessToken});
  const verify = createFirebaseIdentity({projectId, http, getAccount, now: () => initial});
  assert.equal((await verify(token())).uid, 'owner');
  assert.equal(destinations.length, 3);
  assert.equal(destinations[1], OAUTH_URL);
  assert.ok(destinations[2].includes(`/projects/${projectId}/`));
});

test('account factory rejects wrong project/credential binding before dispatch', () => {
  const options = {projectId, http: bind(async () => {}), accessToken: bind(async () => 'server-only')};
  for (const patch of [{projectId: 'velora-73222'}, {http: async () => {}},
    {accessToken: Object.assign(async () => {}, {projectId: 'other'})}]) {
    assert.throws(() => createFirebaseAccounts({...options, ...patch}), BackendError);
  }
});

for (const patch of [{users: []}, {users: [{localId: 'other'}]}, {users: [null]}, {users: {}},
  {users: [{localId: 'owner'}, {localId: 'owner'}]}]) test(`account cardinality/identity rejection ${JSON.stringify(patch)}`, async () => {
  const getAccount = createFirebaseAccounts({projectId, accessToken: bind(async () => 'server-only'),
    http: bind(async () => ({status: 200, data: patch}))});
  await assert.rejects(getAccount('owner'), {kind: 'account', code: 'unavailable'});
});

for (const patch of [{disabled: true}, {disabled: 'false'}, {emailVerified: false}, {email: 'bad'},
  {email: 'owner@example.test\n'},
  {validSince: undefined}, {validSince: '-1'}, {validSince: 1}, {validSince: '253402300800'},
  {validSince: '1.5'}]) test(`malformed account response ${JSON.stringify(patch)}`, async () => {
  const getAccount = createFirebaseAccounts({projectId, accessToken: bind(async () => 'server-only'),
    http: bind(async () => ({status: 200, data: {users: [{localId: 'owner', email: 'owner@example.test',
      emailVerified: true, validSince: '0', ...patch}]}}))});
  await assert.rejects(getAccount('owner'), {kind: 'account', code: 'unavailable'});
});

test('invalid account UID or timed-out credential cannot dispatch account lookup', async () => {
  let release, calls = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const getAccount = createFirebaseAccounts({projectId, timeoutMs: 15,
    accessToken: bind(async () => { await gate; return 'server-only'; }),
    http: bind(async () => { calls++; })});
  await assert.rejects(getAccount('../owner'), {kind: 'account'});
  await assert.rejects(getAccount('owner'), {kind: 'account'});
  release(); await delay(5);
  assert.equal(calls, 0);
});

test('account credential newline rejected before dispatch', async () => {
  let calls = 0;
  const getAccount = createFirebaseAccounts({projectId, accessToken: bind(async () => 'SECRET\n'),
    http: bind(async () => { calls++; })});
  await assert.rejects(getAccount('owner'), {kind: 'account'});
  assert.equal(calls, 0);
});

test('timed-out key refresh never starts account lookup on late completion', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({timeoutMs: 15, http: bind(async () => { await gate; return {status: 200,
    headers: new Headers({'cache-control': 'max-age=3600'}), data: {primary: primary.pem}}; })});
  await assert.rejects(f.verify(token()), identityFailure);
  release(); await delay(5);
  assert.equal(f.accountCalls(), 0);
});

for (const kind of ['missing membership', 'wrong workspace', 'stale generation', 'invalid owner']) {
  test(`verified claims cannot override canonical ${kind}`, async () => {
    const f = fixture();
    // Even Google-signed custom claims never provide workspace authority.
    const auth = await f.verify(token({claims: {role: 'owner', cafeId: 'other', membershipGeneration: 99}}));
    const seed = fakes.fixture().store.snapshot();
    if (kind === 'missing membership') delete seed['user_cafe_memberships/owner'];
    if (kind === 'invalid owner') seed['cafes/cafe/members/owner'].status = 'removed';
    const store = fakes.createStore(seed), before = store.snapshot();
    await assert.rejects(creation.createInventoryItem({auth, store,
      timestamp: () => new Date(initial), toTimestamp: date => date,
      data: {expectedCafeId: kind === 'wrong workspace' ? 'other' : 'cafe',
        expectedMembershipGeneration: kind === 'stale generation' ? 99 : 0,
        idempotencyKey: 'create-request-0001', name: 'Rice', category: 'Dry', quantity: 2,
        unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'}}),
    error => error instanceof creation.InventoryCreationError &&
      error.code === (['wrong workspace', 'stale generation'].includes(kind) ? 'aborted' : 'permission-denied'));
    assert.deepEqual(store.snapshot(), before);
  });
}

test('certificate expiry during account lookup cannot be hidden by cache rotation', async () => {
  const short = certFixture({until: initial + 30000});
  let certs = {primary: short.pem}, calls = 0, entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({http: bind(async () => ({status: 200,
    headers: new Headers({'cache-control': 'max-age=3600'}), data: certs})),
  getAccount: bind(async () => {
    if (++calls === 1) { entered(); await gate; }
    return {...f.account};
  })});
  const pending = assert.rejects(f.verify(token({pair: short})), identityFailure);
  await started;
  f.advance(30000);
  certs = {rotated: rotated.pem};
  await f.verify(token({pair: rotated, header: {kid: 'rotated'}}));
  release();
  await pending;
});
