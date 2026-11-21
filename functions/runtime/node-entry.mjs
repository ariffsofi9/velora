import {createServer} from 'node:http';
import {Readable, Transform} from 'node:stream';
import {finished, pipeline} from 'node:stream/promises';
import {requireTestProject} from '../backend/backend-errors.mjs';
import {exactHttpsOrigin} from '../backend/http-policy.mjs';

const requestHeaders = ['authorization', 'content-type', 'origin',
  'access-control-request-method', 'access-control-request-headers'];
const responseHeaders = ['content-type', 'vary', 'retry-after', 'allow',
  'access-control-allow-origin', 'access-control-allow-methods', 'access-control-allow-headers'];

function reply(res, status, body, close = false) {
  if (res.destroyed || res.writableEnded) return;
  if (res.headersSent) {
    res.destroy();
    return;
  }
  res.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...(close ? {connection: 'close'} : {}),
  });
  res.end(JSON.stringify(body));
}

function closeSocket(socket, status) {
  if (socket.writable) {
    socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  } else socket.destroy();
}

/**
 * Creates an unbound HTTP server behind a future trusted TLS terminator.
 * The caller owns listen() and process lifecycle. No cloud configuration is discovered here.
 */
export function createNodeRuntime({
  application, canonicalOrigin, maxConnections = 32, maxConcurrent = 8,
  maxHeaderBytes = 16384, maxBodyBytes = 65536, requestTimeoutMs = 35000,
  shutdownTimeoutMs = 5000,
} = {}) {
  requireTestProject(application?.projectId);
  if (!exactHttpsOrigin(canonicalOrigin) || typeof application.fetch !== 'function' ||
      ![[maxConnections, 1024], [maxConcurrent, 100], [maxHeaderBytes, 65536],
        [maxBodyBytes, 65536], [requestTimeoutMs, 120000], [shutdownTimeoutMs, 120000]]
        .every(([value, max]) => Number.isInteger(value) && value >= 1 && value <= max)) {
    throw new TypeError('Invalid Node runtime configuration.');
  }
  const fetch = application.fetch.bind(application);
  const sockets = new Set();
  const usedSockets = new WeakSet();
  let active = 0;
  let shutdown;
  const server = createServer({
    maxHeaderSize: maxHeaderBytes,
    headersTimeout: Math.min(requestTimeoutMs, 10000),
    requestTimeout: requestTimeoutMs,
    connectionsCheckingInterval: Math.min(requestTimeoutMs, 1000),
    keepAliveTimeout: 5000,
  }, (req, res) => {
    usedSockets.add(req.socket);
    if (shutdown) return reply(res, 503, {error: 'unavailable'}, true);
    // No query, absolute-form URI, dot-segment, escapes or normalization.
    if (!/^\/(?:[a-z]+(?:\/[a-z-]+)*)?$/.test(req.url)) {
      return reply(res, 400, {error: 'invalid-argument'}, true);
    }
    const health = req.url === '/healthz';
    if (health ? req.method !== 'GET' : !['POST', 'OPTIONS'].includes(req.method)) {
      return reply(res, 405, {error: 'method-not-allowed'}, true);
    }
    if (Number(req.headers['content-length']) > maxBodyBytes) {
      return reply(res, 413, {error: 'too-large'}, true);
    }
    if (req.method !== 'POST' &&
        (req.headers['transfer-encoding'] || Number(req.headers['content-length']) > 0)) {
      return reply(res, 400, {error: 'invalid-argument'}, true);
    }
    if (health) return reply(res, 200, {status: 'ok'});
    if (active >= maxConcurrent) return reply(res, 429, {error: 'resource-exhausted'}, true);
    active++;
    void dispatch(req, res);
  });
  server.maxConnections = maxConnections;
  // The byte ceiling bounds the header count without silently dropping fields.
  server.maxHeadersCount = 0;
  server.on('connection', socket => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  server.on('clientError', (error, socket) => {
    // A parser failure on a pipelined connection must not inject a response
    // into a request that already owns the socket.
    if (usedSockets.has(socket) || error.code === 'ECONNRESET') {
      socket.destroy();
      return;
    }
    closeSocket(socket, error.code === 'HPE_HEADER_OVERFLOW'
      ? '431 Request Header Fields Too Large'
      : error.code === 'ERR_HTTP_REQUEST_TIMEOUT' ? '408 Request Timeout' : '400 Bad Request');
  });
  for (const event of ['checkContinue', 'checkExpectation']) {
    server.on(event, (_req, res) => reply(res, 417, {error: 'expectation-failed'}, true));
  }
  server.on('upgrade', (_req, socket) => socket.destroy());

  async function dispatch(req, res) {
    const controller = new AbortController();
    const {signal} = controller;
    const disconnect = () => {
      if (!res.writableFinished) controller.abort({status: 503, error: 'unavailable'});
    };
    req.once('error', disconnect);
    req.once('aborted', disconnect);
    res.once('close', disconnect);
    const timeout = setTimeout(
      () => controller.abort({status: 504, error: 'deadline-exceeded'}), requestTimeoutMs,
    );
    let body, operation;
    try {
      const headers = new Headers();
      const hopHeaders = String(req.headers.connection ?? '').toLowerCase().split(',').map(value => value.trim());
      for (const name of requestHeaders) {
        const values = req.headersDistinct[name];
        if (values?.length > 1 || (values && hopHeaders.includes(name))) {
          return reply(res, 400, {error: 'invalid-argument'}, true);
        }
        if (values) headers.set(name, values[0]);
      }
      if (req.method === 'POST') {
        let bytes = 0;
        body = new Transform({
          transform(chunk, _encoding, callback) {
            bytes += chunk.byteLength;
            if (bytes > maxBodyBytes) {
              controller.abort({status: 413, error: 'too-large'});
              callback(new Error('Request body limit exceeded.'));
              return;
            }
            callback(null, chunk);
          },
        });
        // The Web stream receives this error too. Keep the Node stream safe
        // even when the application never takes ownership of its body.
        body.on('error', () => {});
      }
      const request = new Request(canonicalOrigin + req.url, {
        method: req.method, headers, signal,
        ...(body ? {body: Readable.toWeb(body, {
          strategy: {highWaterMark: 16384, size: chunk => chunk.byteLength},
        }), duplex: 'half'} : {}),
      });
      const cancelled = new Promise(resolve => {
        signal.addEventListener('abort', () => resolve(null), {once: true});
      });
      operation = Promise.resolve().then(() => signal.aborted ? null : fetch(request)).then(response => {
        if (signal.aborted && response instanceof Response) {
          void response.body?.cancel().catch(() => {});
        }
        return response;
      });
      if (body) req.pipe(body);
      const response = await Promise.race([operation, cancelled]);
      if (signal.aborted) {
        const {status, error} = signal.reason;
        return reply(res, status, {error, ...(req.method === 'POST' ? {outcomeUnknown: true} : {})}, true);
      }
      if (!(response instanceof Response)) throw new Error('Invalid application response.');
      for (const name of responseHeaders) {
        const value = response.headers.get(name);
        if (value !== null) res.setHeader(name, value);
      }
      res.setHeader('cache-control', 'no-store');
      res.setHeader('x-content-type-options', 'nosniff');
      if (!req.complete) res.setHeader('connection', 'close');
      res.statusCode = response.status;
      if (response.body) await pipeline(Readable.fromWeb(response.body), res, {signal});
      else {
        res.end();
        await finished(res, {signal, cleanup: true});
      }
    } catch {
      reply(res, 503, {error: 'unavailable',
        ...(operation && req.method === 'POST' ? {outcomeUnknown: true} : {})}, true);
    } finally {
      clearTimeout(timeout);
      if (body) {
        req.unpipe(body);
        body.destroy();
      }
      // Timeouts cannot free an admission slot while injected work is still running.
      // The detached wait never delays the client response or server shutdown.
      await operation?.catch(() => {});
      active--;
    }
  }

  function close() {
    shutdown ??= new Promise((resolve, reject) => {
      const deadline = setTimeout(() => {
        for (const socket of sockets) socket.destroy();
      }, shutdownTimeoutMs);
      server.close(error => {
        clearTimeout(deadline);
        if (error && error.code !== 'ERR_SERVER_NOT_RUNNING') reject(error);
        else resolve();
      });
    });
    return shutdown;
  }
  return Object.freeze({server, close});
}
