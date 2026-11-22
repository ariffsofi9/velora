import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {mkdtemp, rm} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {basename, dirname, join, resolve} from 'node:path';
import {after, before, test} from 'node:test';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {syntheticIdentity} from '../feasibility/shared-backend/integration/synthetic-identity.mjs';
import {createApplication} from '../backend/application.mjs';
import {CERTIFICATE_URL} from '../backend/google-http.mjs';
import {createHttpPolicy} from '../backend/http-policy.mjs';
import {createAuthenticatedJsonHttp} from '../https/authenticated-json-http.mjs';

const localRequire = createRequire(new URL('../feasibility/shared-backend/runtime/package.json', import.meta.url));
const {Miniflare} = localRequire('miniflare');
const {build} = localRequire('esbuild');
const origin = 'https://velora-test.invalid';
const project = 'velora-spark-test';
const realProject = 'velora-73222';
const realFixtureOrigin = 'https://velora-real.example.test';
const route = '/inventory/create';
const identity = syntheticIdentity(Date.now);
const owner = 'offline-owner';
const uidKey = uid => createHash('sha256').update(`${project}\0${uid}`).digest('hex');
const originalCwd = process.cwd();
let directory, runtime, bundle;
const unexpectedEgress = [];
let redirectAccount = false;
let roster;
const cafe = 'fixture-cafe';
const staff = Array.from({length: 99}, (_, index) => `staff-${String(index).padStart(2, '0')}`);

async function start() {
  const documents = `projects/${realProject}/databases/(default)/documents`;
  const transaction = Buffer.from('real-offline-fixture').toString('base64');
  const membership = `${documents}/user_cafe_memberships/${owner}`;
  const accountUrl = `https://identitytoolkit.googleapis.com/v1/projects/${realProject}/accounts:lookup`;
  const firestore = `https://firestore.googleapis.com/v1/${documents}`;
  const at = '2026-11-22T00:00:00.000Z';
  const document = (name, data) => ({name, createTime: at, updateTime: at,
    fields: Object.fromEntries(Object.entries(data).map(([key, value]) => [key,
      value instanceof Date ? {timestampValue: value.toISOString()} :
        typeof value === 'number' ? {integerValue: String(value)} : {stringValue: value}]))});
  const active = {schemaVersion: 1, status: 'active'};
  const member = uid => ({...active, uid, cafeId: cafe, role: uid === owner ? 'owner' : 'staff'});
  // Each Worker gets a synthetic-only outbound service, with no network path.
  const outboundService = async request => {
    if (roster) roster.requests++;
    if (request.method === 'GET' && request.url === CERTIFICATE_URL) {
      return Response.json({synthetic: identity.certificate}, {headers: {'cache-control': 'max-age=3600'}});
    }
    if (request.method === 'POST' && request.headers.get('authorization') === 'Bearer real-fixture-only') {
      const body = await request.json();
      if (roster && request.url === accountUrl && body.localId.every(uid => uid === owner || staff.includes(uid))) {
        roster.lookups.push([...body.localId]);
        return Response.json({users: body.localId.toReversed().map(uid => ({localId: uid,
          email: `${uid}@example.test`, disabled: uid === roster.disabled,
          emailVerified: uid !== roster.unverified, validSince: '1'}))});
      }
      if (roster && request.url === `${firestore}:batchGet` && body.transaction === transaction) {
        return Response.json(body.documents.toReversed().map(name => {
          const prefix = `${documents}/user_cafe_memberships/`;
          const members = `${documents}/cafes/${cafe}/members/`;
          if (name === `${documents}/cafes/${cafe}`) return {found: document(name, {...active, ownerUid: owner})};
          if (name.startsWith(prefix)) {
            const uid = name.slice(prefix.length);
            return {found: document(name, {...active, uid, cafeId: uid === roster.foreign ? 'other-cafe' : cafe})};
          }
          if (name.startsWith(members)) return {found: document(name, member(name.slice(members.length)))};
          if (name.startsWith(`${documents}/users/`)) {
            const uid = name.split('/').at(-1);
            if (uid === roster.missingProfile) return {missing: name};
            return {found: document(name, {username: uid, role: 'owner', photoUrl: '',
              email: `${uid}@example.test`, createdAt: new Date(at), updatedAt: new Date(at)})};
          }
          throw Error('Unexpected fixture document');
        }));
      }
      if (roster && request.url === `${firestore}/cafes/${cafe}:runQuery` && body.transaction === transaction &&
          body.structuredQuery?.from?.[0]?.collectionId === 'members' && body.structuredQuery.limit === 21) {
        assert.deepEqual(body.structuredQuery.where, {fieldFilter: {field: {fieldPath: 'role'}, op: 'EQUAL', value: {stringValue: 'staff'}}});
        roster.queries++;
        const after = body.structuredQuery.startAt?.values[0].referenceValue.split('/').at(-1);
        return Response.json(staff.filter(uid => !after || uid > after).slice(0, 21).map(uid => ({document: document(`${documents}/cafes/${cafe}/members/${uid}`,
          roster.queries > 1 && uid === roster.stale ? {...member(uid), membershipGeneration: 1} : member(uid))})));
      }
      if (roster && request.url === `${firestore}:commit` && body.transaction === transaction && !body.writes.length) {
        roster.commits++;
        if (roster.retry && roster.commits % 2 === 1) return Response.json({error: {status: 'ABORTED', code: 409}}, {status: 409});
        return Response.json({commitTime: at});
      }
      if (request.url === accountUrl && body.localId?.length === 1 && body.localId[0] === owner) {
        if (redirectAccount) return Response.redirect('https://redirect.example.test/ignored', 302);
        return Response.json({users: [{localId: owner, email: `${owner}@example.test`, disabled: false,
          emailVerified: true, validSince: '1'}]});
      }
      if (request.url === `${firestore}:beginTransaction`) return Response.json({transaction});
      if (request.url === `${firestore}:batchGet` && body.transaction === transaction &&
          body.documents?.length === 1 && body.documents[0] === membership) {
        return Response.json([{missing: membership, readTime: '2026-11-22T00:00:00Z'}]);
      }
      if (request.url === `${firestore}:rollback` && body.transaction === transaction) return Response.json({});
    }
    unexpectedEgress.push(request.url);
    return Response.json({error: 'fixture-egress-denied'}, {status: 599});
  };
  const worker = {modules: true, modulesRoot: directory, script: bundle, outboundService,
    compatibilityDate: '2026-06-11', compatibilityFlags: ['nodejs_compat', 'enable_request_signal']};
  const config = {VELORA_ENVIRONMENT: 'test', VELORA_FIREBASE_PROJECT: project, VELORA_PUBLIC_ORIGIN: origin,
    ADMISSION_RESERVATION_MS: '900', SYNTHETIC_CERTIFICATE: identity.certificate};
  runtime = new Miniflare({host: '127.0.0.1', cf: false, rootPath: directory,
    durableObjectsPersist: join(directory, 'sqlite'), workers: [
      {...worker, name: 'test', bindings: config,
        durableObjects: {ADMISSION: {className: 'AdmissionCoordinator', useSQLite: true}}},
      {...worker, name: 'peer', bindings: config,
        durableObjects: {ADMISSION: {className: 'AdmissionCoordinator', scriptName: 'test', useSQLite: true}}},
      {...worker, name: 'real', bindings: {...config, VELORA_ENVIRONMENT: 'real', VELORA_FIREBASE_PROJECT: realProject,
        ADMISSION_PROJECT_LIMIT: '2', ADMISSION_RECORD_LIMIT: '2'},
      durableObjects: {ADMISSION: {className: 'AdmissionCoordinator', useSQLite: true}}},
      {...worker, name: 'real-bound', bindings: {...config, VELORA_ENVIRONMENT: 'real',
        VELORA_FIREBASE_PROJECT: realProject, VELORA_PUBLIC_ORIGIN: realFixtureOrigin, USE_FIXTURE_SOURCE: true},
      durableObjects: {ADMISSION: {className: 'AdmissionCoordinator', useSQLite: true}}},
      {...worker, name: 'unbound', bindings: config},
    ]});
  await runtime.ready;
}

before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'velora-admission-'));
  const result = await build({stdin: {resolveDir: fileURLToPath(new URL('..', import.meta.url)),
    contents: `
      import worker, {createWorkerApplication} from './runtime/worker-entry.mjs';
      export {AdmissionCoordinator} from './runtime/worker-entry.mjs';
      import {CERTIFICATE_URL} from './backend/google-http.mjs';
      const token = Object.assign(async () => 'synthetic-only', {projectId: '${project}'});
      const fixtureSource = {async acquire(projectId) {
        if (projectId !== '${realProject}') throw Error('Unexpected fixture project');
        return {projectId, access_token: 'real-fixture-only', token_type: 'Bearer', expires_in: 300};
      }};
      let app;
      export default {async fetch(request, env, ctx) {
        const path = new URL(request.url).pathname;
        if (path === '/__fixture/rpc') {
          const {method, args, alternateName} = await request.json();
          try {
            const stub = env.ADMISSION.get(env.ADMISSION.idFromName(alternateName ?? env.VELORA_FIREBASE_PROJECT));
            return Response.json(await stub[method](...args));
          } catch { return Response.json({error: 'fixture-rpc-failed'}, {status: 503}); }
        }
        if (path === '/__fixture/default') return worker.fetch(request, env, ctx);
        // The Miniflare service proxy supplies a loopback Host. Represent the
        // canonical ingress authority for the requests reaching the app here.
        const headers = new Headers(request.headers);
        if (!/^127[.]0[.]0[.]1:[0-9]+$/.test(headers.get('host') ?? '')) throw Error('Expected local proxy');
        headers.set('host', new URL(request.url).host);
        const incoming = new Request(request, {headers});
        if (env.USE_FIXTURE_SOURCE) {
          const source = headers.get('x-fixture-fault') === 'binding-removed' ? undefined : fixtureSource;
          return worker.fetch(incoming, {...env, VELORA_GOOGLE_TOKEN_SOURCE: source}, ctx);
        }
        const fault = request.headers.get('x-fixture-fault');
        const dependencies = {accessToken: token, async transport(url, options) {
          if (url === CERTIFICATE_URL) return Response.json({synthetic: env.SYNTHETIC_CERTIFICATE},
            {headers: {'cache-control': 'max-age=3600'}});
          if (url === 'https://identitytoolkit.googleapis.com/v1/projects/${project}/accounts:lookup') {
            const [uid] = JSON.parse(options.body).localId;
            return Response.json({users: [{localId: uid, email: uid + '@example.test',
              emailVerified: true, disabled: false, validSince: '1'}]});
          }
          throw Error('Unexpected provider request');
        }};
        const application = fault ? createWorkerApplication({...env, ADMISSION_RPC_TIMEOUT_MS: '80', ADMISSION: {
          idFromName: name => env.ADMISSION.idFromName(name),
          get(id) {
            const stub = env.ADMISSION.get(id);
            return {
              async reserve(...args) {
                if (fault === 'storage') throw Error('private storage detail');
                const result = await stub.reserve(...args);
                if (fault === 'reserve') return new Promise(() => {});
                return result;
              },
              async claim(...args) {
                const result = await stub.claim(...args);
                if (fault === 'claim') return new Promise(() => {});
                return result;
              },
              attribute: (...args) => stub.attribute(...args),
              finish: (...args) => stub.finish(...args),
            };
          },
        }}, dependencies) : (app ??= createWorkerApplication(env, dependencies));
        return application.fetch(incoming, work => ctx.waitUntil(work));
      }};
    `}, bundle: true, write: false, format: 'esm', platform: 'browser', external: ['cloudflare:*', 'node:*'],
    banner: {js: `import * as nodeCrypto from 'node:crypto';
      const require = name => { if (name === 'node:crypto') return nodeCrypto; throw Error('Unexpected import'); };`}});
  bundle = result.outputFiles[0].text;
  // workerd resolves persistent storage below its starting directory.
  process.chdir(directory);
  await start();
});

after(async () => {
  try {
    await runtime?.dispose();
    assert.deepEqual(unexpectedEgress, []);
  }
  finally {
    process.chdir(originalCwd);
    if (directory && dirname(resolve(directory)) === resolve(tmpdir()) && basename(directory).startsWith('velora-admission-')) {
      await rm(directory, {recursive: true, force: true});
    }
  }
});

async function call(worker, target, init, baseUrl = origin) {
  const service = await runtime.getWorker(worker);
  const response = await service.fetch(baseUrl + target, init);
  return {status: response.status, body: await response.json()};
}
async function invoke(worker, method, args, alternateName) {
  const response = await call(worker, '/__fixture/rpc', {method: 'POST',
    body: JSON.stringify({method, args, alternateName})});
  assert.equal(response.status, 200);
  return response.body;
}
const begin = () => [randomUUID(), Date.now() + 30000];
async function reserve(worker = 'test', [attempt, until] = begin()) {
  const token = await invoke(worker, 'reserve', [attempt, until]);
  return token === null ? null : [attempt, token];
}
async function occupy(worker, uid) {
  const permit = await reserve(worker);
  assert.ok(permit);
  assert.equal(await invoke(worker, 'claim', permit), true);
  assert.equal(await invoke(worker, 'attribute', [...permit, uidKey(uid)]), true);
  return permit;
}
const finish = (permit, worker = 'test') => invoke(worker, 'finish', permit);
const post = (worker = 'test', fault) => call(worker, route, {method: 'POST', body: '{}', headers: {
  authorization: `Bearer ${identity.token(owner)}`, 'content-type': 'application/json',
  'x-client-uid': 'different-user', ...(fault ? {'x-fixture-fault': fault} : {}),
}});

test('two local Workers share atomic pre-authentication and project capacity', async () => {
  const contenders = await Promise.all(Array.from({length: 8}, (_, i) => reserve(i % 2 ? 'peer' : 'test')));
  const held = contenders.filter(Boolean);
  assert.equal(held.length, 2);
  for (const permit of held) await finish(permit);
  const claimed = [];
  for (let i = 0; i < 8; i++) claimed.push(await occupy(i % 2 ? 'peer' : 'test', `user-${i}`));
  assert.equal(await reserve('peer'), null);
  assert.equal((await post('peer')).status, 429);
  for (const permit of claimed) await finish(permit);
});

test('verified UID attribution rejects a spoofed identity header and preserves route validation', async () => {
  const held = [await occupy('test', owner), await occupy('peer', owner)];
  assert.deepEqual(await post('peer'), {status: 429, body: {error: 'resource-exhausted'}});
  await finish(held[0]);
  // Real synthetic JWT verification succeeds, then the canonical validator handles the body.
  assert.deepEqual(await post('peer'), {status: 400, body: {error: 'invalid-argument'}});
  await finish(held[1]);
});

test('REAL Worker uses the existing REST authorization with REAL-only synthetic provider responses', async () => {
  assert.throws(() => createApplication({projectId: realProject}), /invalid-configuration/);
  assert.throws(() => createApplication({projectId: realProject, realWorker: {projectId: realProject}}),
    /invalid-configuration/);
  const data = {expectedCafeId: 'fixture-cafe', expectedMembershipGeneration: 0,
    idempotencyKey: 'offline-create-00001', name: 'Rice', category: 'Dry', quantity: 1,
    unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'};
  const postReal = (bearer, target = route, extraHeaders = {}) => call('real-bound', target, {method: 'POST',
    body: JSON.stringify(data), headers: {authorization: `Bearer ${bearer}`, 'content-type': 'application/json', ...extraHeaders}},
  realFixtureOrigin);
  assert.deepEqual(await postReal(identity.token(owner)), {status: 401, body: {error: 'unauthenticated'}});
  const bearer = identity.token(owner, {aud: realProject, iss: `https://securetoken.google.com/${realProject}`});
  assert.deepEqual(await postReal(bearer), {status: 403, body: {error: 'permission-denied'}});
  assert.deepEqual(await postReal(bearer, '/ai/generate'), {status: 404, body: {error: 'not-found'}});
  assert.deepEqual(await postReal(bearer, route, {'x-fixture-fault': 'binding-removed'}),
    {status: 503, body: {error: 'unavailable'}});
  redirectAccount = true;
  try {
    assert.deepEqual(await postReal(bearer), {status: 401, body: {error: 'unauthenticated'}});
  } finally { redirectAccount = false; }
  assert.deepEqual(unexpectedEgress, []);
});

test('REAL roster pages 20 Staff with valid profiles and stays within the Free egress budget', async () => {
  const request = async (uid, options = {}) => {
    roster = {requests: 0, queries: 0, commits: 0, lookups: [], ...options};
    const bearer = identity.token(uid, {aud: realProject, iss: `https://securetoken.google.com/${realProject}`});
    const payload = options.payload ?? {expectedCafeId: cafe, expectedMembershipGeneration: 0,
      ...(options.cursor ? {cursor: options.cursor} : {})};
    try {
      return {response: await call('real-bound', '/staff/list', {method: 'POST', body: JSON.stringify(payload),
        headers: {authorization: `Bearer ${bearer}`, 'content-type': 'application/json'}}, realFixtureOrigin), stats: roster};
    } finally { roster = undefined; }
  };
  const full = await request(owner);
  assert.equal(full.response.status, 200);
  assert.equal(full.response.body.members.length, 21);
  assert.equal(full.stats.requests, 23);
  assert.equal(full.stats.queries, 2);
  assert.deepEqual(full.stats.lookups.map(uids => uids.length), [1, 1, 21, 1]);
  const next = await request(owner, {cursor: full.response.body.nextCursor});
  assert.deepEqual(next.response.body.members.map(profile => profile.uid), staff.slice(20, 40));
  for (const [payload, status] of [
    [{}, 400],
    [{expectedCafeId: 'other-cafe', expectedMembershipGeneration: 0}, 403],
    [{expectedCafeId: cafe, expectedMembershipGeneration: 1, cursor: full.response.body.nextCursor}, 403],
    [{expectedCafeId: cafe, expectedMembershipGeneration: 0, cursor: 'malformed'}, 400],
    [{expectedCafeId: cafe, expectedMembershipGeneration: 0, uid: staff[0]}, 400],
  ]) {
    const invalid = await request(owner, {payload});
    assert.equal(invalid.response.status, status);
    assert.equal(invalid.stats.queries, 0);
  }
  assert.equal((await request(staff[0], {cursor: full.response.body.nextCursor})).response.status, 403);
  const retry = await request(owner, {retry: true});
  assert.equal(retry.response.status, 200);
  assert.equal(retry.stats.requests, 43);
  assert.equal(retry.stats.queries, 4);
  const limited = await request(staff[0]);
  assert.equal(limited.response.status, 200);
  assert.deepEqual(limited.response.body.members.map(profile => profile.uid), [owner, staff[0]]);
  assert.equal(limited.stats.queries, 0);
  const changed = await request(owner, {foreign: staff[0], stale: staff[1], missingProfile: staff[2]});
  assert.equal(changed.response.status, 200);
  assert.equal(changed.response.body.members.length, 18);
  assert.ok(!changed.stats.lookups.flat().includes(staff[0]));
  assert.ok(!changed.response.body.members.some(profile => [staff[0], staff[1]].includes(profile.uid)));
  for (const options of [{disabled: staff[0]}, {unverified: staff[0]}]) {
    const invalid = await request(owner, options);
    assert.equal(invalid.response.status, 200);
    assert.equal(invalid.response.body.members.length, 20);
    assert.ok(!invalid.response.body.members.some(profile => profile.uid === staff[0]));
    assert.equal(invalid.stats.queries, 2);
  }
  const denied = await request(staff[0], {disabled: staff[0]});
  assert.deepEqual(denied.response, {status: 401, body: {error: 'unauthenticated'}});
  assert.equal(denied.stats.commits, 0);
});

test('claims are one-shot and stale releases cannot free another permit', async () => {
  const attempt = begin();
  const permit = await reserve('test', attempt);
  const results = await Promise.all([invoke('test', 'claim', permit), invoke('peer', 'claim', permit)]);
  assert.equal(results.filter(Boolean).length, 1);
  await finish(permit);
  const replay = await call('peer', '/__fixture/rpc', {method: 'POST',
    body: JSON.stringify({method: 'reserve', args: attempt})});
  assert.equal(replay.status, 503);
  const first = await reserve(), second = await reserve('peer');
  await finish([first[0], permit[1]]);
  await finish(permit);
  assert.equal(await reserve('peer'), null);
  await finish(first);
  await finish(second);
});

test('unclaimed slots expire while claimed slots survive elapsed deadlines and runtime restart', async () => {
  const running = await reserve('peer', [randomUUID(), Date.now() + 450]);
  assert.equal(await invoke('peer', 'claim', running), true);
  const abandoned = await reserve('test', [randomUUID(), Date.now() + 450]);
  assert.equal(await reserve('test'), null);
  await runtime.dispose();
  await delay(500);
  await start();
  const replacement = await reserve('test');
  assert.ok(replacement);
  assert.equal(await invoke('peer', 'claim', abandoned), false);
  assert.equal(await reserve('peer'), null);
  await finish(running);
  const additional = await reserve('peer');
  assert.ok(additional);
  await finish(additional);
  await finish(replacement);
});

test('bounded replay storage and distinct namespaces preserve fail-closed REAL configuration', async () => {
  const held = await reserve();
  const first = await reserve('real'), second = await reserve('real');
  assert.ok(first && second);
  await finish(first, 'real');
  await finish(second, 'real');
  assert.equal(await reserve('real'), null);
  const wrongObject = await call('test', '/__fixture/rpc', {method: 'POST', body: JSON.stringify({
    method: 'reserve', args: begin(), alternateName: realProject,
  })});
  assert.equal(wrongObject.status, 503);
  assert.deepEqual(await call('real', '/__fixture/default'), {status: 503, body: {error: 'unavailable'}});
  assert.deepEqual(await call('unbound', '/__fixture/default'), {status: 503, body: {error: 'unavailable'}});
  await finish(held);
});

test('storage failure and lost reserve or claim acknowledgements fail before route dispatch', async () => {
  for (const fault of ['storage', 'claim', 'reserve']) {
    assert.deepEqual(await post('test', fault), {status: 503, body: {error: 'unavailable'}});
  }
  const held = await reserve('peer');
  assert.ok(held);
  assert.equal(await reserve('test'), null);
  await delay(950);
  const first = await reserve('peer'), second = await reserve('test');
  assert.ok(first && second);
  await finish(first);
  await finish(second);
});

test('verification timeout returns promptly and retains admission until protected work settles', async () => {
  const late = Promise.withResolvers();
  const deferred = [];
  let releases = 0;
  const permit = {async finish() { releases++; }, async attribute() { assert.fail('Late attribution'); }};
  const admission = {projectId: project, async acquire() { return permit; }};
  class DomainError extends Error {}
  const handler = createAuthenticatedJsonHttp({projectId: project, storeProjectId: project,
    verifyIdentity: () => late.promise, verificationTimeoutMs: 20, domainErrorTypes: [DomainError],
    routes: new Map([[route, () => assert.fail('Late dispatch')]])});
  const fetch = createHttpPolicy({projectId: project, publicOrigin: origin, allowedOrigins: [origin],
    routes: [route], handler, admission, maxConcurrent: 1});
  const request = () => new Request(origin + route, {method: 'POST', body: '{}',
    headers: {authorization: 'Bearer synthetic', 'content-type': 'application/json'}});
  const first = await fetch(request(), work => deferred.push(work));
  assert.equal(first.status, 408);
  assert.equal(releases, 0);
  assert.equal((await fetch(request())).status, 429);
  assert.equal(deferred.length, 1);
  late.resolve(null);
  await deferred[0];
  assert.equal(releases, 1);
});
