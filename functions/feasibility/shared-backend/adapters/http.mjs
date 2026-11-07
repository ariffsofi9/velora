// No network default. Only approved test-project REST destinations.
export function failure(code = 'unavailable', uncertain = false) {
  return Object.assign(new Error(code), {code, uncertain});
}
export function createHttp({transport, timeoutMs = 5000, maxBytes = 262144}) {
  if (typeof transport !== 'function' || !Number.isInteger(timeoutMs) || timeoutMs < 1 ||
      timeoutMs > 15000 || !Number.isInteger(maxBytes) || maxBytes < 1 || maxBytes > 1048576) throw failure('configuration');
  return async (url, options = {}) => {
    const u = new URL(url);
    const allowed = u.href === 'https://oauth2.googleapis.com/token' ||
      u.href === 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com' ||
      u.href === 'https://identitytoolkit.googleapis.com/v1/projects/velora-spark-test/accounts:lookup' ||
      (u.origin === 'https://firestore.googleapis.com' && /^\/v1\/projects\/velora-spark-test\/databases\/\(default\)\/documents(?::(?:beginTransaction|batchGet|commit|rollback)$|\/cafes\/[^/]+:runQuery$)/.test(u.pathname));
    if (!allowed || u.username || u.password || u.hash || u.search) throw failure('endpoint-denied');
    const controller = new AbortController(); let timer; let reader;
    try {
      return await Promise.race([
        new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reader?.cancel().catch(() => {}); reject(failure()); }, timeoutMs); }),
        (async () => {
          const response = await transport(u.href, {...options, redirect: 'error', signal: controller.signal});
          reader = response.body?.getReader(); if (!reader) throw failure();
          const chunks = []; let size = 0;
          for (;;) { const {done, value} = await reader.read(); if (done) break;
            size += value.byteLength; if (size > maxBytes) throw failure('response-limit'); chunks.push(value); }
          const bytes = new Uint8Array(size); let offset = 0;
          for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
          let data; try { data = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes)); } catch { throw failure(); }
          return {status: response.status, headers: response.headers, data};
        })(),
      ]);
    } catch (error) { throw failure(['response-limit'].includes(error?.code) ? error.code : 'unavailable'); }
    finally { clearTimeout(timer); controller.abort(); reader?.cancel().catch(() => {}); }
  };
}
