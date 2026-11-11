import {X509Certificate, webcrypto} from 'node:crypto';
import {BackendError, bounded, requireTestProject, validBudget} from './backend-errors.mjs';
import {CERTIFICATE_URL} from './google-http.mjs';

const uidShape = value => typeof value === 'string' && value.length >= 1 && value.length <= 128 &&
  value.trim() === value && value !== '.' && value !== '..' && !/[\\/\p{Cc}]/u.test(value);
const emailShape = value => typeof value === 'string' && value.trim() === value && value.length <= 254 &&
  /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
const kidShape = value => typeof value === 'string' && value.trim() === value && /^[A-Za-z0-9_-]{1,128}$/.test(value);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const fail = kind => { throw new BackendError(kind, kind === 'identity' ? 'unauthenticated' : 'unavailable'); };
const clock = now => {
  const time = now();
  if (!Number.isSafeInteger(time) || time < 0 || time > 253402300799000) throw Error();
  return time;
};

// Internal trusted account lookup only, with no public route or positive cache.
// Batch/email enumeration remains unavailable in this foundation.
export function createFirebaseAccounts({projectId, http, accessToken, timeoutMs = 5000} = {}) {
  requireTestProject(projectId);
  if (typeof http !== 'function' || http.projectId !== projectId ||
      typeof accessToken !== 'function' || accessToken.projectId !== projectId || !validBudget(timeoutMs)) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const getAccount = async uid => {
    if (!uidShape(uid)) fail('account');
    let active = true;
    try {
      return await bounded(async () => {
        const token = await accessToken();
        if (!active || typeof token !== 'string' || token.trim() !== token ||
            !/^[A-Za-z0-9._~+/-]{1,8192}={0,2}$/.test(token)) throw Error();
        const r = await http(`https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`, {
          method: 'POST', headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'},
          body: JSON.stringify({localId: [uid]})});
        const users = r.data?.users;
        if (!active || r.status !== 200 || !Array.isArray(users) || users.length !== 1) throw Error();
        const u = users[0];
        if (!object(u) || u.localId !== uid ||
            (u.disabled !== undefined && typeof u.disabled !== 'boolean') || u.disabled === true ||
            u.emailVerified !== true || !emailShape(u.email) ||
            typeof u.validSince !== 'string' || !/^(?:0|[1-9]\d{0,11})$/.test(u.validSince) ||
            !Number.isSafeInteger(Number(u.validSince)) || Number(u.validSince) > 253402300799) throw Error();
        return Object.freeze({uid, disabled: false, emailVerified: true, email: u.email,
          tokensValidAfterTime: new Date(Number(u.validSince) * 1000).toISOString()});
      }, timeoutMs, 'account');
    } catch { fail('account'); }
    finally { active = false; }
  };
  return Object.freeze(Object.assign(getAccount, {projectId}));
}

function decode(value, maxBytes) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) throw Error();
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length > maxBytes || bytes.toString('base64url') !== value) throw Error();
  return bytes;
}

function tokenParts(token) {
  if (typeof token !== 'string' || token.length > 8192) throw Error();
  const parts = token.split('.');
  if (parts.length !== 3) throw Error();
  const utf8 = new TextDecoder('utf-8', {fatal: true});
  const header = JSON.parse(utf8.decode(decode(parts[0], 1024)));
  const claims = JSON.parse(utf8.decode(decode(parts[1], 4096)));
  if (!object(header) || !object(claims) || header.alg !== 'RS256' || !kidShape(header.kid) ||
      Object.keys(header).some(key => !['alg', 'kid', 'typ'].includes(key)) ||
      (header.typ !== undefined && header.typ !== 'JWT')) throw Error();
  return {header, claims, signature: decode(parts[2], 1024),
    signed: new TextEncoder().encode(parts.slice(0, 2).join('.'))};
}

function claimsValid(claims, projectId, now) {
  const time = Math.floor(now / 1000);
  return claims.aud === projectId && claims.iss === `https://securetoken.google.com/${projectId}` &&
    uidShape(claims.sub) && claims.email_verified === true && emailShape(claims.email) &&
    Number.isSafeInteger(claims.exp) && claims.exp > time && claims.exp <= 253402300799 &&
    Number.isSafeInteger(claims.iat) && claims.iat >= 0 && claims.iat <= time && claims.iat < claims.exp &&
    Number.isSafeInteger(claims.auth_time) && claims.auth_time >= 0 && claims.auth_time <= claims.iat &&
    (claims.nbf === undefined || (Number.isSafeInteger(claims.nbf) && claims.nbf >= 0 &&
      claims.nbf <= time && claims.nbf < claims.exp));
}

async function certificate(pem, time) {
  if (typeof pem !== 'string' || pem.length > 16384 ||
      !/^-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*$/.test(pem)) throw Error();
  const cert = new X509Certificate(pem);
  const from = Date.parse(cert.validFrom), until = Date.parse(cert.validTo);
  if (!Number.isFinite(from) || !Number.isFinite(until) || from > time || until <= time ||
      cert.publicKey.asymmetricKeyType !== 'rsa') throw Error();
  // Reuse the prototype SPKI -> WebCrypto algorithm binding, without exporting
  // or trusting a JWT-supplied JWK. Authenticity comes from the pinned HTTPS source.
  const key = await webcrypto.subtle.importKey('spki', cert.publicKey.export({format: 'der', type: 'spki'}),
    {name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256'}, false, ['verify']);
  if (key.algorithm.modulusLength < 2048 || key.algorithm.modulusLength > 8192) throw Error();
  return {key, from, until};
}

export function createFirebaseIdentity({projectId, http, getAccount, now = Date.now,
  timeoutMs = 5000} = {}) {
  requireTestProject(projectId);
  if (typeof http !== 'function' || http.projectId !== projectId ||
      typeof getAccount !== 'function' || getAccount.projectId !== projectId ||
      typeof now !== 'function' || !validBudget(timeoutMs)) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  let cache, pending, lastRefresh = -Infinity;
  async function refresh() {
    if (pending) return pending;
    const start = clock(now);
    if (start - lastRefresh < 30000) throw Error();
    lastRefresh = start;
    const flight = bounded(async () => {
      const r = await http(CERTIFICATE_URL, {method: 'GET'});
      const policy = r.headers.get('cache-control') ?? '';
      const ages = [...policy.matchAll(/(?:^|,)\s*max-age=(\d+)\s*(?=,|$)/gi)];
      const age = r.headers.get('age') ?? '0';
      if (r.status !== 200 || !object(r.data) || policy.length > 1024 || ages.length !== 1 ||
          !Number.isSafeInteger(Number(ages[0][1])) ||
          /(?:^|,)\s*(?:no-store|no-cache)(?:\s|,|$)/i.test(policy) || !/^\d{1,10}$/.test(age)) throw Error();
      const lifetime = Math.min(Number(ages[0][1]), 86400) - Number(age);
      if (!Number.isFinite(lifetime) || lifetime <= 0) throw Error();
      const entries = Object.entries(r.data);
      if (entries.length < 1 || entries.length > 10) throw Error();
      const keys = new Map();
      for (const [kid, pem] of entries) {
        if (!kidShape(kid)) throw Error();
        keys.set(kid, await certificate(pem, clock(now)));
      }
      const until = Math.min(start + lifetime * 1000, ...[...keys.values()].map(k => k.until));
      if (clock(now) < start || until <= clock(now)) throw Error();
      return {keys, from: start, until};
    }, timeoutMs, 'identity', 'unauthenticated');
    pending = flight;
    try { cache = await flight; } catch (error) { cache = undefined; throw error; }
    finally { if (pending === flight) pending = undefined; }
  }
  const verifyIdentity = async token => {
    let active = true;
    try {
      return await bounded(async () => {
        const {header, claims, signature, signed} = tokenParts(token);
        if (!claimsValid(claims, projectId, clock(now))) throw Error();
        const time = clock(now);
        if (!cache || time < cache.from || time >= cache.until || !cache.keys.has(header.kid)) await refresh();
        if (!active) throw Error();
        const verifiedCache = cache;
        const at = clock(now), entry = verifiedCache?.keys.get(header.kid);
        if (!entry || at < verifiedCache.from || at >= verifiedCache.until || at < entry.from || at >= entry.until ||
            !await webcrypto.subtle.verify('RSASSA-PKCS1-v1_5', entry.key, signature, signed)) throw Error();
        if (!active || !claimsValid(claims, projectId, clock(now))) throw Error();
        const user = await getAccount(claims.sub);
        // Recheck after every async security dependency; no stale positive account
        // cache. Auth revocation is still not atomic with a later Firestore commit.
        const validAfter = user?.tokensValidAfterTime;
        const completedAt = clock(now);
        if (!active || completedAt < at || completedAt >= verifiedCache.until || completedAt >= entry.until ||
            !claimsValid(claims, projectId, completedAt) ||
            !object(user) || user.uid !== claims.sub || user.disabled !== false || user.emailVerified !== true ||
            user.email !== claims.email || typeof validAfter !== 'string' ||
            !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(validAfter) ||
            !Number.isFinite(Date.parse(validAfter)) || new Date(validAfter).toISOString() !== validAfter ||
            claims.auth_time * 1000 < Date.parse(validAfter)) throw Error();
        return Object.freeze({uid: claims.sub, token: Object.freeze(claims)});
      }, timeoutMs, 'identity', 'unauthenticated');
    } catch { fail('identity'); }
    finally { active = false; }
  };
  return Object.freeze(Object.assign(verifyIdentity, {projectId}));
}
