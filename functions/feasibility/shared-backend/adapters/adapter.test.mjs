import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync, sign, verify} from 'node:crypto';
import {createHttp} from './http.mjs';
import {createOAuth} from './google-oauth.mjs';
import {createAccounts} from './firebase-accounts.mjs';
import {createFirebaseIdentity, certificateKey} from './firebase-identity.mjs';
import {workspaceAuthority} from './workspace-authority.mjs';
import fakes from '../../../test/helpers/shared-backend-fakes.cjs';
globalThis.fetch = () => { throw Error('Unexpected network'); };
test('HTTP fixed endpoints, byte limit, deadline and redaction', async () => {
  const http = createHttp({transport: async () => Response.json({secret: 'SENTINEL'}), maxBytes: 2});
  await assert.rejects(http('https://evil.invalid'), /endpoint-denied/);
  await assert.rejects(http('https://oauth2.googleapis.com/token'), /response-limit/);
  const timed = createHttp({transport: () => new Promise(() => {}), timeoutMs: 5});
  await assert.rejects(timed('https://oauth2.googleapis.com/token'), /unavailable/);
  const error = createHttp({transport: async () => { throw Error('SENTINEL'); }});
  await assert.rejects(error('https://oauth2.googleapis.com/token'), {message: 'unavailable'});
});
test('OAuth synthetic RSA assertion, single-flight expiry and failed refresh', async () => {
  const pair = generateKeyPairSync('rsa', {modulusLength: 2048}); let now = 100000; let calls = 0; let fail = false;
  const token = createOAuth({email: 'synthetic@velora-spark-test.iam.gserviceaccount.com', now: () => now,
    sign: bytes => sign('RSA-SHA256', bytes, pair.privateKey), http: async (_, request) => {
      calls++; if (fail) throw Error('SENTINEL');
      const jwt = new URLSearchParams(request.body).get('assertion').split('.');
      assert.equal(verify('RSA-SHA256', Buffer.from(jwt.slice(0,2).join('.')), pair.publicKey, Buffer.from(jwt[2], 'base64url')), true);
      return {status: 200, data: {access_token: 'synthetic-token', token_type: 'Bearer', expires_in: 120}};
    }});
  assert.deepEqual(await Promise.all([token(), token()]), ['synthetic-token', 'synthetic-token']); assert.equal(calls, 1);
  now += 61000; await token(); assert.equal(calls, 2); now += 61000; fail = true;
  await assert.rejects(token(), {message: 'unavailable'});
});
const account = {localId: 'owner', email: 'owner@example.test', emailVerified: true, validSince: '0'};
for (const [name, users] of [['valid', [account]], ['deleted', []], ['disabled', [{...account, disabled: true}]],
  ['unverified', [{...account, emailVerified: false}]], ['malformed', [{...account, validSince: 'bad'}]]]) {
  test(`account lookup ${name}`, async () => {
    const lookup = createAccounts({accessToken: async () => 'synthetic', http: async () => ({status: 200, data: {users}})});
    if (name === 'valid') assert.equal((await lookup('owner')).uid, 'owner'); else await assert.rejects(lookup('owner'));
  });
}
test('account IAM denial/unavailability fails closed', async () => {
  for (const http of [async () => ({status: 403, data: {}}), async () => { throw Error('private'); }]) {
    await assert.rejects(createAccounts({http, accessToken: async () => 'synthetic'})('owner'), /unauthenticated/);
  }
});
test('canonical authority and stale/cross-workspace/role denial', async () => {
  const f = fakes.fixture(); const auth = {uid: 'owner', token: {email_verified: true}};
  const resolve = expected => f.store.runTransaction(tx => workspaceAuthority(tx, auth, expected));
  assert.equal((await resolve({})).role, 'owner');
  await assert.rejects(resolve({expectedCafeId: 'other'}));
  await assert.rejects(resolve({expectedMembershipGeneration: 1}));
  await f.store.runTransaction(async tx => tx.update('cafes/cafe/members/owner', {role: 'staff'}));
  await assert.rejects(resolve({}));
});
test('Firebase key fetch unavailable, malformed X509 and unknown-kid refresh bounded', async () => {
  const f = fakes.fixture(); let calls = 0;
  const identity = createFirebaseIdentity({now: f.now, getAccount: f.identity.getAccount,
    http: async () => { calls++; return {status: 200, headers: new Headers({'cache-control': 'max-age=3600'}), data: {synthetic: 'not a certificate'}}; }});
  await assert.rejects(identity(f.token())); await assert.rejects(identity(f.token())); assert.equal(calls, 1);
});
// Minimal self-signed test certificates, generated entirely in memory; not trusted credentials.
function syntheticCertificate(pair, from = '250101000000Z', to = '350101000000Z') {
  const der = (tag, ...parts) => {
    const bytes = Buffer.concat(parts); let length = bytes.length;
    const size = length < 128 ? Buffer.from([length]) : (() => { const list = []; while (length) { list.unshift(length & 255); length >>>= 8; } return Buffer.from([128 + list.length, ...list]); })();
    return Buffer.concat([Buffer.from([tag]), size, bytes]);
  };
  const seq = (...p) => der(48, ...p);
  const algorithm = seq(der(6, Buffer.from('2a864886f70d01010b', 'hex')), der(5));
  const name = seq(der(49, seq(der(6, Buffer.from('550403','hex')), der(12, Buffer.from('Synthetic only')))));
  const tbs = seq(der(2, Buffer.from([1])), algorithm, name,
    seq(der(23, Buffer.from(from)), der(23, Buffer.from(to))), name,
    pair.publicKey.export({format: 'der', type: 'spki'}));
  const cert = seq(tbs, algorithm, der(3, Buffer.from([0]), sign('RSA-SHA256', tbs, pair.privateKey)));
  return '-----BEGIN CERTIFICATE-----\n' + cert.toString('base64').match(/.{1,64}/g).join('\n') + '\n-----END CERTIFICATE-----';
}
test('valid X509 JWT, rotated key, expiry, invalid signature and account revocation', async () => {
  const pairs = [0,1].map(() => generateKeyPairSync('rsa', {modulusLength: 2048}));
  let clock = Date.UTC(2026,10,7); let index = 0; let available = true; let revoked = false;
  const identity = createFirebaseIdentity({now: () => clock, getAccount: async () => ({uid:'owner', disabled:false,
    emailVerified:true, email:'owner@example.test', tokensValidAfterTime: new Date(revoked ? clock + 1000 : 0).toISOString()}),
    http: async () => { if (!available) throw Error('private'); return {status:200, headers:new Headers({'cache-control':'max-age=60'}),
      data:{['key'+index]:syntheticCertificate(pairs[index])}}; }});
  const jwt = (overrides = {}, bad = false, header = {}) => {
    const e = x => Buffer.from(JSON.stringify(x)).toString('base64url');
    const body = e({alg:'RS256',kid:'key'+index,...header}) + '.' + e({sub:'owner',aud:'velora-spark-test',
      iss:'https://securetoken.google.com/velora-spark-test',iat:clock/1000,auth_time:clock/1000,
      exp:clock/1000+3600,email:'owner@example.test',email_verified:true,...overrides});
    return body + '.' + sign('RSA-SHA256',Buffer.from(body),pairs[bad ? 1-index : index].privateKey).toString('base64url');
  };
  assert.equal((await identity(jwt())).uid,'owner');
  for (const change of [{aud:'other'},{iss:'wrong'},{exp:1},{email:'changed@example.test'}]) await assert.rejects(identity(jwt(change)));
  await assert.rejects(identity(jwt({},true)));
  for (const header of [{alg:'none'},{alg:'HS256'},{jku:'https://untrusted.invalid/key'},{kid:'unknown'}]) await assert.rejects(identity(jwt({},false,header)));
  clock += 31000; index=1; assert.equal((await identity(jwt())).uid,'owner');
  revoked=true; await assert.rejects(identity(jwt())); revoked=false;
  clock+=61000; available=false; await assert.rejects(identity(jwt()));
});
test('SPKI conversion rejects malformed, expired, future, EC and weak RSA certificates', async () => {
  const time=Date.UTC(2026,10,7);
  const rsa=generateKeyPairSync('rsa',{modulusLength:2048});
  const key=await certificateKey(syntheticCertificate(rsa),time);
  assert.equal(key.kty,'RSA');assert.equal(key.alg,'RS256');
  for(const pem of ['invalid',syntheticCertificate(rsa,'240101000000Z','250101000000Z'),
    syntheticCertificate(rsa,'300101000000Z','350101000000Z'),
    syntheticCertificate(generateKeyPairSync('ec',{namedCurve:'prime256v1'})),
    syntheticCertificate(generateKeyPairSync('rsa',{modulusLength:1024}))]) await assert.rejects(certificateKey(pem,time));
});
