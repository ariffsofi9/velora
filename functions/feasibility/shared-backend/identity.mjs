// Offline feasibility only. Keys and account directory must be explicitly injected.
import {webcrypto} from 'node:crypto';
const fail = () => { throw new Error('unauthenticated'); };
const decode = value => {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) fail();
  return Buffer.from(value, 'base64url');
};
export function createIdentity({projectId, keys, getAccount, now = Date.now}) {
  if (projectId !== 'velora-spark-test' || !keys || typeof getAccount !== 'function') fail();
  return async token => {
    try {
      if (typeof token !== 'string' || token.length > 8192) fail();
      const parts = token.split('.');
      if (parts.length !== 3) fail();
      const header = JSON.parse(decode(parts[0]));
      const claims = JSON.parse(decode(parts[1]));
      if (header.alg !== 'RS256' || typeof header.kid !== 'string' ||
          header.crit !== undefined || header.jku !== undefined || header.jwk !== undefined ||
          !Object.hasOwn(keys, header.kid)) fail();
      const key = await webcrypto.subtle.importKey('jwk', keys[header.kid],
        {name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256'}, false, ['verify']);
      if (!await webcrypto.subtle.verify('RSASSA-PKCS1-v1_5', key, decode(parts[2]),
        new TextEncoder().encode(parts.slice(0, 2).join('.')))) fail();
      const time = Math.floor(now() / 1000);
      if (claims.aud !== projectId || claims.iss !== `https://securetoken.google.com/${projectId}` ||
          typeof claims.sub !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(claims.sub) ||
          !Number.isSafeInteger(claims.exp) || claims.exp <= time ||
          !Number.isSafeInteger(claims.iat) || claims.iat > time || claims.iat >= claims.exp ||
          !Number.isSafeInteger(claims.auth_time) || claims.auth_time < 0 || claims.auth_time > claims.iat ||
          (claims.nbf !== undefined && (!Number.isSafeInteger(claims.nbf) || claims.nbf > time)) ||
          claims.email_verified !== true || typeof claims.email !== 'string') fail();
      const user = await getAccount(claims.sub);
      const validAfter = Date.parse(user?.tokensValidAfterTime);
      if (user?.uid !== claims.sub || user.disabled !== false || user.emailVerified !== true ||
          user.email !== claims.email || !Number.isFinite(validAfter) || claims.auth_time * 1000 < validAfter) fail();
      return {uid: claims.sub, token: claims};
    } catch { fail(); }
  };
}
