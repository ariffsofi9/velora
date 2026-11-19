// Synthetic offline scenario controller. Never deploy this file.
import {syntheticIdentity} from '../integration/synthetic-identity.mjs';
import restModule from '../../../test/helpers/shared-firestore-rest-fake.cjs';
import model from '../../../src/saved-recipe-model.js';
import {createSavedRecipesHttp} from '../../../https/saved-recipes-http.mjs';
import {createGoogleHttp, CERTIFICATE_URL, OAUTH_URL} from '../../../backend/google-http.mjs';
import {createGoogleOAuth} from '../../../backend/google-oauth.mjs';
import {createFirebaseAccounts, createFirebaseIdentity} from '../../../backend/firebase-identity.mjs';
import {createFirestoreStore} from '../../../backend/firestore-store.mjs';

const projectId = 'velora-spark-test';
const episode = {expectedCafeId: 'cafe', expectedMembershipGeneration: 0};
const listing = {...episode, mode: 'active', limit: 1, cursor: null};
const privateDetail = 'SYNTHETIC_PRIVATE_UPSTREAM_DETAIL';
const check = (condition, label) => { if (!condition) throw Error(label); };

function fixture({large = false} = {}) {
  let time = Date.UTC(2026, 10, 18);
  const now = () => time;
  // Existing fixture generates only ephemeral synthetic test key material.
  const identity = syntheticIdentity(now);
  const accounts = Object.fromEntries(['owner', 'staff', 'outsider'].map(uid => [uid,
    {localId: uid, email: `${uid}@example.test`, emailVerified: true, disabled: false, validSince: '0'}]));
  const seed = {'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1}};
  for (const uid of ['owner', 'staff']) {
    const link = {uid, cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: 0};
    seed[`user_cafe_memberships/${uid}`] = link;
    seed[`cafes/cafe/members/${uid}`] = {...link, role: uid};
  }
  const ids = [];
  for (const title of large ? Array.from({length: 20}, (_, i) => String(i).padStart(3, '0') + 'x'.repeat(97)) : ['Offline rice', 'Offline bread']) {
    const recipe = {title, ingredients: large ? Array.from({length: 10}, (_, i) => ({itemId: `${i}` + 'i'.repeat(127), quantity: 1, unit: 'pcs'})) : [{itemId: 'item', quantity: 1, unit: 'pcs'}],
      steps: large ? Array(8).fill('s'.repeat(300)) : ['Prepare safely.'], whyRecommended: large ? 'w'.repeat(300) : 'Synthetic qualification.'};
    const binding = model.identity(projectId, 'cafe', recipe);
    ids.push(binding.recipeId);
    seed[`cafes/cafe/saved_recipes/${binding.recipeId}`] = {schemaVersion: 1, projectId, cafeId: 'cafe',
      recipeId: binding.recipeId, contentDigest: binding.contentDigest, recipe,
      source: 'workspace-submitted', provenanceEvidence: 'unverified-attribution',
      submittedAttribution: {kind: 'sample', provider: null, ticketId: null},
      createdBy: 'owner', updatedBy: 'owner', createdAt: new Date(now()), updatedAt: new Date(now()),
      version: 1, isArchived: false, archivedBy: null, archivedAt: null};
  }
  ids.sort();
  const fake = restModule.createRestFake(seed), trace = [];
  let accountHook;
  const transport = async (url, options) => {
    trace.push(url);
    check(options.redirect === 'error', 'redirect policy');
    if (url === CERTIFICATE_URL) return Response.json({synthetic: identity.certificate},
      {headers: {'cache-control': 'public, max-age=3600'}});
    if (url === OAUTH_URL) {
      identity.verifyAssertion(options.body);
      return Response.json({access_token: 'synthetic-access', token_type: 'Bearer', expires_in: 3600});
    }
    if (url === `https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`) {
      check(options.headers.authorization === 'Bearer synthetic-access', 'account credential');
      if (accountHook) return accountHook();
      const uid = JSON.parse(options.body).localId[0];
      return Response.json({users: accounts[uid] ? [accounts[uid]] : []});
    }
    if (new URL(url).origin === 'https://firestore.googleapis.com') return fake.transport(url, options);
    throw Error('Unexpected injected destination');
  };
  const http = createGoogleHttp({projectId, transport});
  const accessToken = createGoogleOAuth({projectId, email: `synthetic@${projectId}.iam.gserviceaccount.com`,
    sign: identity.sign, http, now});
  const getAccount = createFirebaseAccounts({projectId, http, accessToken});
  const verifier = createFirebaseIdentity({projectId, http, getAccount, now});
  const actualStore = createFirestoreStore({projectId, http, accessToken, now, sleep: async () => {}, random: () => 0});
  let mutationCalls = 0;
  const store = {...actualStore, runTransaction: callback => actualStore.runTransaction(tx => callback({...tx,
    create() { mutationCalls++; throw Error('Business write forbidden'); },
    update() { mutationCalls++; throw Error('Business write forbidden'); },
    set() { mutationCalls++; throw Error('Business write forbidden'); },
    delete() { mutationCalls++; throw Error('Business write forbidden'); },
  }))};
  const options = {projectId, storeProjectId: projectId, verifyIdentity: verifier, store, timestamp: actualStore.timestamp};
  function handler(patch = {}) {
    const canonical = createSavedRecipesHttp({...options, ...patch});
    return request => {
      const url = new URL(request.url);
      // Admission only; identity/authorization/validation remain canonical.
      if (request.method !== 'POST' || !['/recipes/list', '/recipes/get'].includes(url.pathname)) {
        return Response.json({error: 'not-found'}, {status: 404, headers: {'cache-control': 'no-store'}});
      }
      return canonical(request);
    };
  }
  const request = (operation = 'list', data = listing, uid = 'owner', claims = {}, token, signal) =>
    new Request(`https://offline.invalid/recipes/${operation}`, {method: 'POST', signal,
      headers: {'content-type': 'application/json', authorization: `Bearer ${token ?? identity.token(uid, claims)}`},
      body: JSON.stringify(data)});
  const active = handler();
  const call = async (...args) => {
    const response = await active(request(...args));
    check(response.headers.get('cache-control') === 'no-store', 'cache policy');
    return {status: response.status, body: await response.json()};
  };
  return {identity, accounts, fake, trace, ids, seed, now, options, handler, request, call,
    advance: ms => { time += ms; },
    mutationCalls: () => mutationCalls, accountHook: value => { accountHook = value; }};
}

// Resource protocol is synthetic/local only. One prepared fixture bounds retained
// state. Preparation (including key generation and signed requests) is not timed.
let prepared;
const resourceNames = ['list', 'get', 'signature', 'project', 'refresh', 'disabled',
  'revoked', 'large-list', 'large-get', 'response-cap', 'oversized', 'retry',
  'upstream', 'deadline', 'abort'];
async function resourceControl(input) {
  if (input.action === 'prepare') {
    check(resourceNames.includes(input.name), 'unknown resource scenario');
    const f = fixture({large: input.name.startsWith('large-')});
    const warmup = [];
    if (input.warm !== false) {
      for (let i = 0; i < 2; i++) {
        const r = await f.call(); check(r.status === 200, 'resource warmup'); warmup.push(r.status);
      }
    }
    let operation = ['get', 'large-get'].includes(input.name) ? 'get' : 'list';
    const data = operation === 'get' ? {...episode, recipeId: f.ids[0]} : {...listing, limit: input.name === 'large-list' ? 20 : 1};
    let claims = {}, token, patch = {}, status = 200;
    if (input.name === 'signature') { const parts = f.identity.token().split('.'); parts[2] = 'A'.repeat(parts[2].length); token = parts.join('.'); status = 401; }
    if (input.name === 'project') { claims.aud = 'velora-73222'; status = 401; }
    if (input.name === 'refresh') f.advance(3600001);
    if (input.name === 'disabled') { f.accounts.owner.disabled = true; status = 401; }
    if (input.name === 'revoked') { f.accounts.owner.validSince = String(f.now() / 1000 + 1); status = 401; }
    if (input.name === 'upstream') { f.accountHook(() => { throw Error(privateDetail); }); status = 401; }
    if (input.name === 'retry') f.fake.commitModes.push('abort');
    if (['response-cap', 'oversized'].includes(input.name)) {
      // Deliberate store-boundary output fault, not a valid large recipe result.
      const size = input.name === 'response-cap' ? 65536 : 65537;
      const result = {value: 'x'.repeat(size - Buffer.byteLength(JSON.stringify({value: ''})))};
      patch = {store: {...f.options.store, runTransaction: async () => result}};
      if (input.name === 'oversized') status = 503;
    }
    if (input.name === 'deadline') {
      patch = {requestTimeoutMs: 10}; status = 408;
      // Release late fake I/O after the deadline; no indefinite pending streams.
      f.fake.hooks.runQuery = async () => { await new Promise(resolve => setTimeout(resolve, 25)); };
    }
    // Store plain templates only: workerd forbids reusing a Request/stream
    // created by the preparation request in another request's I/O context.
    const signed = token ?? f.identity.token('owner', claims);
    const template = {url: `https://offline.invalid/recipes/${operation}`,
      body: JSON.stringify(data), headers: {'content-type': 'application/json', authorization: `Bearer ${signed}`}};
    if (input.name === 'abort') status = 408;
    const requests = Array(20).fill(template);
    f.trace.length = 0; f.fake.calls.length = 0;
    prepared = {f, handler: f.handler(patch), requests, status, count: 0, name: input.name};
    return Response.json({ready: true, expectedStatus: status, warmupRequests: warmup.length});
  }
  check(prepared, 'resource fixture not prepared');
  if (input.action === 'run') {
    check(Number.isInteger(input.index) && input.index >= 0 && input.index < 20, 'resource request bound');
    check(prepared.count++ < 20, 'resource count bound');
    const template = prepared.requests[input.index];
    const controller = new AbortController();
    if (prepared.name === 'abort') controller.abort();
    return prepared.handler(new Request(template.url, {method: 'POST', headers: template.headers,
      body: template.body, signal: controller.signal}));
  }
  if (input.action === 'inspect') {
    const {f} = prepared;
    check(f.mutationCalls() === 0, 'resource mutation');
    check(f.fake.calls.filter(c => c.method === 'commit').every(c => c.body.writes.length === 0), 'resource writes');
    check(JSON.stringify(f.seed) === JSON.stringify(f.fake.snapshot()), 'resource records changed');
    return Response.json({requests: prepared.count, accountLookups: f.trace.filter(url => url.includes('accounts:lookup')).length,
      certificates: f.trace.filter(url => url === CERTIFICATE_URL).length,
      oauth: f.trace.filter(url => url === OAUTH_URL).length, rpcCalls: f.fake.calls.length,
      commits: f.fake.calls.filter(c => c.method === 'commit').length});
  }
  throw Error('unknown resource control');
}

async function scenario(name) {
  if (name === 'egress') {
    const response = await fetch('https://velora-egress-must-fail.invalid/');
    check(response.status === 599 && await response.text() === 'OFFLINE_EGRESS_DENIED', 'egress did not hit local deny fixture');
    // An unregistered host is also blocked by disableNetConnect; Miniflare may
    // turn the mock exception into a synthetic 500 instead of rejecting fetch.
    let denied = false;
    try { denied = (await fetch('https://velora-unregistered-egress.invalid/')).status >= 500; }
    catch { denied = true; }
    check(denied, 'unregistered egress not denied');
    return {blocked: true};
  }
  const f = fixture();
  if (name === 'construction') {
    check(f.trace.length === 0, 'construction performs no IO');
    for (const patch of [{projectId: 'velora-73222'}, {storeProjectId: 'other'},
      {verifyIdentity: Object.assign(async () => ({}), {projectId: 'other'})}]) {
      let rejected = false;
      try { f.handler(patch); } catch { rejected = true; }
      check(rejected, 'project mismatch admitted');
    }
  } else if (name === 'admission') {
    for (const op of ['save', 'archive', 'restore', 'lifecycle', 'reconcile', 'unknown']) {
      check((await f.call(op)).status === 404, 'mutation route admitted');
    }
    const wrongMethod = new Request('https://offline.invalid/recipes/list', {method: 'GET'});
    check((await f.handler()(wrongMethod)).status === 404, 'method admitted');
    check(f.trace.length === 0 && f.mutationCalls() === 0, 'rejection dispatched');
  } else if (name === 'owner-staff-pagination') {
    for (const uid of ['owner', 'staff']) {
      const first = await f.call('list', listing, uid);
      check(first.status === 200 && first.body.items.length === 1 && first.body.nextCursor, 'first page');
      const next = await f.call('list', {...listing, cursor: first.body.nextCursor}, uid);
      check(next.status === 200 && next.body.items.length === 1 && next.body.nextCursor === null, 'next page');
      check(first.body.items[0].recipeId !== next.body.items[0].recipeId, 'pagination repeated item');
      const detail = await f.call('get', {...episode, recipeId: first.body.items[0].recipeId}, uid);
      check(detail.status === 200 && detail.body.item.cafeId === 'cafe', 'detail');
    }
    check(f.trace.filter(url => url.includes('accounts:lookup')).length === 12, 'fresh account per verifier call');
    check(f.trace.filter(url => url === CERTIFICATE_URL).length === 1, 'warm certificate reuse');
    check(f.trace.filter(url => url === OAUTH_URL).length === 1, 'warm OAuth reuse');
  } else if (['signature', 'project', 'unverified', 'disabled', 'revoked', 'account-unverified'].includes(name)) {
    let claims = {}, token;
    if (name === 'signature') { const t = f.identity.token(); const parts = t.split('.'); parts[2] = 'A'.repeat(parts[2].length); token = parts.join('.'); }
    if (name === 'project') claims.aud = 'velora-73222';
    if (name === 'unverified') claims.email_verified = false;
    if (name === 'disabled') f.accounts.owner.disabled = true;
    if (name === 'account-unverified') f.accounts.owner.emailVerified = false;
    if (name === 'revoked') f.accounts.owner.validSince = String(f.now() / 1000 + 1);
    const r = await f.call('list', listing, 'owner', claims, token);
    check(r.status === 401 && r.body.error === 'unauthenticated', 'identity accepted');
    check(f.fake.calls.length === 0, 'identity denial reached store');
  } else if (['generation', 'cross-workspace', 'inactive', 'outsider', 'transaction-conflict'].includes(name)) {
    if (name === 'inactive') {
      const path = 'cafes/cafe/members/staff';
      f.seed[path] = {...f.seed[path], status: 'revoked'};
      f.fake.replace(path, f.seed[path]);
    }
    if (name === 'transaction-conflict') {
      let changed = false;
      f.fake.hooks.runQuery = () => {
        if (!changed) {
          changed = true;
          for (const path of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) {
            f.seed[path] = {...f.seed[path], membershipGeneration: 1};
            f.fake.replace(path, f.seed[path]);
          }
        }
      };
    }
    const data = {...listing, ...(name === 'generation' ? {expectedMembershipGeneration: 9} : {}),
      ...(name === 'cross-workspace' ? {expectedCafeId: 'other'} : {})};
    const r = await f.call('list', data, name === 'outsider' ? 'outsider' : 'staff');
    check(r.status === (['inactive', 'outsider'].includes(name) ? 403 : 409), 'authority accepted');
    if (name === 'transaction-conflict') check(f.fake.calls.filter(c => c.method === 'beginTransaction').length === 2, 'no native retry');
  } else if (name === 'limits') {
    check((await f.call('list', {...listing, limit: 21})).status === 400, 'list bound');
    check((await f.call('get', {...episode, recipeId: 'recipe_' + 'f'.repeat(64)})).status === 404, 'missing detail');
    const oversized = f.request('list', {...listing, extra: 'x'.repeat(32769)});
    check((await f.handler()(oversized)).status === 413, 'request bytes');
    // Fault injection at the dependency boundary exercises canonical HTTP output admission.
    const huge = f.handler({store: {...f.options.store, runTransaction: async () => ({value: 'x'.repeat(65537)})}});
    check((await huge(f.request())).status === 503, 'response bytes');
  } else if (name === 'upstream-stream') {
    f.accountHook(() => new Response(new ReadableStream({start(controller) {
      const data = new TextEncoder().encode(JSON.stringify({users: [f.accounts.owner]}));
      controller.enqueue(data.slice(0, 8)); controller.enqueue(data.slice(8)); controller.close();
    }}), {headers: {'content-type': 'application/json'}}));
    check((await f.call()).status === 200, 'chunked account response');
    f.accountHook(() => { throw Error(privateDetail); });
    const denied = await f.call();
    check(denied.status === 401 && !JSON.stringify(denied).includes(privateDetail), 'upstream sanitization');
  } else if (name === 'warm-revocation') {
    check((await f.call()).status === 200, 'warmup');
    const before = f.fake.calls.length;
    f.accounts.owner.validSince = String(f.now() / 1000 + 1);
    check((await f.call()).status === 401, 'warm verifier cached positive account status');
    check(f.fake.calls.length === before, 'revoked warm request reached store');
  } else if (name === 'stream-abort') {
    let upstreamSignal, cancelled = false, expire;
    const blockedTransport = async (_url, options) => {
      upstreamSignal = options.signal;
      return new Response(new ReadableStream({
        start(controller) { controller.enqueue(new TextEncoder().encode('{')); expire(); },
        cancel() { cancelled = true; },
      }), {headers: {'content-type': 'application/json'}});
    };
    // A controlled pending body is aborted through the canonical Google HTTP
    // adapter, rather than relying on a wall-clock sleep or network timeout.
    let ready;
    const reached = new Promise(resolve => { ready = resolve; });
    expire = ready;
    const slow = createGoogleHttp({projectId, transport: blockedTransport, timeoutMs: 20});
    const result = slow(CERTIFICATE_URL).then(() => false, () => true);
    await reached;
    check(await result, 'pending stream accepted');
    check(upstreamSignal.aborted && cancelled, 'upstream abort/cancel missing');
  } else if (name === 'deadline-abort') {
    let expire, release, entered;
    const ready = new Promise(resolve => { entered = resolve; });
    const pending = new Promise(resolve => { release = resolve; });
    f.fake.hooks.runQuery = async () => { entered(); await pending; };
    const handler = f.handler({requestTimeoutMs: 12345, scheduleTimeout(callback, ms) {
      if (ms === 12345) { expire = callback; return () => {}; }
      const timer = setTimeout(callback, ms); return () => clearTimeout(timer);
    }});
    const task = handler(f.request());
    await ready; expire();
    check((await task).status === 408, 'deadline response');
    release();
    // Await a separate successful read after the expired read finishes yielding.
    f.fake.hooks.runQuery = undefined;
    check((await f.call()).status === 200, 'late result poisoned next request');
    check(f.fake.calls.filter(c => c.method === 'commit').length === 1, 'expired read committed late');
    const controller = new AbortController(); controller.abort();
    const before = f.trace.length;
    check((await f.handler()(f.request('list', listing, 'owner', {}, undefined, controller.signal))).status === 408, 'aborted request');
    check(f.trace.length === before, 'aborted request dispatched');
  } else throw Error('Unknown synthetic scenario');
  check(f.mutationCalls() === 0, 'domain business mutation');
  check(f.fake.calls.filter(c => c.method === 'commit').every(c => c.body.writes.length === 0), 'REST business mutation');
  check(JSON.stringify(f.fake.snapshot()) === JSON.stringify(f.seed), 'fixture records changed');
  return {ok: true, rpcCalls: f.fake.calls.length, mutations: f.mutationCalls()};
}

export default {async fetch(request) {
  try {
    const input = await request.json();
    if (input.action) return await resourceControl(input);
    return Response.json(await scenario(input.scenario));
  }
  catch (error) { return Response.json({ok: false, diagnostic: String(error.message)}, {status: 500}); }
}};
