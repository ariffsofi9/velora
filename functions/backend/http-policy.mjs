import {BackendError, requireBackendProject} from './backend-errors.mjs';

export function exactHttpsOrigin(value) {
  try {
    const url = new URL(value);
    return typeof value === 'string' && url.protocol === 'https:' && url.origin === value;
  } catch { return false; }
}
const reply = (status, error, unknown = false) => Response.json({error,
  ...(unknown ? {outcomeUnknown: true} : {})}, {status});

const routeHeaders = ['authorization', 'content-type'];
const localFrontendRoutes = new Set(['/workspace/create', '/staff/list', '/staff/remove',
  '/staff/create', '/staff/revoke', '/staff/redeem', '/staff/reconcile']);
const securityHeaders = new Set([...routeHeaders, 'host', 'origin',
  'access-control-request-method', 'access-control-request-headers']);

function isLocalFrontendOrigin(origin) {
  if (typeof origin !== 'string' || !/^http:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::[1-9][0-9]{0,4})?$/.test(origin)) return false;
  try {
    return new URL(origin).origin === origin;
  } catch { return false; }
}

// The local cap protects ingress. Worker composition supplies shared admission.
export function createHttpPolicy({projectId, publicOrigin, allowedOrigins, routes,
  handler, maxConcurrent = 8, admission, realWorker, enableLocalFrontend = false} = {}) {
  requireBackendProject(projectId, realWorker);
  if (!exactHttpsOrigin(publicOrigin) || !Array.isArray(allowedOrigins) || !allowedOrigins.length ||
      allowedOrigins.length > 20 || allowedOrigins.some(origin => !exactHttpsOrigin(origin)) ||
      new Set(allowedOrigins).size !== allowedOrigins.length || typeof handler !== 'function' ||
      !Array.isArray(routes) || !routes.length || routes.some(path => typeof path !== 'string' ||
        !/^\/[a-z]+(?:\/[a-z-]+)+$/.test(path)) || new Set(routes).size !== routes.length ||
      !Number.isInteger(maxConcurrent) || maxConcurrent < 1 || maxConcurrent > 100 ||
      typeof enableLocalFrontend !== 'boolean' || (enableLocalFrontend && !realWorker) ||
      (realWorker !== undefined && admission !== realWorker.admission) ||
      (admission !== undefined && (admission?.projectId !== projectId ||
        typeof admission.acquire !== 'function'))) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const origins = new Set(allowedOrigins), known = new Set(routes);
  let active = 0;
  function headers(response, origin, preflight = false, originAllowed = origins.has(origin)) {
    const result = new Headers(response.headers);
    for (const key of [...result.keys()]) if (key.startsWith('access-control-')) result.delete(key);
    result.set('cache-control', 'no-store');
    result.set('x-content-type-options', 'nosniff');
    const vary = (result.get('vary') ?? '').split(',').map(v => v.trim()).filter(Boolean);
    if (!vary.some(v => v.toLowerCase() === 'origin')) vary.push('Origin');
    if (preflight) {
      for (const field of ['Access-Control-Request-Method', 'Access-Control-Request-Headers']) {
        if (!vary.some(v => v.toLowerCase() === field.toLowerCase())) vary.push(field);
      }
    }
    result.set('vary', vary.join(', '));
    if (originAllowed) {
      result.set('access-control-allow-origin', origin);
      if (preflight) {
        result.set('access-control-allow-methods', 'POST');
        result.set('access-control-allow-headers', 'authorization, content-type');
      }
    }
    return new Response(response.body, {status: response.status, headers: result});
  }
  return async (request, deferCleanup) => {
    let origin = null, admitted = false, originAllowed = false;
    let permit, pending;
    try {
      origin = request.headers.get('origin');
      const url = new URL(request.url);
      originAllowed = origins.has(origin) ||
        (enableLocalFrontend && localFrontendRoutes.has(url.pathname) && isLocalFrontendOrigin(origin));
      if (url.origin !== publicOrigin || url.username || url.password || url.search || url.hash || !known.has(url.pathname)) {
        return headers(reply(404, 'not-found'), origin);
      }
      // Use the canonical Fetch URL. An explicit Host can only corroborate it.
      const host = request.headers.get('host')?.toLowerCase();
      const connection = request.headers.get('connection') ?? '';
      if ((host !== undefined && host !== url.host && !(url.port === '' && host === `${url.host}:443`)) ||
          connection.split(',').some(name => securityHeaders.has(name.trim().toLowerCase()))) {
        return headers(reply(400, 'invalid-argument'), origin);
      }
      if (origin !== null && !originAllowed) return headers(reply(403, 'permission-denied'), origin);
      if (request.method === 'OPTIONS') {
        const method = request.headers.get('access-control-request-method');
        const text = request.headers.get('access-control-request-headers') ?? '';
        const requested = text.split(',').map(header => header.trim().toLowerCase());
        if (origin === null || method !== 'POST' || text.length > 256 ||
            (text && requested.some(header => !routeHeaders.includes(header)))) {
          return headers(reply(403, 'permission-denied'), origin, false, originAllowed);
        }
        return headers(new Response(null, {status: 204}), origin, true, originAllowed);
      }
      if (request.method !== 'POST') return headers(reply(405, 'method-not-allowed'), origin, false, originAllowed);
      const {signal} = request;
      if (signal?.aborted) return headers(reply(408, 'deadline-exceeded'), origin, false, originAllowed);
      if (active >= maxConcurrent) return headers(reply(429, 'resource-exhausted'), origin, false, originAllowed);
      // Keep admission independent of all proxy/IP/identity header claims.
      const acceptedHeaders = new Headers();
      for (const name of routeHeaders) {
        const value = request.headers.get(name);
        if (value !== null) acceptedHeaders.set(name, value);
      }
      active++; admitted = true;
      if (admission) {
        let result;
        try { result = await admission.acquire(signal); }
        catch {
          return headers(signal?.aborted ? reply(408, 'deadline-exceeded') : reply(503, 'unavailable'), origin, false, originAllowed);
        }
        if (result !== null && (typeof result?.attribute !== 'function' || typeof result?.finish !== 'function')) {
          return headers(reply(503, 'unavailable'), origin, false, originAllowed);
        }
        permit = result;
        if (signal?.aborted) return headers(reply(408, 'deadline-exceeded'), origin, false, originAllowed);
        if (permit === null) return headers(reply(429, 'resource-exhausted'), origin, false, originAllowed);
        pending = new Set();
      }
      // Hand off the original stream and cancellation signal without cloning
      // or forwarding ingress-specific metadata (including Worker subrequests).
      const response = await handler({url: url.href, method: request.method, headers: acceptedHeaders,
        body: request.body, signal, ...(permit ? {admission: {
          attribute: uid => permit.attribute(uid, signal),
          track(work) {
            pending.add(work);
            const settled = () => pending.delete(work);
            void work.then(settled, settled);
            return work;
          },
        }} : {})});
      if (!(response instanceof Response)) throw Error();
      return headers(response, origin, false, originAllowed);
    } catch {
      // A handler failure could follow mutation dispatch. No raw exception or
      // new definite-failure envelope may erase that possibility.
      return headers(reply(503, 'unavailable', true), origin, false, originAllowed);
    } finally {
      if (permit) {
        const finish = async () => {
          try { await permit.finish(); }
          catch { /* An uncertain release leaves the durable slot counted. */ }
          finally { active--; }
        };
        // A nested deadline can return before protected work settles. Keep both
        // slots held without extending the request's deadline for that work.
        if (pending?.size) {
          const cleanup = (async () => {
            while (pending.size) await Promise.allSettled(pending);
            await finish();
          })();
          try { deferCleanup?.(cleanup); } catch { /* The durable slot stays held. */ }
        } else await finish();
      } else if (admitted) active--;
    }
  };
}
