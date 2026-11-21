import assert from 'node:assert/strict';
import {once} from 'node:events';
import {request} from 'node:http';
import {createConnection} from 'node:net';
import test from 'node:test';
import {createHttpPolicy} from '../backend/http-policy.mjs';
import {createNodeRuntime} from '../runtime/node-entry.mjs';

const projectId = 'velora-spark-test';
const canonicalOrigin = 'https://api.example.test';
const browserOrigin = 'https://client.example.test';
const path = '/staff/create';
const timeout = {timeout: 4000};

async function start(t, fetch, options = {}) {
  const runtime = createNodeRuntime({application: {projectId, fetch}, canonicalOrigin, ...options});
  assert.equal(runtime.server.listening, false);
  t.after(runtime.close);
  runtime.server.listen(0, '127.0.0.1');
  await once(runtime.server, 'listening');
  const port = runtime.server.address().port;
  function open({method = 'POST', target = path, headers = {}} = {}) {
    const req = request({host: '127.0.0.1', port, method, path: target, headers, agent: false});
    const response = new Promise((resolve, reject) => {
      req.once('error', reject);
      req.once('response', async res => {
        try {
          let body = '';
          for await (const chunk of res) body += chunk.toString();
          resolve({status: res.statusCode, headers: res.headers, body});
        } catch (error) { reject(error); }
      });
    });
    return {req, response};
  }
  function send(options = {}) {
    const {req, response} = open(options);
    req.end(options.body);
    return response;
  }
  function raw(data) {
    const socket = createConnection({host: '127.0.0.1', port});
    return new Promise((resolve, reject) => {
      let result = '';
      socket.setEncoding('utf8');
      socket.once('error', reject);
      socket.once('end', () => resolve(result));
      socket.once('connect', () => socket.write(data));
      t.after(() => socket.destroy());
      socket.on('data', chunk => { result += chunk; });
    });
  }
  return {...runtime, open, send, raw};
}

test('runtime is explicitly TEST-bound and requires an exact HTTPS origin', () => {
  const fetch = async () => Response.json({});
  for (const origin of ['http://api.example.test', canonicalOrigin + '/', undefined]) {
    assert.throws(() => createNodeRuntime({application: {projectId, fetch}, canonicalOrigin: origin}));
  }
  assert.throws(() => createNodeRuntime({application: {projectId: 'velora-73222', fetch}, canonicalOrigin}));
});

test('converts HTTP to Fetch and streams a Fetch response with safe headers', timeout, async t => {
  const runtime = await start(t, async req => {
    assert.equal(req.url, canonicalOrigin + path);
    assert.equal(req.method, 'POST');
    assert.equal(req.headers.get('authorization'), 'Bearer synthetic');
    assert.equal(req.headers.get('content-type'), 'application/json');
    for (const name of ['host', 'forwarded', 'x-forwarded-host', 'x-forwarded-proto', 'connection']) {
      assert.equal(req.headers.get(name), null);
    }
    assert.deepEqual(await req.json(), {value: 5});
    return new Response(new ReadableStream({
      start(controller) {
        const encoder = new TextEncoder();
        controller.enqueue(encoder.encode('first '));
        controller.enqueue(encoder.encode('second'));
        controller.close();
      },
    }), {status: 201, headers: {'content-type': 'text/plain', vary: 'Origin',
      'set-cookie': 'private=ignored', 'cache-control': 'public', location: 'https://elsewhere.test'}});
  });
  const r = await runtime.send({body: '{"value":5}', headers: {
    host: 'attacker.test', forwarded: 'host=attacker.test;proto=http',
    'x-forwarded-host': 'attacker.test', 'x-forwarded-proto': 'http',
    authorization: 'Bearer synthetic', 'content-type': 'application/json',
  }});
  assert.equal(r.status, 201);
  assert.equal(r.body, 'first second');
  assert.equal(r.headers['content-type'], 'text/plain');
  assert.equal(r.headers.vary, 'Origin');
  assert.equal(r.headers['cache-control'], 'no-store');
  assert.equal(r.headers['set-cookie'], undefined);
  assert.equal(r.headers.location, undefined);
});

test('forwards a request body chunk before the client finishes uploading', timeout, async t => {
  const firstChunk = Promise.withResolvers();
  const runtime = await start(t, async request => {
    const reader = request.body.getReader();
    const first = Buffer.from((await reader.read()).value).toString();
    firstChunk.resolve(first);
    let rest = '';
    for (;;) {
      const {value, done} = await reader.read();
      if (done) break;
      rest += Buffer.from(value).toString();
    }
    return Response.json({body: first + rest});
  });
  const {req, response} = runtime.open();
  req.write('first');
  assert.equal(await firstChunk.promise, 'first');
  req.end('second');
  assert.deepEqual(JSON.parse((await response).body), {body: 'firstsecond'});
});

test('uses the canonical origin and delegates browser origin enforcement', timeout, async t => {
  let dispatches = 0;
  const policy = createHttpPolicy({projectId, publicOrigin: canonicalOrigin, allowedOrigins: [browserOrigin],
    routes: [path], handler: async () => { dispatches++; return Response.json({ok: true}); }});
  const runtime = await start(t, policy);
  const wrong = await runtime.send({headers: {origin: 'https://wrong.test', host: 'wrong.test'}});
  assert.equal(wrong.status, 403);
  const preflight = await runtime.send({method: 'OPTIONS', headers: {origin: browserOrigin,
    'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization, content-type'}});
  assert.equal(preflight.status, 204);
  assert.equal(preflight.body, '');
  assert.equal(preflight.headers['access-control-allow-origin'], browserOrigin);
  assert.equal(dispatches, 0);
  assert.equal((await runtime.send({headers: {origin: browserOrigin, host: 'wrong.test'}})).status, 200);
  assert.equal(dispatches, 1);
});

test('rejects oversized headers and malformed or unsupported requests before dispatch', timeout, async t => {
  let calls = 0;
  const runtime = await start(t, async () => { calls++; return Response.json({}); }, {maxHeaderBytes: 256});
  assert.match(await runtime.raw('POST /staff/create HTTP/1.1\r\nHost: test\r\nX-Large: ' +
    'x'.repeat(400) + '\r\n\r\n'), /^HTTP\/1.1 431 /);
  for (const target of ['https://attacker.test/staff/create', '//attacker.test/staff/create',
    '/staff/../create', '/staff/%63reate', '/staff/create?x=1']) {
    assert.equal((await runtime.send({target})).status, 400, target);
  }
  assert.equal((await runtime.send({method: 'PUT'})).status, 405);
  assert.equal((await runtime.send({headers: {expect: '100-continue'}})).status, 417);
  assert.equal((await runtime.send({headers: {connection: 'authorization', authorization: 'Bearer test'}})).status, 400);
  assert.match(await runtime.raw('POST /staff/create HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer one\r\n' +
    'Authorization: Bearer two\r\nContent-Length: 0\r\n\r\n'), /^HTTP\/1.1 400 /);
  assert.equal(calls, 0);
});

test('bounds declared and chunked body sizes', timeout, async t => {
  let calls = 0;
  const runtime = await start(t, async req => {
    calls++;
    await req.text();
    return Response.json({ok: true});
  }, {maxBodyBytes: 8});
  const declared = await runtime.send({headers: {'content-length': 9}, body: '123456789'});
  assert.equal(declared.status, 413);
  assert.equal(calls, 0);
  const {req, response} = runtime.open();
  req.write('12345');
  req.end('6789');
  const chunked = await response;
  assert.equal(chunked.status, 413);
  assert.deepEqual(JSON.parse(chunked.body), {error: 'too-large', outcomeUnknown: true});
  assert.equal(calls, 1);
  assert.equal((await runtime.send({body: '12345678'})).status, 200);
});

test('client disconnect aborts the injected request', timeout, async t => {
  const entered = Promise.withResolvers(), aborted = Promise.withResolvers();
  const runtime = await start(t, async req => {
    entered.resolve();
    await once(req.signal, 'abort');
    aborted.resolve(req.signal.aborted);
    return Response.json({});
  });
  const {req, response} = runtime.open();
  req.end();
  await entered.promise;
  req.destroy();
  await assert.rejects(response);
  assert.equal(await aborted.promise, true);
});

test('timeout preserves uncertainty and keeps noncooperative work in the admission count', timeout, async t => {
  const release = Promise.withResolvers();
  let calls = 0, signal;
  const runtime = await start(t, async req => {
    calls++;
    signal = req.signal;
    await release.promise;
    return Response.json({});
  }, {maxConcurrent: 1, requestTimeoutMs: 120});
  try {
    const timedOut = await runtime.send();
    assert.equal(timedOut.status, 504);
    assert.deepEqual(JSON.parse(timedOut.body), {error: 'deadline-exceeded', outcomeUnknown: true});
    assert.equal(signal.aborted, true);
    assert.equal((await runtime.send()).status, 429);
    assert.equal(calls, 1);
  } finally { release.resolve(); }
});

test('admission frees after response completion and health never calls the app', timeout, async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  let calls = 0;
  const runtime = await start(t, async () => {
    calls++; entered.resolve(); await release.promise;
    return Response.json({ok: true});
  }, {maxConcurrent: 1});
  const first = runtime.send();
  try {
    await entered.promise;
    const health = await runtime.send({method: 'GET', target: '/healthz'});
    assert.equal(health.status, 200);
    assert.deepEqual(JSON.parse(health.body), {status: 'ok'});
    assert.equal((await runtime.send()).status, 429);
    assert.equal(calls, 1);
  } finally { release.resolve(); }
  assert.equal((await first).status, 200);
  assert.equal((await runtime.send()).status, 200);
});

test('connection cap rejects excess sockets before application dispatch', timeout, async t => {
  let calls = 0;
  const runtime = await start(t, async () => { calls++; return Response.json({}); }, {maxConnections: 1});
  const admitted = once(runtime.server, 'connection');
  const held = createConnection({host: '127.0.0.1', port: runtime.server.address().port});
  t.after(() => held.destroy());
  await admitted;
  const dropped = once(runtime.server, 'drop');
  const excess = assert.rejects(runtime.send());
  await Promise.all([dropped, excess]);
  assert.equal(calls, 0);
  held.destroy();
});

test('preserves application unknown outcomes and normalizes exceptions without retries', timeout, async t => {
  let calls = 0;
  const runtime = await start(t, async () => {
    if (++calls === 1) return Response.json({error: 'unavailable', outcomeUnknown: true}, {status: 503});
    throw new Error('private credential and invitation code');
  });
  for (let i = 1; i <= 2; i++) {
    const res = await runtime.send();
    assert.equal(res.status, 503);
    assert.deepEqual(JSON.parse(res.body), {error: 'unavailable', outcomeUnknown: true});
    assert.equal(calls, i);
  }
});

test('graceful shutdown drains a response and repeated shutdown shares its result', timeout, async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const runtime = await start(t, async () => {
    entered.resolve(); await release.promise; return Response.json({ok: true});
  });
  const response = runtime.send();
  await entered.promise;
  const closing = runtime.close();
  assert.equal(runtime.close(), closing);
  release.resolve();
  assert.equal((await response).status, 200);
  await closing;
  assert.equal(runtime.server.listening, false);
});

test('shutdown deadline aborts a stalled connection', timeout, async t => {
  const entered = Promise.withResolvers(), aborted = Promise.withResolvers();
  const runtime = await start(t, async req => {
    entered.resolve(); await once(req.signal, 'abort'); aborted.resolve();
    return Response.json({});
  }, {shutdownTimeoutMs: 75});
  const pending = runtime.send();
  const lost = assert.rejects(pending);
  await entered.promise;
  await runtime.close();
  await Promise.all([lost, aborted.promise]);
});
