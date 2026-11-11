import {BackendError, requireTestProject} from './backend-errors.mjs';

export function exactHttpsOrigin(value) {
  try {
    const url = new URL(value);
    return typeof value === 'string' && url.protocol === 'https:' && url.origin === value;
  } catch { return false; }
}
const reply = (status, error, unknown = false) => Response.json({error,
  ...(unknown ? {outcomeUnknown: true} : {})}, {status});

// Process-local concurrent admission, with no queue or persistent quota claim.
// Hosting/distributed admission and TLS enforcement remain activation gates.
export function createHttpPolicy({projectId, publicOrigin, allowedOrigins, routes,
  handler, maxConcurrent = 8} = {}) {
  requireTestProject(projectId);
  if (!exactHttpsOrigin(publicOrigin) || !Array.isArray(allowedOrigins) || !allowedOrigins.length ||
      allowedOrigins.length > 20 || allowedOrigins.some(origin => !exactHttpsOrigin(origin)) ||
      new Set(allowedOrigins).size !== allowedOrigins.length || typeof handler !== 'function' ||
      !Array.isArray(routes) || !routes.length || routes.some(path => typeof path !== 'string' ||
        !/^\/[a-z]+(?:\/[a-z-]+)+$/.test(path)) || new Set(routes).size !== routes.length ||
      !Number.isInteger(maxConcurrent) || maxConcurrent < 1 || maxConcurrent > 100) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const origins = new Set(allowedOrigins), known = new Set(routes);
  let active = 0;
  function headers(response, origin, preflight = false) {
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
    if (origins.has(origin)) {
      result.set('access-control-allow-origin', origin);
      if (preflight) {
        result.set('access-control-allow-methods', 'POST');
        result.set('access-control-allow-headers', 'authorization, content-type');
      }
    }
    return new Response(response.body, {status: response.status, headers: result});
  }
  return async request => {
    let origin = null, admitted = false;
    try {
      origin = request.headers.get('origin');
      const url = new URL(request.url);
      if (url.origin !== publicOrigin || url.username || url.password || url.search || url.hash || !known.has(url.pathname)) {
        return headers(reply(404, 'not-found'), origin);
      }
      if (origin !== null && !origins.has(origin)) return headers(reply(403, 'permission-denied'), origin);
      if (request.method === 'OPTIONS') {
        const method = request.headers.get('access-control-request-method');
        const text = request.headers.get('access-control-request-headers') ?? '';
        const requested = text.split(',').map(header => header.trim().toLowerCase());
        if (origin === null || method !== 'POST' || text.length > 256 ||
            (text && requested.some(header => !['authorization', 'content-type'].includes(header)))) {
          return headers(reply(403, 'permission-denied'), origin);
        }
        return headers(new Response(null, {status: 204}), origin, true);
      }
      if (request.method !== 'POST') return headers(reply(405, 'method-not-allowed'), origin);
      if (active >= maxConcurrent) return headers(reply(429, 'resource-exhausted'), origin);
      active++; admitted = true;
      const response = await handler(request);
      if (!(response instanceof Response)) throw Error();
      return headers(response, origin);
    } catch {
      // A handler failure could follow mutation dispatch. No raw exception or
      // new definite-failure envelope may erase that possibility.
      return headers(reply(503, 'unavailable', true), origin);
    } finally { if (admitted) active--; }
  };
}
