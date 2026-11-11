// Injected HTTP boundary only. No server, cloud SDK or network defaults.
export const DOMAIN_HTTP_STATUSES = Object.freeze({'unauthenticated': 401, 'permission-denied': 403,
  'invalid-argument': 400, 'already-exists': 409, 'failed-precondition': 409,
  'resource-exhausted': 429, 'not-found': 404});
const reply = (status, body) => Response.json(body, {status,
  headers: {'cache-control': 'no-store', 'x-content-type-options': 'nosniff'}});
class PreDomainFailure extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
const schedule = (callback, ms) => {
  const timer = setTimeout(callback, ms);
  return () => clearTimeout(timer);
};

// verifyIdentity MUST cryptographically verify signature, issuer, audience, time,
// verified email and current account/revocation status. It is a trusted dependency,
// not a decoded client claim. store MUST target the configured project.
export function createAuthenticatedJsonHttp({projectId, storeProjectId, verifyIdentity, routes, domainErrorTypes,
  domainStatuses = DOMAIN_HTTP_STATUSES, maxRequestBytes = 2048,
  domainReason = () => undefined,
  verificationTimeoutMs = 5000, bodyTimeoutMs = 5000, cleanupTimeoutMs = 100,
  scheduleTimeout = schedule}) {
  if (!['velora-spark-test', 'velora-73222'].includes(projectId) || storeProjectId !== projectId ||
      typeof verifyIdentity !== 'function' || !(routes instanceof Map) || !routes.size ||
      [...routes].some(([path, operation]) => typeof path !== 'string' || !path.startsWith('/') || typeof operation !== 'function') ||
      !Array.isArray(domainErrorTypes) || !domainErrorTypes.length ||
      domainErrorTypes.some(Type => typeof Type !== 'function' || !(Type.prototype instanceof Error)) ||
      !Number.isInteger(maxRequestBytes) || maxRequestBytes < 1 || maxRequestBytes > 65536 ||
      !domainStatuses || typeof domainStatuses !== 'object' ||
      Object.entries(domainStatuses).some(([code, status]) => !/^[a-z]+(?:-[a-z]+)*$/.test(code) ||
        !Number.isInteger(status) || status < 400 || status > 599) ||
      typeof scheduleTimeout !== 'function' || typeof domainReason !== 'function' ||
      ![verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs].every(ms =>
        Number.isInteger(ms) && ms > 0 && ms <= 30000)) throw Error('Explicit authenticated HTTP dependencies required');
  const allowedRoutes = new Map(routes);
  const statuses = Object.freeze({...domainStatuses});
  const errorTypes = [...domainErrorTypes];
  async function bounded(action, ms) {
    let cancel;
    try {
      return await Promise.race([
        new Promise((_, reject) => {
          cancel = scheduleTimeout(() => reject(new PreDomainFailure(408, 'deadline-exceeded')), ms);
        }),
        Promise.resolve().then(action),
      ]);
    } finally { cancel?.(); }
  }
  // Deadlines bound this handler's waiting, not arbitrary injected work. Late
  // verification/read completion cannot re-enter the domain dispatch below.
  // Hosting-level admission/concurrency limits are still required separately.
  return async request => {
    try {
      const url = new URL(request.url);
      const operation = allowedRoutes.get(url.pathname);
      if (!operation || url.search || url.hash) return reply(404, {error: 'not-found'});
      if (request.method !== 'POST') return reply(405, {error: 'method-not-allowed'});
      if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get('content-type') ?? '')) {
        return reply(400, {error: 'invalid-argument'});
      }
      const bearer = request.headers.get('authorization');
      if (!bearer || !/^Bearer [A-Za-z0-9_.-]{1,8192}$/.test(bearer)) return reply(401, {error: 'unauthenticated'});
      let auth;
      try {
        auth = await bounded(() => verifyIdentity(bearer.slice(7)), verificationTimeoutMs);
        if (!auth || typeof auth.uid !== 'string' || auth.uid !== auth.token?.sub ||
            auth.token.aud !== projectId || auth.token.iss !== `https://securetoken.google.com/${projectId}` ||
            auth.token.email_verified !== true) throw Error();
      } catch (error) {
        if (error instanceof PreDomainFailure) throw error;
        return reply(401, {error: 'unauthenticated'});
      }
      const reader = request.body?.getReader();
      if (!reader) return reply(400, {error: 'invalid-argument'});
      const chunks = []; let length = 0; let reading = true; let bodyFailure;
      try {
        await bounded(async () => {
          for (;;) {
            if (!reading) throw new PreDomainFailure(408, 'deadline-exceeded');
            const {value, done} = await reader.read();
            if (!reading) throw new PreDomainFailure(408, 'deadline-exceeded');
            if (done) break;
            length += value.byteLength;
            if (length > maxRequestBytes) throw new PreDomainFailure(413, 'too-large');
            chunks.push(value);
          }
        }, bodyTimeoutMs);
      } catch (error) { bodyFailure = error; }
      reading = false;
      try { await bounded(() => reader.cancel(), cleanupTimeoutMs); }
      catch (error) { bodyFailure ??= error; }
      if (bodyFailure) throw bodyFailure;
      let data;
      try {
        const bytes = new Uint8Array(length); let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        data = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
        if (!data || typeof data !== 'object' || Array.isArray(data)) throw Error();
      } catch { return reply(400, {error: 'invalid-argument'}); }
      // Domain owns strict field validation and all canonical authorization.
      const result = await operation({auth, data});
      return reply(200, result);
    } catch (error) {
      if (error instanceof PreDomainFailure) return reply(error.status, {error: error.code});
      // Store failures (even with a domain-looking code) cannot prove noncommit.
      if (!error?.uncertain && errorTypes.some(Type => error instanceof Type) && Object.hasOwn(statuses, error.code)) {
        // A trusted composition may select this single public reason. Never
        // serialize arbitrary messages, details, or callback return values.
        let reason;
        try { reason = domainReason(error); } catch { /* no public details */ }
        return reply(statuses[error.code], {error: error.code,
          ...(error.code === 'failed-precondition' && reason === 'insufficient-stock'
            ? {reason: 'insufficient-stock'} : {})});
      }
      return reply(503, {error: 'unavailable', outcomeUnknown: true});
    }
  };
}
