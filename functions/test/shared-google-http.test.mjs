import test from 'node:test';
import assert from 'node:assert/strict';
import {createGoogleHttp, CERTIFICATE_URL, OAUTH_URL, firestoreCafeSegment} from '../backend/google-http.mjs';
import {BackendError} from '../backend/backend-errors.mjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const safe = unknown => error => error instanceof BackendError && error.kind === 'http' &&
  error.outcomeUnknown === unknown && !JSON.stringify(error).includes('SECRET');

test('inert factory requires explicit TEST project and transport', () => {
  let calls = 0;
  const transport = () => { calls++; };
  const http = createGoogleHttp({projectId, transport});
  assert.equal(http.projectId, projectId);
  assert.equal(calls, 0);
  for (const options of [{}, {projectId}, {projectId: 'velora-73222', transport},
    {projectId, transport, timeoutMs: 0}, {projectId, transport, maxBytes: 1048577}]) {
    assert.throws(() => createGoogleHttp(options), BackendError);
  }
});

test('valid JSON, fixed destinations, redirect policy and copied response headers', async () => {
  const calls = [];
  const http = createGoogleHttp({projectId, transport: async (url, options) => {
    calls.push({url, options});
    return Response.json({ok: true});
  }});
  for (const [url, method] of [[CERTIFICATE_URL, 'GET'], [OAUTH_URL, 'POST'],
    [`https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`, 'POST'],
    [`https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:commit`, 'POST']]) {
    assert.deepEqual((await http(url, {method})).data, {ok: true});
  }
  assert.equal(calls.length, 4);
  assert.ok(calls.every(({options}) => options.redirect === 'error' && options.signal.aborted));
});

for (const url of [
  'http://oauth2.googleapis.com/token', 'https://oauth2.googleapis.com/token?x=1',
  'https://oauth2.googleapis.com/token#x', 'https://user@oauth2.googleapis.com/token',
  'https://oauth2.googleapis.com.evil.test/token', 'https://oauth2.googleapis.com:443/token',
  'https://identitytoolkit.googleapis.com/v1/projects/velora-73222/accounts:lookup',
  'https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents:commit',
  'https://firestore.googleapis.com/v1/projects/velora-spark-test/databases/other/documents:commit',
  'https://firestore.googleapis.com/v1/projects/velora-spark-test/databases/(default)/documents/cafes/%2e%2e:runQuery',
  'https://firestore.googleapis.com/v1/projects/velora-spark-test/databases/(default)/documents/cafes/a%2Fb:runQuery',
  'https://offline.invalid', 'not a URL',
]) test(`destination denied before dispatch: ${url}`, async () => {
  let calls = 0;
  const http = createGoogleHttp({projectId, transport: () => { calls++; }});
  await assert.rejects(http(url, {method: 'POST', mutation: true}), safe(false));
  assert.equal(calls, 0);
});

for (const [name, response] of [
  ['redirect', () => new Response('{}', {status: 302})],
  ['wrong type', () => new Response('{}', {headers: {'content-type': 'text/html'}})],
  ['invalid JSON', () => new Response('{SECRET', {headers: {'content-type': 'application/json'}})],
  ['invalid UTF8', () => new Response(new Uint8Array([255]), {headers: {'content-type': 'application/json'}})],
  ['array', () => Response.json([])], ['null', () => Response.json(null)],
  ['oversize', () => Response.json({value: 'a'.repeat(200)})],
  ['advertised oversize', () => new Response('{}', {headers: {'content-type': 'application/json', 'content-length': '99999'}})],
  ['bad length', () => new Response('{}', {headers: {'content-type': 'application/json', 'content-length': 'no'}})],
  ['redirected response', () => ({redirected: true, status: 200})],
  ['wrong final URL', () => ({url: 'https://evil.invalid', status: 200})],
  ['missing body', () => ({status: 200, headers: new Headers({'content-type': 'application/json'})})],
  ['stream error', () => new Response(new ReadableStream({start(c) { c.error(Error('SECRET')); }}),
    {headers: {'content-type': 'application/json'}})],
]) test(`bounded sanitized response rejection: ${name}`, async () => {
  let calls = 0;
  const http = createGoogleHttp({projectId, maxBytes: 100, transport: async () => { calls++; return response(); }});
  await assert.rejects(http(OAUTH_URL, {method: 'POST', mutation: true}), safe(true));
  assert.equal(calls, 1);
});

test('valid service error response remains data, never inferred mutation noncommit', async () => {
  const http = createGoogleHttp({projectId, transport: async () => Response.json({error: {}}, {status: 503})});
  assert.equal((await http(OAUTH_URL, {method: 'POST'})).status, 503);
});

for (const phase of ['transport', 'body', 'cleanup']) {
  test(`${phase} stall is bounded, no automatic retry or late result`, async () => {
    let calls = 0, release, cancelled = false;
    const gate = new Promise(resolve => { release = resolve; });
    const http = createGoogleHttp({projectId, timeoutMs: 20, cleanupTimeoutMs: 10,
      transport: async () => {
        calls++;
        if (phase === 'transport') await gate;
        if (phase === 'cleanup') return {status: 200, headers: new Headers({'content-type': 'application/json'}),
          body: {getReader: () => ({read: async () => ({done: true}), cancel: () => gate})}};
        if (phase === 'body') return new Response(new ReadableStream({cancel() { cancelled = true; }}),
          {headers: {'content-type': 'application/json'}});
        return Response.json({ok: true});
      }});
    const start = Date.now();
    await assert.rejects(http(OAUTH_URL, {method: 'POST', mutation: true}), safe(true));
    assert.ok(Date.now() - start < 1000);
    release();
    await delay(5);
    assert.equal(calls, 1);
    if (phase === 'body') assert.equal(cancelled, true);
  });
}

test('dependency failure has no cause, body, token or original message', async () => {
  const http = createGoogleHttp({projectId, transport: async () => { throw Error('SECRET'); }});
  await assert.rejects(http(CERTIFICATE_URL), error => safe(false)(error) && error.cause === undefined);
});

test('lost commit is uncertain without caller hint and is never retried', async () => {
  let calls = 0;
  const http = createGoogleHttp({projectId, transport: async () => { calls++; throw Error('SECRET'); }});
  await assert.rejects(http(`https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:commit`,
    {method: 'POST'}), safe(true));
  assert.equal(calls, 1);
});

test('wrong method and oversized request fail before dispatch', async () => {
  let calls = 0;
  const http = createGoogleHttp({projectId, transport: async () => { calls++; }});
  for (const options of [{method: 'GET'}, {method: 'PUT'}, {method: 'POST', body: 'a'.repeat(1048577)}]) {
    await assert.rejects(http(OAUTH_URL, options), safe(false));
  }
  assert.equal(calls, 0);
});

const firestoreBase = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;
for (const [rpc, url, rows] of [
  ['batchGet', `${firestoreBase}:batchGet`, [{missing: 'projects/test/documents/cafes/cafe', readTime: '2026-11-11T00:00:00Z'}]],
  ['runQuery', `${firestoreBase}/cafes/cafe:runQuery`, [{document: {name: 'projects/test/documents/cafes/cafe/inventory/item', fields: {}}}]],
]) test(`${rpc} explicitly permits bounded Firestore rows only`, async () => {
  const http = createGoogleHttp({projectId, transport: async () => Response.json(rows)});
  assert.deepEqual((await http(url, {method: 'POST', firestoreRpc: rpc})).data, rows);
  await assert.rejects(http(url, {method: 'POST'}), safe(false));
  await assert.rejects(http(OAUTH_URL, {method: 'POST', firestoreRpc: rpc}), safe(false));
});

for (const rows of [[null], [[]], [{}], [{error: 'SECRET'}], [{found: {}, missing: 'x'}],
  [{missing: 1}], [{document: {name: 'x', fields: []}}], [{readTime: 12}],
  Array.from({length: 503}, () => ({readTime: '2026-11-11T00:00:00Z'}))]) {
  test(`rejects malformed/bounded Firestore rows ${JSON.stringify(rows).slice(0, 60)}`, async () => {
    const http = createGoogleHttp({projectId, transport: async () => Response.json(rows)});
    await assert.rejects(http(`${firestoreBase}/cafes/cafe:runQuery`, {method: 'POST', firestoreRpc: 'runQuery'}), safe(false));
  });
}

for (const id of ['cafe one', 'Kafe 咖啡', 'legacy.id', 'cafe?#']) {
  test(`encodes one canonical cafe segment without double encoding: ${id}`, async () => {
    const url = `${firestoreBase}/cafes/${firestoreCafeSegment(id)}:runQuery`;
    let calls = 0;
    const http = createGoogleHttp({projectId, transport: async actual => { calls++; assert.equal(actual, url); return Response.json([]); }});
    await http(url, {method: 'POST', firestoreRpc: 'runQuery'});
    assert.equal(calls, 1);
  });
}

for (const segment of ['..', '%2E%2E', '%252e%252e', 'a%2fb', 'a%5Cb', 'a%00b', 'a%C2%85b', '%', '%GG',
  'a/b', '%20cafe', 'cafe%20', 'cafe%2520one']) test(`denies unsafe cafe segment ${segment}`, async () => {
  let calls = 0;
  const http = createGoogleHttp({projectId, transport: async () => { calls++; }});
  await assert.rejects(http(`${firestoreBase}/cafes/${segment}:runQuery`, {method: 'POST', firestoreRpc: 'runQuery'}), safe(false));
  assert.equal(calls, 0);
});

test('RPC mismatch and Firestore oversize retain restrictions', async () => {
  const http = createGoogleHttp({projectId, maxBytes: 30, transport: async () => Response.json([{missing: 'x'.repeat(100)}])});
  await assert.rejects(http(`${firestoreBase}:batchGet`, {method: 'POST', firestoreRpc: 'runQuery'}), safe(false));
  await assert.rejects(http(`${firestoreBase}:batchGet`, {method: 'POST', firestoreRpc: 'batchGet'}), safe(false));
});
