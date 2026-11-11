import {BackendError, bounded, requireTestProject, validBudget} from './backend-errors.mjs';

export const CERTIFICATE_URL = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
export const OAUTH_URL = 'https://oauth2.googleapis.com/token';

export function firestoreCafeSegment(id) {
  if (typeof id !== 'string' || !id || id.length > 128 || id.trim() !== id ||
      ['.', '..'].includes(id) || /[\\/%\p{Cc}]/u.test(id)) {
    throw new BackendError('http', 'endpoint-denied');
  }
  try { return encodeURIComponent(id); } catch { throw new BackendError('http', 'endpoint-denied'); }
}
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function firestoreRows(data, rpc) {
  if (!Array.isArray(data) || data.length > 502) return false;
  return data.every(row => {
    const allowed = rpc === 'batchGet' ? ['found', 'missing', 'transaction', 'readTime'] :
      ['document', 'transaction', 'readTime', 'skippedResults', 'done'];
    if (!record(row) || !Object.keys(row).length || Object.keys(row).some(k => !allowed.includes(k))) return false;
    if (row.transaction !== undefined && (typeof row.transaction !== 'string' || !row.transaction || row.transaction.length > 8192)) return false;
    if (row.readTime !== undefined && (typeof row.readTime !== 'string' || row.readTime.length > 40)) return false;
    if (row.skippedResults !== undefined && (!Number.isSafeInteger(row.skippedResults) || row.skippedResults < 0)) return false;
    if (row.done !== undefined && typeof row.done !== 'boolean') return false;
    const doc = rpc === 'batchGet' ? row.found : row.document;
    if (doc !== undefined && (!record(doc) || typeof doc.name !== 'string' || !doc.name ||
        (doc.fields !== undefined && !record(doc.fields)))) return false;
    if (row.missing !== undefined && (typeof row.missing !== 'string' || !row.missing)) return false;
    if (doc !== undefined && row.missing !== undefined) return false;
    return doc !== undefined || row.missing !== undefined || row.readTime !== undefined || row.transaction !== undefined;
  });
}

// No fetch/default transport, credential discovery, listener or import-time I/O.
// The injected transport is trusted to enforce TLS and the redirect policy and
// must not implement automatic retries. Deadlines also bound noncooperative fakes.
export function createGoogleHttp({projectId, transport, timeoutMs = 5000,
  cleanupTimeoutMs = 100, maxBytes = 262144} = {}) {
  requireTestProject(projectId);
  if (typeof transport !== 'function' || !validBudget(timeoutMs) ||
      !validBudget(cleanupTimeoutMs) || !Number.isInteger(maxBytes) || maxBytes < 1 || maxBytes > 1048576) {
    throw new BackendError('configuration', 'invalid-configuration');
  }
  const accountUrl = `https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`;
  function destination(url, method, rpc) {
    const u = new URL(url);
    const base = `/v1/projects/${projectId}/databases/(default)/documents`;
    let firestore = false, actualRpc;
    if (u.origin === 'https://firestore.googleapis.com') {
      for (const operation of ['beginTransaction', 'batchGet', 'commit', 'rollback']) {
        if (u.pathname === `${base}:${operation}`) { firestore = true; actualRpc = operation; }
      }
      const prefix = `${base}/cafes/`;
      if (u.pathname.startsWith(prefix) && u.pathname.endsWith(':runQuery')) {
        const segment = u.pathname.slice(prefix.length, -':runQuery'.length);
        if (firestoreCafeSegment(decodeURIComponent(segment)) === segment) { firestore = true; actualRpc = 'runQuery'; }
      }
    }
    return url === u.href && !u.username && !u.password && !u.search && !u.hash &&
      (rpc === undefined || (['batchGet', 'runQuery'].includes(rpc) && actualRpc === rpc)) &&
      ((url === CERTIFICATE_URL && method === 'GET') ||
       ((url === OAUTH_URL || url === accountUrl || firestore) && method === 'POST'));
  }
  const http = async (url, options = {}) => {
    const {method = 'GET', body, headers, mutation = false, firestoreRpc} = options;
    try {
      if (typeof url !== 'string' || !destination(url, method, firestoreRpc) || typeof mutation !== 'boolean' ||
          (body !== undefined && (typeof body !== 'string' || Buffer.byteLength(body) > 1048576))) throw Error();
    } catch {
      throw new BackendError('http', 'endpoint-denied');
    }
    const controller = new AbortController();
    let reader, active = true, dispatched = false;
    const check = () => { if (!active) throw Error(); };
    try {
      return await bounded(async () => {
        check();
        dispatched = true;
        const response = await transport(url, {method, body, headers,
          redirect: 'error', signal: controller.signal});
        if (!active) {
          // Observe cancellation without waiting for an untrusted late stream.
          try { Promise.resolve(response.body?.cancel()).catch(() => {}); } catch { /* ignored */ }
          throw Error();
        }
        if (response.redirected || (response.url && response.url !== url) ||
            !Number.isInteger(response.status) || response.status < 200 || response.status > 599 ||
            (response.status >= 300 && response.status < 400)) throw Error();
        const contentType = response.headers.get('content-type') ?? '';
        if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(contentType)) throw Error();
        const length = response.headers.get('content-length');
        if (length !== null && (!/^\d+$/.test(length) || Number(length) > maxBytes)) throw Error();
        reader = response.body?.getReader();
        if (!reader) throw Error();
        const chunks = [];
        let size = 0;
        for (;;) {
          check();
          const {done, value} = await reader.read();
          check();
          if (done) break;
          if (!(value instanceof Uint8Array)) throw Error();
          size += value.byteLength;
          if (size > maxBytes) throw Error();
          chunks.push(value);
        }
        const data = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(Buffer.concat(chunks, size)));
        if (firestoreRpc && response.status === 200) {
          if (!firestoreRows(data, firestoreRpc)) throw Error();
        } else if (!record(data)) throw Error();
        check();
        // Copy headers so an injected response cannot mutate the cache policy.
        return {status: response.status, headers: new Headers(response.headers), data};
      }, timeoutMs, 'http');
    } catch {
      // A commit transport failure is always potentially applied, even if a
      // future store caller forgets to mark the RPC as a mutation.
      throw new BackendError('http', 'unavailable', dispatched && (mutation || url.endsWith('/documents:commit')));
    } finally {
      active = false;
      controller.abort();
      if (reader) {
        try { await bounded(() => reader.cancel(), cleanupTimeoutMs, 'http'); } catch { /* bounded cleanup */ }
      }
    }
  };
  return Object.freeze(Object.assign(http, {projectId}));
}
