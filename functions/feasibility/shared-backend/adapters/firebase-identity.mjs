import {X509Certificate, webcrypto} from 'node:crypto';
import {createIdentity} from '../identity.mjs';
import {failure} from './http.mjs';
const endpoint = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
// Bind the SPKI key to RSASSA-PKCS1-v1_5/SHA-256 before exporting JWK.
// Direct X509 KeyObject -> JWK export fails on the pinned workerd runtime.
export async function certificateKey(pem, now) {
  const cert = new X509Certificate(pem);
  const from = Date.parse(cert.validFrom), to = Date.parse(cert.validTo);
  if (!Number.isFinite(from) || !Number.isFinite(to) || from > now || to <= now ||
      cert.publicKey.asymmetricKeyType !== 'rsa') throw failure('unauthenticated');
  const spki = cert.publicKey.export({format: 'der', type: 'spki'});
  const key = await webcrypto.subtle.importKey('spki', spki,
    {name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256'}, true, ['verify']);
  if (key.algorithm.modulusLength < 2048) throw failure('unauthenticated');
  return webcrypto.subtle.exportKey('jwk', key);
}
export function createFirebaseIdentity({http, getAccount, now = Date.now}) {
  let keys; let until = 0; let pending; let refreshedAt = -Infinity;
  async function refresh() {
    if (pending) return pending;
    if (now() - refreshedAt < 30000) throw failure('unauthenticated');
    refreshedAt = now();
    pending = (async () => {
      const r = await http(endpoint, {method: 'GET'});
      const match = /(?:^|,)\s*max-age=(\d+)/i.exec(r.headers.get('cache-control') ?? '');
      if (r.status !== 200 || !match || !r.data || Array.isArray(r.data)) throw failure();
      const entries = Object.entries(r.data); if (!entries.length || entries.length > 10) throw failure();
      const next = Object.create(null);
      for (const [kid, pem] of entries) {
        if (!/^[A-Za-z0-9_-]{1,128}$/.test(kid) || typeof pem !== 'string' || pem.length > 16384) throw failure();
        next[kid] = await certificateKey(pem, now());
      }
      const seconds = Math.min(Number(match[1]), 86400); if (!seconds) throw failure();
      keys = next; until = now() + seconds * 1000;
    })();
    try { await pending; } finally { pending = undefined; }
  }
  return async token => {
    try {
      if (typeof token !== 'string' || token.length > 8192) throw failure();
      const head = JSON.parse(Buffer.from(token.split('.')[0], 'base64url'));
      if (head.alg !== 'RS256' || typeof head.kid !== 'string') throw failure();
      if (!keys || now() >= until || !Object.hasOwn(keys, head.kid)) await refresh();
      if (!keys || now() >= until || !Object.hasOwn(keys, head.kid)) throw failure();
      return await createIdentity({projectId: 'velora-spark-test', keys, getAccount, now})(token);
    } catch { throw failure('unauthenticated'); }
  };
}
