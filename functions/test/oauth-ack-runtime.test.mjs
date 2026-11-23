import assert from 'node:assert/strict';
import {generateKeyPairSync, randomUUID} from 'node:crypto';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {bundleWorkerFixture} from './helpers/worker-fixture-bundle.mjs';

const require = createRequire(new URL('../feasibility/shared-backend/runtime/package.json', import.meta.url));
const {Miniflare} = require('miniflare');
const {unstable_readConfig: readConfig} = require('wrangler');
const project = 'velora-73222';
const endpoint = 'https://oauth2.googleapis.com/token';
const reverseBinding = {binding: 'OAUTH_ACK', service: 'rest-api', entrypoint: 'OAuthAcknowledgement'};

test('Wrangler accepts the proposed reverse binding in a temporary config', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'velora-oauth-config-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  const rest = readConfig({config: fileURLToPath(new URL('../runtime/wrangler.jsonc', import.meta.url)), env: 'real'});
  const sourcePath = new URL('../runtime/google-token-source.wrangler.jsonc', import.meta.url);
  const source = JSON.parse(await readFile(sourcePath, 'utf8'));
  const config = join(directory, 'wrangler.json');
  await writeFile(config, JSON.stringify({...source, services: [reverseBinding]}));
  const proposal = readConfig({config});
  assert.equal(proposal.name, 'velora-google-token-source-real');
  assert.equal(proposal.workers_dev, false);
  assert.equal(proposal.preview_urls, false);
  assert.deepEqual(proposal.services, [reverseBinding]);
  assert.equal(rest.name, reverseBinding.service);
  assert.deepEqual(rest.services, [{binding: 'VELORA_GOOGLE_TOKEN_SOURCE', service: source.name,
    entrypoint: 'GoogleTokenSource'}]);
});

const restSource = `
  import {AdmissionCoordinator} from './runtime/worker-entry.mjs';
  export {OAuthAcknowledgement} from './runtime/worker-entry.mjs';

  export class FixtureCoordinator extends AdmissionCoordinator {
    #storage;
    constructor(ctx, env) {
      super(ctx, env);
      this.#storage = ctx.storage;
    }
    openFixture() {
      const attempt = crypto.randomUUID();
      const token = this.reserve(attempt, Date.now() + 30000);
      if (!this.claim(attempt, token)) throw Error('Fixture claim failed');
      const id = this.registerOAuth(attempt, token);
      this.#storage.kv.put('fixture-attempt:' + id, attempt);
      return id;
    }
    #pair(id) {
      const attempt = this.#storage.kv.get('fixture-attempt:' + id);
      const {token} = this.#storage.sql.exec('SELECT token FROM permits WHERE attempt = ?', attempt).one();
      return [attempt, token];
    }
    statusFixture(id) { return this.statusOAuth(id, ...this.#pair(id)); }
    finishFixture(id) { return this.finish(...this.#pair(id)); }
  }
  export default {async fetch(request, env, ctx) {
    // Loopback test driver only. The acknowledgement has no HTTP handler.
    const path = new URL(request.url).pathname;
    if (request.method !== 'POST' || request.headers.get('x-fixture-control') !== env.FIXTURE_CONTROL) {
      return new Response(null, {status: 404});
    }
    if (path === '/__fixture/control') {
      const {action, id, generation, draining} = await request.json();
      const ledger = env.ADMISSION.get(env.ADMISSION.idFromName(env.VELORA_FIREBASE_PROJECT));
      if (action === 'open') return Response.json(await ledger.openFixture());
      if (action === 'status') return Response.json(await ledger.statusFixture(id));
      if (action === 'finish') return Response.json(await ledger.finishFixture(id));
      if (action === 'drain') return Response.json(await ledger.updateAdmissionDrain(generation, draining));
      if (action === 'drain-status') return Response.json(await ledger.admissionDrainStatus());
    }
    if (path !== '/__fixture/run') return new Response(null, {status: 404});
    const {id, fault, timeout} = await request.json();
    const source = env.VELORA_GOOGLE_TOKEN_SOURCE;
    const remote = Promise.resolve().then(() =>
      fault === 'legacy' ? source.acquire(env.VELORA_FIREBASE_PROJECT) : source.run(id, fault))
      .then(() => new Response(null, {status: 204}), () => new Response(null, {status: 503}));
    if (!timeout) return remote;
    ctx.waitUntil(remote);
    let timer;
    try {
      return await Promise.race([remote,
        new Promise(resolve => { timer = setTimeout(() => resolve(new Response(null, {status: 408})), 100); })]);
    } finally { clearTimeout(timer); }
  }};
`;

const tokenSource = `
  import {GoogleTokenSource, acquireGoogleToken} from './runtime/google-token-source.mjs';

  export class FixtureGoogleTokenSource extends GoogleTokenSource {
    async run(id, fault) {
      const ack = this.env.OAUTH_ACK;
      if (!fault) return this.acquireTracked('${project}', 1, id);
      if (fault === 'version-mismatch') return this.acquireTracked('${project}', 2, id);
      if (fault === 'authority') {
        for (const name of ['finish', 'updateAdmissionDrain', 'status']) {
          let rejected = false;
          try { await ack[name](id); } catch { rejected = true; }
          if (!rejected) throw Error('Unexpected authority');
        }
        return;
      }
      const grant = await ack.start(1, id);
      if (fault === 'lost-grant') throw Error('Fixture drops grant after commit');
      let work;
      try { await acquireGoogleToken(this.env, '${project}', completion => { work = completion; }); }
      finally {
        if (work === undefined || await work) {
          if (fault === 'interrupted-before-ack') throw Error('Fixture stops before acknowledgement');
          await ack.acknowledge(1, id, fault === 'wrong-capability' ? crypto.randomUUID() : grant);
          await ack.acknowledge(1, id, grant);
          if (fault === 'lost-receipt') throw Error('Fixture drops reply after commit');
        }
      }
    }
  }
  export default {fetch() { return new Response(null, {status: 404}); }};
`;

test('private acknowledgement across local Workers and SQLite coordinator RPC', {timeout: 45000}, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'velora-oauth-ack-'));
  let runtime, activeExchange, exchangeEntered, requests = 0;
  t.after(async () => {
    activeExchange?.resolve();
    try { await runtime?.dispose(); }
    finally { await rm(directory, {recursive: true, force: true}); }
  });
  const [rest, source, legacySource] = await Promise.all([
    bundleWorkerFixture(restSource), bundleWorkerFixture(tokenSource),
    bundleWorkerFixture(`
      import {WorkerEntrypoint} from 'cloudflare:workers';
      import {acquireGoogleToken} from './runtime/google-token-source.mjs';
      export class LegacySource extends WorkerEntrypoint {
        acquire(project) { return acquireGoogleToken(this.env, project); }
      }
      export default {};
    `),
  ]);
  const controlKey = randomUUID();
  const key = generateKeyPairSync('rsa', {modulusLength: 2048}).privateKey.export({type: 'pkcs8', format: 'pem'});
  const common = {modules: true, compatibilityDate: '2026-06-11',
    compatibilityFlags: ['nodejs_compat', 'enable_request_signal']};
  async function startRuntime({reverse = true, enabled = true, legacy = false,
    acknowledgement = reverseBinding.entrypoint} = {}) {
    runtime = new Miniflare({host: '127.0.0.1', cf: false, durableObjectsPersist: directory, workers: [
      {...common, name: 'rest-api', script: rest,
        bindings: {VELORA_ENVIRONMENT: 'real', VELORA_FIREBASE_PROJECT: project,
          ADMISSION_PRE_AUTH_LIMIT: '8', FIXTURE_CONTROL: controlKey, VELORA_DURABLE_OAUTH: String(enabled)},
        durableObjects: {ADMISSION: {className: 'FixtureCoordinator', useSQLite: true}},
        serviceBindings: {VELORA_GOOGLE_TOKEN_SOURCE: {name: 'velora-google-token-source-real',
          entrypoint: legacy ? 'LegacySource' : 'FixtureGoogleTokenSource'}},
        outboundService: () => new Response(null, {status: 403})},
      {...common, name: 'velora-google-token-source-real', script: legacy ? legacySource : source,
        bindings: {VELORA_GOOGLE_SERVICE_ACCOUNT_KEY: JSON.stringify({
          type: 'service_account', project_id: project,
          client_email: 'offline@velora-73222.iam.gserviceaccount.com', private_key: key,
        })},
        serviceBindings: reverse ? {[reverseBinding.binding]: {name: reverseBinding.service,
          entrypoint: acknowledgement}} : {},
        async outboundService(request) {
          assert.equal(request.url, endpoint);
          assert.equal(request.method, 'POST');
          requests++;
          exchangeEntered?.resolve();
          await activeExchange?.promise;
          return Response.json({access_token: 'offline-oauth-token', token_type: 'Bearer', expires_in: 300});
        }},
    ]});
    await runtime.ready;
  }
  await startRuntime();
  const call = (path, body, signal) => runtime.dispatchFetch('http://localhost/__fixture/' + path, {
    method: 'POST', headers: {'x-fixture-control': controlKey}, body: JSON.stringify(body), signal,
  });
  async function control(action, args) {
    const response = await call('control', {action, ...args});
    assert.equal(response.status, 200, response.status === 200 ? undefined : await response.text());
    return response.json();
  }
  const operation = () => control('open');
  const status = id => control('status', {id});
  const run = (id, fault, timeout = false) => call('run', {id, fault, timeout});

  const lostGrant = await operation();
  assert.equal((await run(lostGrant, 'lost-grant')).status, 503);
  assert.equal(await status(lostGrant), 'started');
  assert.equal((await run(lostGrant)).status, 503);
  assert.equal(await control('finish', {id: lostGrant}), false);
  assert.equal(requests, 0);

  const late = await operation();
  activeExchange = Promise.withResolvers();
  exchangeEntered = Promise.withResolvers();
  assert.equal((await run(late, undefined, true)).status, 408);
  await exchangeEntered.promise;
  assert.equal(await status(late), 'started');
  assert.equal(await control('finish', {id: late}), false);
  const blocked = await operation();
  await control('drain', {generation: 0, draining: true});
  assert.equal((await run(blocked)).status, 503);
  assert.equal(await status(blocked), 'registered');
  activeExchange.resolve();
  for (let i = 0; i < 100 && await status(late) !== 'settled'; i++) await delay(15);
  assert.equal(await status(late), 'settled');
  assert.equal(await control('finish', {id: late}), true);
  assert.equal(requests, 1);
  assert.equal((await run(late, 'authority')).status, 204);
  assert.deepEqual(await control('drain-status'), {generation: 1, draining: true});
  await control('drain', {generation: 1, draining: false});

  const lostReceipt = await operation();
  assert.equal((await run(lostReceipt, 'lost-receipt')).status, 503);
  assert.equal(await status(lostReceipt), 'settled');
  assert.equal(await control('finish', {id: lostReceipt}), true);
  const wrong = await operation();
  assert.equal((await run(wrong, 'wrong-capability')).status, 503);
  assert.equal(await status(wrong), 'started');
  const interrupted = await operation();
  assert.equal((await run(interrupted, 'interrupted-before-ack')).status, 503);
  assert.equal(await status(interrupted), 'started');
  assert.equal(await control('finish', {id: interrupted}), false);
  for (const path of ['/oauth/start', '/oauth/acknowledge']) {
    assert.equal((await runtime.dispatchFetch('http://localhost' + path, {
      method: 'POST', headers: {'x-fixture-control': controlKey},
    })).status, 404);
    const sourceWorker = await runtime.getWorker('velora-google-token-source-real');
    assert.equal((await sourceWorker.fetch('http://localhost' + path, {method: 'POST'})).status, 404);
  }
  await runtime.dispose();
  await startRuntime();
  assert.equal(await status(lostReceipt), 'settled');
  assert.equal(await status(interrupted), 'started');
  assert.equal((await run(interrupted)).status, 503);
  assert.equal(requests, 1);

  const sealed = await operation();
  assert.equal((await run(sealed, 'version-mismatch')).status, 503);
  assert.equal(await status(sealed), 'registered');
  assert.equal(await control('finish', {id: sealed}), true);
  assert.equal(await status(sealed), 'sealed-before-start');
  assert.equal(await control('finish', {id: sealed}), true);
  assert.equal((await run(sealed)).status, 503);

  const cancelled = await operation();
  activeExchange = Promise.withResolvers();
  exchangeEntered = Promise.withResolvers();
  const abort = new AbortController();
  const outcome = call('run', {id: cancelled}, abort.signal).then(() => 'response', error => error.name);
  await exchangeEntered.promise;
  abort.abort();
  assert.equal(await outcome, 'AbortError');
  assert.equal(await status(cancelled), 'started');
  activeExchange.resolve();
  // Client abort proves only that the local client stopped waiting.
  assert.equal(requests, 2);

  await runtime.dispose();
  await startRuntime({reverse: false, enabled: false});
  assert.equal(await status(lostGrant), 'started');
  assert.equal(await control('finish', {id: lostGrant}), false);
  assert.equal(await status(lostReceipt), 'settled');
  assert.equal((await run(blocked)).status, 503);
  assert.equal(await status(blocked), 'registered');
  assert.equal(requests, 2);
  assert.equal((await run(blocked, 'legacy')).status, 204);
  assert.equal(requests, 3);

  // REST has the new interface while the Token Source only serves legacy RPC.
  await runtime.dispose();
  await startRuntime({legacy: true, reverse: false, enabled: false});
  assert.equal((await run(blocked)).status, 503);
  assert.equal(await status(blocked), 'registered');
  assert.equal((await run(blocked, 'legacy')).status, 204);
  assert.equal(requests, 4);

  await runtime.dispose();
  await assert.rejects(startRuntime({enabled: false, acknowledgement: 'WrongAcknowledgement'}),
    /no such named entrypoint/);
  assert.equal(requests, 4);

  // Restore the known compatible pair, leaving registration off. Existing
  // unstarted work can finish normally while unresolved starts stay held.
  await runtime.dispose().catch(error => {
    if (error.code !== 'ERR_RUNTIME_FAILURE') throw error;
  });
  await startRuntime({enabled: false});
  assert.equal(await status(blocked), 'registered');
  assert.equal((await run(blocked)).status, 204);
  assert.equal(await status(blocked), 'settled');
  assert.equal(await status(lostGrant), 'started');
  assert.equal(await control('finish', {id: lostGrant}), false);
  assert.equal(requests, 5);
});
