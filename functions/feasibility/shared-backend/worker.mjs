// No deployed entrypoint, credentials, logging, global fetch or live defaults.
export function createWorker({verifyIdentity, backend}) {
  if (typeof verifyIdentity !== 'function' || typeof backend !== 'function') throw Error('Dependencies required');
  return {async fetch(request) {
    try {
      if (request.method !== 'POST') return Response.json({error: 'method-not-allowed'}, {status: 405});
      if (request.headers.get('content-type')?.split(';')[0] !== 'application/json') {
        return Response.json({error: 'invalid-argument'}, {status: 400});
      }
      const reader = request.body?.getReader();
      if (!reader) throw Error();
      let size = 0; const chunks = [];
      try {
        for (;;) {
          const {done, value} = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > 2048) return Response.json({error: 'too-large'}, {status: 413});
          chunks.push(value);
        }
      } finally { await reader.cancel(); }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      let data;
      try { data = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes)); }
      catch { return Response.json({error: 'invalid-argument'}, {status: 400}); }
      if (!data || Array.isArray(data) || typeof data !== 'object') return Response.json({error: 'invalid-argument'}, {status: 400});
      const bearer = request.headers.get('authorization');
      if (!bearer?.startsWith('Bearer ')) return Response.json({error: 'unauthenticated'}, {status: 401});
      let auth;
      try { auth = await verifyIdentity(bearer.slice(7)); }
      catch { return Response.json({error: 'unauthenticated'}, {status: 401}); }
      const result = await backend(new URL(request.url).pathname, auth, data);
      const body = JSON.stringify(result);
      if (new TextEncoder().encode(body).length > 65536) throw Error();
      return new Response(body, {headers: {'content-type': 'application/json', 'cache-control': 'no-store'}});
    } catch (error) {
      const statuses = {'permission-denied': 403, 'invalid-argument': 400, 'already-exists': 409,
        'failed-precondition': 409, 'resource-exhausted': 429, 'aborted': 409,
        'deadline-exceeded': 504, 'unauthenticated': 401, 'not-found': 404};
      const code = Object.hasOwn(statuses, error?.code) ? error.code : 'unavailable';
      return Response.json({error: code}, {status: statuses[code] ?? 503});
    }
  }};
}
