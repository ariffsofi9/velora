import assert from 'node:assert/strict';
import {mkdtemp, rm} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {bundleWorkerFixture} from './helpers/worker-fixture-bundle.mjs';

const require = createRequire(new URL('../feasibility/shared-backend/runtime/package.json', import.meta.url));
const {Miniflare} = require('miniflare');
const project = 'velora-73222';

const driver = `
  export default {async fetch(request, env) {
    const {action, pair, grant, version = 1} = await request.json();
    const coordinator = env.ADMISSION.get(env.ADMISSION.idFromName('${project}'));
    try {
      if (action === 'seed') {
        const attempt = crypto.randomUUID();
        const token = await coordinator.reserve(attempt, Date.now() + 30000);
        if (!await coordinator.claim(attempt, token)) throw Error('Claim failed');
        const id = await coordinator.registerOAuth(attempt, token);
        return Response.json({attempt, token, id, grant: await env.ACK.start(1, id)});
      }
      if (action === 'status') return Response.json(await coordinator.statusOAuth(pair.id, pair.attempt, pair.token));
      if (action === 'finish') return Response.json(await coordinator.finish(pair.attempt, pair.token));
      if (action === 'register') return Response.json(await coordinator.registerOAuth(pair.attempt, pair.token));
      if (action === 'start') return Response.json(await env.ACK.start(version, pair.id));
      if (action === 'ack') return Response.json(await env.ACK.acknowledge(version, pair.id, grant));
      if (action === 'unsafe-method') return Response.json(await env.ACK.finish(pair.attempt, pair.token));
      return new Response(null, {status: 404});
    } catch { return new Response(null, {status: 503}); }
  }};
`;

test('containment restores private acknowledgement and holds unresolved permits', {timeout: 45000}, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'velora-rest-containment-'));
  let runtime;
  t.after(async () => {
    try { await runtime?.dispose(); }
    finally { await rm(directory, {recursive: true, force: true}); }
  });
  const [seed, containment] = await Promise.all([
    bundleWorkerFixture(`
      export {AdmissionCoordinator, OAuthAcknowledgement} from './runtime/admission-coordinator.mjs';
      export default {async fetch(request, env) {
        try { await env.SOURCE.acquire('${project}'); return new Response(null, {status: 204}); }
        catch { return new Response('fixture legacy acquisition failed', {status: 502}); }
      }};
    `),
    bundleWorkerFixture("export {default, AdmissionCoordinator, OAuthAcknowledgement} from './runtime/ingress-containment-entry.mjs';"),
  ]);
  assert.doesNotMatch(containment, /\/staff\/list|createApplication|identitytoolkit\.googleapis\.com/);
  const common = {modules: true, compatibilityDate: '2026-06-11',
    compatibilityFlags: ['nodejs_compat', 'enable_request_signal']};
  async function start(script, {reverse = true, enabled = false} = {}) {
    runtime = new Miniflare({host: '127.0.0.1', cf: false, durableObjectsPersist: directory, workers: [
      {...common, name: 'fixture-source', script: driver,
        durableObjects: {ADMISSION: {className: 'AdmissionCoordinator', scriptName: 'rest-api', useSQLite: true}},
        serviceBindings: reverse ? {ACK: {name: 'rest-api', entrypoint: 'OAuthAcknowledgement'}} : {},
        outboundService: () => new Response(null, {status: 403})},
      {...common, name: 'rest-api', script, bindings: {
        VELORA_ENVIRONMENT: 'real', VELORA_FIREBASE_PROJECT: project, VELORA_DURABLE_OAUTH: String(enabled),
      }, durableObjects: {ADMISSION: {className: 'AdmissionCoordinator', useSQLite: true}},
      outboundService: () => new Response(null, {status: 403})},
    ]});
    await runtime.ready;
  }
  const invoke = (action, args) => runtime.dispatchFetch('http://localhost', {
    method: 'POST', body: JSON.stringify({action, ...args}),
  });
  const read = async (action, args) => {
    const response = await invoke(action, args);
    assert.equal(response.status, 200);
    return response.json();
  };
  const ingress = async (path, method = 'POST') =>
    (await runtime.getWorker('rest-api')).fetch('https://offline.invalid' + path, {method});

  // Synthetic operations simulate work admitted before containment.
  await start(seed, {enabled: true});
  const late = await read('seed'), unresolved = await read('seed');
  assert.equal((await ingress('/staff/list')).status, 502);
  await runtime.dispose();

  await assert.rejects(start(seed + "\nthrow Error('synthetic REST startup defect');"),
    /synthetic REST startup defect/);
  await runtime.dispose().catch(error => {
    if (error.code !== 'ERR_RUNTIME_FAILURE') throw error;
  });

  await start(containment, {reverse: false, enabled: true});
  for (const [path, method] of [['/staff/list', 'POST'], ['/oauth/acknowledge', 'POST'], ['/staff/list', 'OPTIONS']]) {
    const response = await ingress(path, method);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), {error: 'unavailable'});
  }
  assert.equal((await invoke('ack', {pair: late, grant: late.grant})).status, 503);
  assert.equal(await read('status', {pair: late}), 'started');
  assert.equal(await read('finish', {pair: unresolved}), false);
  assert.equal((await invoke('register', {pair: unresolved})).status, 503);
  await runtime.dispose();

  await start(containment, {enabled: true});
  assert.equal((await invoke('start', {pair: unresolved})).status, 503);
  assert.equal((await invoke('unsafe-method', {pair: unresolved})).status, 503);
  assert.equal((await invoke('ack', {pair: late, grant: late.grant, version: 2})).status, 503);
  assert.equal((await invoke('ack', {pair: late, grant: unresolved.grant})).status, 503);
  assert.equal(await read('ack', {pair: late, grant: late.grant}), 'settled');
  assert.equal(await read('ack', {pair: late, grant: late.grant}), 'settled');
  await runtime.dispose();

  await start(containment);
  assert.equal(await read('status', {pair: late}), 'settled');
  assert.equal(await read('status', {pair: unresolved}), 'started');
  assert.equal(await read('finish', {pair: unresolved}), false);
  assert.equal((await ingress('/staff/list')).status, 503);
});
