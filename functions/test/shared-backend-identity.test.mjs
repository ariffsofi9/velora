import test from 'node:test';
import assert from 'node:assert/strict';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';
globalThis.fetch = () => { throw Error('Unexpected network'); };
const f = fakes.fixture();
test('cryptographically verifies synthetic Firebase-shaped JWT', async () => {
  assert.equal((await createIdentity(f.identity)(f.token())).uid, 'owner');
});
for (const [name, claims, header] of [
  ['wrong project', {aud: 'other'}], ['wrong issuer', {iss: 'other'}],
  ['expired', {exp: 1}], ['future issued', {iat: 9999999999}],
  ['future authentication', {auth_time: 9999999999}], ['missing verification', {email_verified: false}],
  ['invalid subject', {sub: '../owner'}], ['wrong email', {email: 'other@example.test'}],
  ['algorithm confusion', {}, {alg: 'HS256'}], ['unknown key', {}, {kid: 'other'}],
  ['remote key injection', {}, {jku: 'https://invalid.test'}],
]) test(`rejects ${name}`, async () => {
  await assert.rejects(createIdentity(f.identity)(f.token('owner', claims, header)), /unauthenticated/);
});
test('rejects tampered signature and malformed tokens', async () => {
  const token = f.token(); const parts = token.split('.');
  const signature = Buffer.from(parts[2], 'base64url'); signature[0] ^= 1;
  for (const bad of ['', 'a.b', `${parts[0]}.${parts[1]}.${signature.toString('base64url')}`, 'x'.repeat(9000)]) {
    await assert.rejects(createIdentity(f.identity)(bad));
  }
});
for (const [name, account] of [
  ['disabled', {disabled: true}], ['revoked', {tokensValidAfterTime: new Date(f.now() + 1000).toISOString()}],
  ['unverified', {emailVerified: false}], ['unknown revocation', {tokensValidAfterTime: 'bad'}],
]) test(`rejects ${name} authoritative fake account`, async () => {
  const verify = createIdentity({...f.identity, getAccount: async uid => ({...f.accounts[uid], ...account})});
  await assert.rejects(verify(f.token()));
});
test('unavailable account lookup fails closed', async () => {
  const verify = createIdentity({...f.identity, getAccount: async () => { throw Error('private'); }});
  await assert.rejects(verify(f.token()), {message: 'unauthenticated'});
});
