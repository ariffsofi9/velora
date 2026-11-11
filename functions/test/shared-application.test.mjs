import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync, sign, X509Certificate} from 'node:crypto';
import {createApplication} from '../backend/application.mjs';
import {CERTIFICATE_URL, OAUTH_URL} from '../backend/google-http.mjs';
import {createRestFake} from './helpers/shared-firestore-rest-fake.cjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test', initial = Date.UTC(2026, 10, 11);
const publicOrigin = 'https://backend.invalid', origin = 'https://frontend.invalid';
const pair = generateKeyPairSync('rsa', {modulusLength: 2048});
// Generated in memory, independently signed X509 fixture. No secret files or
// external crypto command; this is a synthetic key, never a live credential.
function der(tag, ...values) {
  const data = Buffer.concat(values.map(value => Buffer.from(value)));
  let hex = data.length.toString(16); if (hex.length % 2) hex = `0${hex}`;
  const bytes = Buffer.from(hex, 'hex');
  return Buffer.concat([Buffer.from([tag]), data.length < 128 ? Buffer.from([data.length]) :
    Buffer.concat([Buffer.from([128 + bytes.length]), bytes]), data]);
}
const algorithm = der(0x30, der(6, Buffer.from('2a864886f70d01010b', 'hex')), der(5, []));
const name = der(0x30, der(0x31, der(0x30, der(6, [0x55, 4, 3]), der(0x0c, Buffer.from('SYNTHETIC S534')))));
const utc = time => der(0x17, Buffer.from(new Date(time).toISOString().replace(/[-:T]/g, '').slice(2, 14) + 'Z'));
const tbs = der(0x30, der(0xa0, der(2, [2])), der(2, [1]), algorithm, name,
  der(0x30, utc(initial - 86400000), utc(initial + 172800000)), name,
  pair.publicKey.export({format: 'der', type: 'spki'}));
const certificate = der(0x30, tbs, algorithm, der(3, [0], sign('sha256', tbs, pair.privateKey)));
const pem = `-----BEGIN CERTIFICATE-----\n${certificate.toString('base64').match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`;
assert.equal(new X509Certificate(pem).verify(pair.publicKey), true);

function records(generation) {
  const seed = {'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1},
    'cafes/cafe/inventory/item': {cafeId: 'cafe', name: 'Rice', category: 'Dry', quantity: 5, unit: 'kg',
      version: 1, schemaVersion: 1, expiryDate: new Date('2030-01-02T00:00:00Z')}};
  for (const uid of ['owner', 'staff']) {
    const link = {uid, cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: generation,
      createdAt: new Date(initial), updatedAt: new Date(initial)};
    seed[`user_cafe_memberships/${uid}`] = link;
    seed[`cafes/cafe/members/${uid}`] = {...link, role: uid};
  }
  return seed;
}
function fixture({generation = 0, ...overrides} = {}) {
  let time = initial;
  const fake = createRestFake(records(generation)), wireCalls = [], accounts = Object.fromEntries(
    ['owner', 'staff', 'joiner', 'outsider'].map(uid => [uid, {localId: uid, email: `${uid}@example.test`,
      emailVerified: true, disabled: false, validSince: String(initial / 1000 - 1)}]));
  const hooks = {};
  const transport = async (url, options) => {
    wireCalls.push({url, body: options.body});
    if (hooks.transport) { const result = await hooks.transport(url, options); if (result !== undefined) return result; }
    if (url === CERTIFICATE_URL) return Response.json({synthetic: pem}, {headers: {'cache-control': 'max-age=3600'}});
    if (url === OAUTH_URL) {
      const assertion = new URLSearchParams(options.body).get('assertion');
      assert.equal(JSON.parse(Buffer.from(assertion.split('.')[1], 'base64url')).iss, `synthetic@${projectId}.iam.gserviceaccount.com`);
      return Response.json({token_type: 'Bearer', access_token: 'synthetic-access', expires_in: 3600});
    }
    if (url === `https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`) {
      assert.equal(options.headers.authorization, 'Bearer synthetic-access');
      const input = JSON.parse(options.body);
      if (input.email) return Response.json({users: Object.values(accounts).filter(user => user.email === input.email[0])});
      const uid = input.localId[0];
      return Response.json({users: accounts[uid] ? [accounts[uid]] : []});
    }
    return fake.transport(url, options);
  };
  const config = {projectId, publicOrigin, allowedOrigins: [origin], transport, now: () => time,
    credential: {projectId, email: `synthetic@${projectId}.iam.gserviceaccount.com`,
      sign: async bytes => sign('RSA-SHA256', bytes, pair.privateKey)}, ...overrides};
  const app = createApplication(config);
  const token = (uid = 'owner', changes = {}) => {
    const head = Buffer.from(JSON.stringify({alg: 'RS256', kid: 'synthetic', typ: 'JWT'})).toString('base64url');
    const body = Buffer.from(JSON.stringify({sub: uid, aud: projectId, iss: `https://securetoken.google.com/${projectId}`,
      iat: initial / 1000, auth_time: initial / 1000, exp: initial / 1000 + 3600,
      email: `${uid}@example.test`, email_verified: true, ...changes})).toString('base64url');
    return `${head}.${body}.${sign('RSA-SHA256', Buffer.from(`${head}.${body}`), pair.privateKey).toString('base64url')}`;
  };
  const call = async (path, data, {uid = 'owner', bearer = token(uid), from = origin, method = 'POST', raw, headers = {}} = {}) => {
    const response = await app.fetch(new Request(publicOrigin + path, {method,
      headers: {'content-type': 'application/json', ...(bearer === null ? {} : {authorization: `Bearer ${bearer}`}),
        ...(from === null ? {} : {origin: from}), ...headers},
      ...(['POST', 'PUT', 'PATCH'].includes(method) ? {body: raw ?? JSON.stringify(data ?? {})} : {})}));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('access-control-allow-origin'), from === origin ? origin : null);
    return {status: response.status, body: response.status === 204 ? null : await response.json()};
  };
  return {fake, wireCalls, accounts, hooks, config, app, token, call,
    context: {expectedCafeId: 'cafe', expectedMembershipGeneration: generation}, advance: ms => { time += ms; }};
}
const createData = {idempotencyKey: 'create-request-0001', name: 'Rice', category: 'Dry', quantity: 2,
  unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'};
const updateData = {idempotencyKey: 'update-request-0001', itemId: 'item', expectedVersion: 1, name: 'New rice'};
const stockData = {idempotencyKey: 'stock-request-0001', itemId: 'item', expectedVersion: 1, direction: 'in', quantity: 2, reason: 'Delivery'};
const lifecycleData = {idempotencyKey: 'archive-request-0001', itemId: 'item', expectedVersion: 1, action: 'archive'};
const invitationData = {email: 'joiner@example.test', requestId: 'request_123456789'};
const operations = [['create', createData], ['update', updateData], ['adjust-stock', stockData], ['lifecycle', lifecycleData]];
const commits = f => f.fake.calls.filter(call => call.method === 'commit');
const invite = f => f.call('/staff/create', {...f.context, ...invitationData});

const aiSecret = 'SYNTHETIC_AI_SECRET';
const aiCompletion = () => Response.json({choices: [{finish_reason: 'stop', message: {content: JSON.stringify({recipes: [
  {title: 'Rice dish', ingredients: [{itemId: 'i1', quantity: 1, unit: 'kg'}],
    steps: ['Cook rice safely.'], whyRecommended: 'Uses rice.'},
]})}}]});
function aiFixture(options = {}) {
  const providerCalls = []; let provider = async () => aiCompletion();
  const f = fixture({...options, ai: {transport: async (url, request) => {
    providerCalls.push({url, ...request}); return provider(url, request);
  }, getSecret: () => aiSecret, timeoutMs: 50}});
  return {...f, providerCalls, provider: fn => { provider = fn; },
    issueAi: (data = {}, auth) => f.call('/ai/issue', {...f.context, ...data}, auth),
    generateAi: (ticketId, data = {}, auth) => f.call('/ai/generate', {...f.context, ticketId, ...data}, auth)};
}

test('AI stays unavailable without explicit dependencies; configured composition is inert and rejects invalid wiring', async () => {
  const f = fixture();
  for (const path of ['/ai/issue', '/ai/generate']) {
    assert.equal((await f.call(path)).status, 404);
    assert.equal((await f.call(path, {}, {method: 'OPTIONS', headers: {'access-control-request-method': 'POST'}})).status, 404);
  }
  assert.equal(f.wireCalls.length, 0);
  const enabled = aiFixture(); assert.equal(enabled.wireCalls.length, 0); assert.equal(enabled.providerCalls.length, 0);
  for (const ai of [null, {}, {transport() {}, getSecret() {}, model: 'other'},
    {transport() {}, getSecret() {}, timeoutMs: 0}]) assert.throws(() => createApplication({...f.config, ai}));
});

for (const generation of [0, 7]) for (const uid of ['owner', 'staff']) {
  test(`composed AI ${uid} generation=${generation} uses signed identity, fresh accounts and real REST quota`, async () => {
    const f = aiFixture({generation}), before = f.fake.snapshot();
    const issued = await f.issueAi({}, {uid}); assert.equal(issued.status, 200);
    const id = issued.body.ticketId;
    const result = await f.generateAi(id, {}, {uid}); assert.equal(result.status, 200);
    assert.equal(result.body.recipes[0].ingredients[0].itemId, 'item'); assert.equal(result.body.schemaVersion, 2);
    assert.equal((await f.generateAi(id, {}, {uid})).status, 409); assert.equal(f.providerCalls.length, 1);
    const state = f.fake.snapshot(); assert.equal(state[`ai_generation_tickets/${id}`].state, 'completed');
    assert.equal(state['ai_usage_workspaces/cafe'].lock, null); assert.equal(state['ai_usage_workspaces/cafe'].admitted, 1);
    assert.deepEqual(state['cafes/cafe/inventory/item'], before['cafes/cafe/inventory/item']);
    assert.ok(f.wireCalls.every(c => !c.url.includes('groq.com')));
    assert.equal(f.providerCalls[0].url, 'https://api.groq.com/openai/v1/chat/completions');
    assert.ok(f.wireCalls.some(c => c.url === CERTIFICATE_URL));
    assert.ok(f.wireCalls.some(c => c.url === OAUTH_URL));
    assert.ok(f.wireCalls.filter(c => c.url.includes('accounts:lookup')).length >= 5);
    assert.equal(JSON.stringify(state).includes(aiSecret), false);
    assert.equal(JSON.stringify(state).includes('Rice dish'), false);
  });
}
for (const op of ['issue', 'generate']) test(`configured AI ${op} enforces CORS, authenticated identity and exact routes`, async () => {
  const f = aiFixture(), path = `/ai/${op}`;
  assert.equal((await f.call(path, {}, {method: 'OPTIONS', headers: {'access-control-request-method': 'POST',
    'access-control-request-headers': 'authorization,content-type'}})).status, 204);
  assert.equal((await f.call(path, {}, {from: 'https://evil.invalid'})).status, 403);
  assert.equal((await f.call(path, {}, {bearer: null})).status, 401);
  assert.equal((await f.call(path, {}, {bearer: f.token('owner', {aud: 'velora-73222'})})).status, 401);
  for (const extra of ['/ai/cleanup', '/ai/recover', '/ai/reset-quota', '/ai/generate/extra']) {
    assert.equal((await f.call(extra)).status, 404);
  }
  assert.equal(f.fake.calls.length, 0); assert.equal(f.providerCalls.length, 0);
});

for (const mode of ['operation', 'model', 'cafe', 'generation', 'outsider', 'account']) test(`composed AI rejects ${mode} before quota/provider`, async () => {
  const f = aiFixture({generation: 7});
  if (mode === 'account') f.accounts.owner.disabled = true;
  const data = mode === 'operation' ? {operation: 'generate'} : mode === 'model' ? {model: 'other'} :
    mode === 'cafe' ? {expectedCafeId: 'other'} : mode === 'generation' ? {expectedMembershipGeneration: 0} : {};
  const result = await f.issueAi(data, {uid: mode === 'outsider' ? 'outsider' : 'owner'});
  assert.equal(result.status, ['operation', 'model'].includes(mode) ? 400 : ['cafe', 'generation'].includes(mode) ?
    409 : mode === 'account' ? 401 : 403);
  assert.equal(commits(f).length, 0); assert.equal(f.providerCalls.length, 0);
});

test('composed provider lost result quarantines durable evidence and cannot redispatch', async () => {
  const f = aiFixture(), id = (await f.issueAi()).body.ticketId;
  f.provider(async () => { throw Error(aiSecret); });
  assert.deepEqual(await f.generateAi(id), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(f.fake.snapshot()[`ai_generation_tickets/${id}`].state, 'quarantined');
  assert.ok(f.fake.snapshot()['ai_usage_workspaces/cafe'].lock);
  assert.equal((await f.generateAi(id)).status, 409); assert.equal(f.providerCalls.length, 1);
});

test('composed session revocation during provider work suppresses result and retains durable claim', async () => {
  const f = aiFixture(), id = (await f.issueAi()).body.ticketId;
  f.provider(async () => { f.accounts.owner.validSince = String(initial / 1000 + 1); return aiCompletion(); });
  assert.deepEqual(await f.generateAi(id), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(f.providerCalls.length, 1);
  assert.equal(f.fake.snapshot()[`ai_generation_tickets/${id}`].state, 'dispatched');
  assert.ok(f.fake.snapshot()['ai_usage_workspaces/cafe'].lock);
  assert.equal((await f.generateAi(id)).status, 401); assert.equal(f.providerCalls.length, 1);
});

const menuData = {idempotencyKey: 'menu-request-00001', name: 'Tea', category: 'Drinks', priceMinor: 350, isAvailable: true};
for (const generation of [0, 7]) test(`composed menu lifecycle, Staff exception and historical receipts generation=${generation}`, async () => {
  const f = fixture({generation}), before = f.fake.snapshot();
  const create = {...f.context, ...menuData};
  const first = await f.call('/menu/create', create);
  assert.equal(first.status, 200); const itemId = first.body.itemId;
  const edit = {...f.context, itemId, expectedVersion: 1, idempotencyKey: 'menu-update-00001', isAvailable: false};
  assert.equal((await f.call('/menu/update', {...edit, name: 'Tea'}, {uid: 'staff'})).status, 403);
  assert.equal((await f.call('/menu/update', edit, {uid: 'staff'})).body.version, 2);
  assert.equal((await f.call('/menu/get', {itemId}, {uid: 'staff'})).body.item.isAvailable, false);
  const archive = {...f.context, itemId, expectedVersion: 2, idempotencyKey: 'menu-archive-0001', action: 'archive'};
  assert.equal((await f.call('/menu/lifecycle', archive)).body.version, 3);
  assert.deepEqual((await f.call('/menu/list', {}, {uid: 'staff'})).body.items, []);
  assert.equal((await f.call('/menu/list', {includeArchived: true})).body.items[0].currency, 'MYR');
  assert.equal((await f.call('/menu/lifecycle', {...archive, action: 'restore', expectedVersion: 3,
    idempotencyKey: 'menu-restore-0001'})).body.version, 4);
  assert.deepEqual(await f.call('/menu/create', create), {status: 200, body: {...first.body, changed: false}});
  assert.equal((await f.call('/menu/create', {...create, priceMinor: 400})).status, 409);
  assert.equal((await f.call('/menu/update', edit)).status, 409);
  assert.deepEqual(f.fake.snapshot()['cafes/cafe/inventory/item'], before['cafes/cafe/inventory/item']);
  assert.ok(commits(f).flatMap(c => c.body.writes).every(w => /\/menu_(items|requests)\//.test(w.update.name)));
});

for (const operation of ['create', 'get', 'list', 'update', 'lifecycle']) {
  test(`composed /menu/${operation} enforces origin, identity and fresh account before store access`, async () => {
    const f = fixture(), path = `/menu/${operation}`;
    assert.equal((await f.call(path, {}, {method: 'OPTIONS', headers: {'access-control-request-method': 'POST',
      'access-control-request-headers': 'authorization,content-type'}})).status, 204);
    assert.equal((await f.call(path, {}, {from: 'https://evil.invalid'})).status, 403);
    assert.equal((await f.call(path, {}, {bearer: null})).status, 401);
    assert.equal((await f.call(path, {}, {bearer: f.token('owner', {aud: 'velora-73222'})})).status, 401);
    f.accounts.owner.disabled = true;
    assert.equal((await f.call(path)).status, 401); assert.equal(f.fake.calls.length, 0);
  });
}

test('menu fresh account is checked again after body authentication and before transaction dispatch', async () => {
  const f = fixture(); let lookups = 0;
  f.hooks.transport = (url, options) => {
    if (url.includes('accounts:lookup') && JSON.parse(options.body).localId?.[0] === 'owner' && ++lookups === 2) {
      f.accounts.owner.disabled = true;
    }
  };
  const result = await f.call('/menu/create', {...f.context, ...menuData});
  assert.equal(result.status, 503); assert.equal(f.fake.calls.length, 0); assert.equal(lookups, 2);
});

for (const patch of [{expectedCafeId: 'other'}, {expectedMembershipGeneration: 0}]) {
  test(`composed menu rejects stale workspace binding ${JSON.stringify(patch)}`, async () => {
    const f = fixture({generation: 7}), before = f.fake.snapshot();
    assert.deepEqual(await f.call('/menu/create', {...f.context, ...menuData, ...patch}),
      {status: 409, body: {error: 'aborted'}});
    assert.deepEqual(f.fake.snapshot(), before); assert.equal(commits(f).length, 0);
  });
}

test('composed menu lost acknowledgement remains unknown; explicit identical replay uses receipt', async () => {
  const f = fixture(), data = {...f.context, ...menuData};
  f.fake.commitModes.push('applied-lost');
  assert.deepEqual(await f.call('/menu/create', data), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 1);
  const replay = await f.call('/menu/create', data);
  assert.equal(replay.status, 200); assert.equal(replay.body.changed, false);
  assert.deepEqual(commits(f).at(-1).body.writes, []);
});

test('factory is inert, TEST-bound and requires explicit credential/endpoint configuration', () => {
  const f = fixture(); assert.equal(f.wireCalls.length, 0); assert.equal(f.fake.calls.length, 0);
  for (const patch of [{projectId: 'velora-73222'}, {credential: {...f.config.credential, projectId: 'other'}},
    {credential: {...f.config.credential, email: 'x@other.iam.gserviceaccount.com'}}, {transport: undefined},
    {publicOrigin: 'http://backend.invalid'}, {allowedOrigins: ['*']}, {verificationTimeoutMs: 0}]) {
    assert.throws(() => createApplication({...f.config, ...patch}));
  }
});

for (const generation of [0, 7]) for (const uid of ['owner', 'staff']) for (const [operation, payload] of operations) {
  test(`${uid} generation=${generation} ${operation}: signed identity to REST to canonical domain`, async () => {
    const f = fixture({generation});
    const response = await f.call('/inventory/' + operation, {...f.context, ...payload}, {uid});
    assert.equal(response.status, 200); assert.equal(response.body.cafeId, 'cafe');
    assert.equal(commits(f).length, 1);
    const audits = Object.entries(f.fake.snapshot()).filter(([path]) => path.includes('/activities/'));
    assert.equal(audits.length, 1); assert.equal(audits[0][1].actorUid, uid);
    assert.ok(f.wireCalls.some(call => call.url === CERTIFICATE_URL));
    assert.ok(f.wireCalls.some(call => call.url === OAUTH_URL));
    assert.ok(f.wireCalls.some(call => call.url.includes('accounts:lookup')));
    assert.ok(commits(f)[0].body.writes.some(write => write.updateTransforms?.some(value => value.setToServerValue === 'REQUEST_TIME')));
  });
}

for (const [operation, payload] of operations) {
  test(`${operation} rejects outsider, wrong cafe and stale generation with no mutation`, async () => {
    for (const variant of ['outsider', 'cafe', 'generation']) {
      const f = fixture({generation: 7}), before = f.fake.snapshot();
      const data = {...f.context, ...payload,
        ...(variant === 'cafe' ? {expectedCafeId: 'other'} : {}),
        ...(variant === 'generation' ? {expectedMembershipGeneration: 0} : {})};
      const response = await f.call('/inventory/' + operation, data, {uid: variant === 'outsider' ? 'outsider' : 'owner'});
      assert.equal(response.status, variant === 'outsider' ? 403 : 409);
      assert.equal(commits(f).length, 0); assert.deepEqual(f.fake.snapshot(), before);
    }
  });
  test(`${operation} unchanged retry preserves canonical result without duplicate audits`, async () => {
    const f = fixture(), data = {...f.context, ...payload};
    assert.equal((await f.call('/inventory/' + operation, data)).status, 200);
    const replay = await f.call('/inventory/' + operation, data);
    assert.equal(replay.status, 200);
    // Metadata replays retain the original updated flag; other domains mark
    // the replay explicitly. Preserve each existing acknowledgement contract.
    assert.equal(replay.body[{create: 'created', update: 'updated', 'adjust-stock': 'adjusted', lifecycle: 'changed'}[operation]], operation === 'update');
    assert.equal(Object.keys(f.fake.snapshot()).filter(path => path.includes('/activities/')).length, 1);
  });
}

test('concurrent identity contexts do not mix actor IDs, roles or operation receipts', async () => {
  const f = fixture();
  const result = await Promise.all(['owner', 'staff'].map(uid => f.call('/inventory/create',
    {...f.context, ...createData}, {uid})));
  assert.ok(result.every(response => response.status === 200));
  const actors = Object.entries(f.fake.snapshot()).filter(([path]) => path.includes('/activities/')).map(([, row]) => row.actorUid).sort();
  assert.deepEqual(actors, ['owner', 'staff']);
  assert.notEqual(result[0].body.itemId, result[1].body.itemId);
});

test('archive/restore wire deletion removes both fields and preserves stock/expiry', async () => {
  const f = fixture(), before = f.fake.snapshot()['cafes/cafe/inventory/item'];
  assert.equal((await f.call('/inventory/lifecycle', {...f.context, ...lifecycleData})).status, 200);
  assert.equal((await f.call('/inventory/lifecycle', {...f.context, ...lifecycleData,
    action: 'restore', expectedVersion: 2, idempotencyKey: 'restore-request-0001'})).status, 200);
  const after = f.fake.snapshot()['cafes/cafe/inventory/item'];
  assert.equal(Object.hasOwn(after, 'archivedAt'), false); assert.equal(Object.hasOwn(after, 'archivedBy'), false);
  assert.equal(after.quantity, before.quantity); assert.deepEqual(after.expiryDate, before.expiryDate);
  const write = commits(f)[1].body.writes.find(write => write.update.name.endsWith('/inventory/item'));
  assert.ok(write.updateMask.fieldPaths.includes('`archivedAt`')); assert.ok(write.updateMask.fieldPaths.includes('`archivedBy`'));
  assert.equal(Object.hasOwn(write.update.fields, 'archivedAt'), false);
});

test('stock insufficient reason and overflow retain exact definite public errors', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('/inventory/adjust-stock', {...f.context, ...stockData, direction: 'out', quantity: 6}),
    {status: 409, body: {error: 'failed-precondition', reason: 'insufficient-stock'}});
  const current = f.fake.snapshot()['cafes/cafe/inventory/item'];
  f.fake.replace('cafes/cafe/inventory/item', {...current, quantity: Number.MAX_SAFE_INTEGER});
  assert.deepEqual(await f.call('/inventory/adjust-stock', {...f.context, ...stockData}),
    {status: 409, body: {error: 'out-of-range'}});
  assert.equal(commits(f).length, 0);
});

test('metadata no-op and historical stock replay retain original versions/results', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('/inventory/update', {...f.context, ...updateData, name: 'Rice'}),
    {status: 200, body: {cafeId: 'cafe', itemId: 'item', updated: false, version: 1}});
  const original = await f.call('/inventory/adjust-stock', {...f.context, ...stockData});
  assert.equal(original.status, 200);
  await f.call('/inventory/adjust-stock', {...f.context, ...stockData, expectedVersion: 2,
    direction: 'out', quantity: 7, idempotencyKey: 'stock-request-0002'});
  assert.deepEqual(await f.call('/inventory/adjust-stock', {...f.context, ...stockData}),
    {status: 200, body: {...original.body, adjusted: false}});
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 0);
});

test('native contention rereads membership and exposes canonical stale response without second commit', async () => {
  const f = fixture(); let first = true;
  f.fake.hooks.commit = () => {
    if (!first) return;
    first = false;
    for (const path of ['user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
      f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 1});
    }
    return f.fake.nativeError(409, 'ABORTED');
  };
  assert.deepEqual(await f.call('/inventory/adjust-stock', {...f.context, ...stockData}),
    {status: 409, body: {error: 'aborted'}});
  assert.equal(commits(f).length, 1);
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 5);
});

for (const generation of [0, 7]) test(`all invitation routes retain response shapes at generation ${generation}`, async () => {
  const f = fixture({generation});
  const created = await invite(f);
  assert.equal(created.status, 200);
  assert.deepEqual(Object.keys(created.body).sort(), ['code', 'expiresAt', 'invitationId']);
  assert.match(created.body.code, /^[a-f0-9]{32}\.[a-f0-9]{64}$/);
  assert.equal(created.body.expiresAt, '2026-11-12T00:00:00.000Z');
  assert.equal(JSON.stringify(f.fake.snapshot()).includes(created.body.code), false);
  assert.deepEqual(await f.call('/staff/reconcile', {...f.context, requestId: invitationData.requestId}),
    {status: 200, body: {state: 'committed', invitationState: 'pending'}});
  assert.deepEqual(commits(f).at(-1).body.writes, []);
  // Recipient has no membership: no universal pre-route membership gate.
  assert.equal(f.fake.snapshot()['user_cafe_memberships/joiner'], undefined);
  assert.deepEqual(await f.call('/staff/redeem', {code: created.body.code}, {uid: 'joiner'}),
    {status: 200, body: {joined: true, cafeId: 'cafe'}});
  assert.deepEqual(await f.call('/staff/reconcile', {...f.context, requestId: invitationData.requestId}),
    {status: 200, body: {state: 'committed', invitationState: 'redeemed'}});
  const second = await f.call('/staff/create', {...f.context, ...invitationData, requestId: 'request_123456780'});
  assert.deepEqual(await f.call('/staff/revoke', {...f.context, invitationId: second.body.invitationId}),
    {status: 200, body: {revoked: true}});
  assert.deepEqual(await f.call('/staff/reconcile', {...f.context, requestId: 'request_123456780'}),
    {status: 200, body: {state: 'committed', invitationState: 'revoked'}});
});

test('Staff cannot issue/revoke/observe invitations or elevate through client flags', async () => {
  const f = fixture(), created = await invite(f);
  for (const [path, data] of [['create', {...f.context, ...invitationData}],
    ['revoke', {...f.context, invitationId: created.body.invitationId}],
    ['reconcile', {...f.context, requestId: invitationData.requestId}]]) {
    assert.deepEqual(await f.call('/staff/' + path, data, {uid: 'staff'}), {status: 403, body: {error: 'permission-denied'}});
  }
  for (const flag of ['allowRejoin', 'role', 'actorUid', 'targetGeneration']) {
    assert.deepEqual(await f.call('/staff/create', {...f.context, ...invitationData, [flag]: true}),
      {status: 400, body: {error: 'invalid-argument'}});
  }
});

test('invitation duplicate ID, issuer generation and absent receipt retain safe semantics', async () => {
  const f = fixture(); await invite(f);
  assert.deepEqual(await invite(f), {status: 409, body: {error: 'already-exists'}});
  assert.deepEqual(await f.call('/staff/reconcile', {...f.context, requestId: 'request_999999999'}),
    {status: 200, body: {state: 'unknown'}});
  for (const path of ['user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 1});
  }
  assert.deepEqual(await f.call('/staff/reconcile', {...f.context, requestId: invitationData.requestId}),
    {status: 409, body: {error: 'failed-precondition'}});
});

test('invitation expired observation is read-only; replayed revocation has identical shape', async () => {
  const f = fixture(), created = await invite(f);
  const path = `workspace_invitations/${created.body.invitationId}`;
  f.fake.replace(path, {...f.fake.snapshot()[path], expiresAt: new Date(initial + 1)});
  f.advance(2);
  assert.deepEqual(await f.call('/staff/reconcile', {...f.context, requestId: invitationData.requestId}),
    {status: 200, body: {state: 'committed', invitationState: 'expired'}});
  assert.deepEqual(commits(f).at(-1).body.writes, []);
  const data = {...f.context, invitationId: created.body.invitationId};
  for (let i = 0; i < 2; i++) assert.deepEqual(await f.call('/staff/revoke', data), {status: 200, body: {revoked: true}});
  assert.deepEqual(commits(f).at(-1).body.writes, []);
});

test('concurrent invitation redemption admits one membership and preserves atomic links', async () => {
  const f = fixture(), created = await invite(f);
  const results = await Promise.all([f.call('/staff/redeem', {code: created.body.code}, {uid: 'joiner'}),
    f.call('/staff/redeem', {code: created.body.code}, {uid: 'joiner'})]);
  assert.equal(results.filter(result => result.status === 200).length, 1);
  assert.equal(results.filter(result => result.status === 409).length, 1);
  const state = f.fake.snapshot();
  assert.equal(state['user_cafe_memberships/joiner'].cafeId, 'cafe');
  assert.equal(state['cafes/cafe/members/joiner'].role, 'staff');
  assert.equal(state[`workspace_invitations/${created.body.invitationId}`].redeemedBy, 'joiner');
});

for (const state of ['wrong-email', 'expired', 'revoked', 'existing-membership']) test(`invitation redeem rejects ${state}`, async () => {
  const f = fixture(), created = await invite(f), path = `workspace_invitations/${created.body.invitationId}`;
  let uid = 'joiner';
  if (state === 'wrong-email') uid = 'outsider';
  if (state === 'existing-membership') {
    const link = {uid: 'joiner', cafeId: 'other', status: 'inactive', schemaVersion: 1, membershipGeneration: 1};
    f.fake.replace('user_cafe_memberships/joiner', link);
  }
  if (state === 'expired') f.fake.replace(path, {...f.fake.snapshot()[path], expiresAt: new Date(initial - 1)});
  if (state === 'revoked') await f.call('/staff/revoke', {...f.context, invitationId: created.body.invitationId});
  const response = await f.call('/staff/redeem', {code: created.body.code}, {uid});
  assert.equal(response.status, {'wrong-email': 403, expired: 409, revoked: 409, 'existing-membership': 409}[state]);
  assert.notEqual(f.fake.snapshot()[path].status, 'redeemed');
});

test('native contention retry preserves invitation ID/code and leaves one issuance', async () => {
  const f = fixture(); f.fake.commitModes.push('abort');
  const response = await invite(f); assert.equal(response.status, 200);
  assert.equal(commits(f).length, 2);
  assert.deepEqual(commits(f)[0].body.writes, commits(f)[1].body.writes);
  assert.equal(Object.keys(f.fake.snapshot()).filter(path => path.startsWith('workspace_invitations/')).length, 1);
});

for (const route of ['inventory', 'invitation']) for (const mode of ['lost', 'applied-lost', 'malformed']) {
  test(`${route} ${mode} commit remains uncertain, no automatic retry or secret delivery`, async () => {
    const f = fixture(); f.fake.commitModes.push(mode);
    const response = route === 'inventory' ? await f.call('/inventory/adjust-stock', {...f.context, ...stockData}) : await invite(f);
    assert.deepEqual(response, {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
    assert.equal(commits(f).length, 1);
    if (route === 'invitation') {
      assert.deepEqual(await f.call('/staff/reconcile', {...f.context, requestId: invitationData.requestId}),
        {status: 200, body: mode === 'lost' ? {state: 'unknown'} : {state: 'committed', invitationState: 'pending'}});
      assert.deepEqual(commits(f).at(-1).body.writes, []);
    }
  });
}

for (const kind of ['missing', 'signature', 'project', 'issuer', 'expired', 'unverified', 'disabled', 'revoked']) {
  test(`identity ${kind} fails before Firestore dispatch`, async () => {
    const f = fixture(); let bearer = f.token();
    if (kind === 'missing') bearer = null;
    if (kind === 'signature') { const parts = bearer.split('.'); const sig = Buffer.from(parts[2], 'base64url'); sig[0] ^= 1; parts[2] = sig.toString('base64url'); bearer = parts.join('.'); }
    if (kind === 'project') bearer = f.token('owner', {aud: 'velora-73222'});
    if (kind === 'issuer') bearer = f.token('owner', {iss: 'https://evil.invalid'});
    if (kind === 'expired') bearer = f.token('owner', {exp: initial / 1000});
    if (kind === 'unverified') f.accounts.owner.emailVerified = false;
    if (kind === 'disabled') f.accounts.owner.disabled = true;
    if (kind === 'revoked') f.accounts.owner.validSince = String(initial / 1000 + 1);
    assert.deepEqual(await f.call('/inventory/create', {...f.context, ...createData}, {bearer}),
      {status: 401, body: {error: 'unauthenticated'}});
    assert.equal(f.fake.calls.length, 0);
  });
}

test('CORS preflight and denied origins do no identity lookup or transaction; native POST still requires auth', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('/inventory/create', undefined, {method: 'OPTIONS', bearer: null,
    headers: {'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization,content-type'}}),
    {status: 204, body: null});
  assert.equal((await f.call('/inventory/create', {}, {from: 'null'})).status, 403);
  assert.equal((await f.call('/inventory/create', {}, {from: 'https://evil.invalid'})).status, 403);
  assert.equal(f.wireCalls.length, 0);
  assert.deepEqual(await f.call('/inventory/create', {...f.context, ...createData}, {from: null, bearer: null}),
    {status: 401, body: {error: 'unauthenticated'}});
  assert.equal((await f.call('/inventory/create', {...f.context, ...createData}, {from: null})).status, 200);
});

test('body schema/size and fixed route isolation retain existing contracts', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('/inventory/create', {}, {raw: '{'}), {status: 400, body: {error: 'invalid-argument'}});
  assert.deepEqual(await f.call('/staff/create', {}, {raw: ' '.repeat(2049)}), {status: 413, body: {error: 'too-large'}});
  assert.deepEqual(await f.call('/inventory/create', {}, {raw: ' '.repeat(4097)}), {status: 413, body: {error: 'too-large'}});
  for (const path of ['/workspace/delete', '/staff/promote', '/menu/delete', '/ai/generate', '/inventory/reconcile/extra']) {
    assert.deepEqual(await f.call(path, {}), {status: 404, body: {error: 'not-found'}});
  }
  assert.equal(f.fake.calls.length, 0);
});

test('identity is rechecked after body consumption before transaction dispatch', async () => {
  const f = fixture(); let read = false;
  const body = JSON.stringify({...f.context, ...createData});
  const response = await f.app.fetch({url: publicOrigin + '/inventory/create', method: 'POST',
    headers: new Headers({origin, authorization: `Bearer ${f.token()}`, 'content-type': 'application/json'}),
    body: {getReader: () => ({read: async () => {
      if (!read) { read = true; return {value: new TextEncoder().encode(body), done: false}; }
      f.advance(3600000); return {done: true};
    }, cancel: async () => {}})}});
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {error: 'unavailable', outcomeUnknown: true});
  assert.equal(f.fake.calls.length, 0);
});

test('fresh account disablement at dispatch cannot reuse initial authentication', async () => {
  const f = fixture(); let lookups = 0;
  f.hooks.transport = url => {
    if (url.endsWith('accounts:lookup') && ++lookups === 2) f.accounts.owner.disabled = true;
  };
  assert.deepEqual(await f.call('/inventory/create', {...f.context, ...createData}),
    {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(lookups, 2); assert.equal(f.fake.calls.length, 0);
});

test('application admission holds pending commit and refuses overflow before identity work', async () => {
  const f = fixture({maxConcurrent: 1}); let release, entered;
  const gate = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  f.fake.hooks.commit = async () => { entered(); await gate; };
  const first = f.call('/inventory/create', {...f.context, ...createData}); await started;
  const requests = f.wireCalls.length;
  assert.deepEqual(await f.call('/inventory/create', {...f.context, ...createData}),
    {status: 429, body: {error: 'resource-exhausted'}});
  assert.equal(f.wireCalls.length, requests);
  assert.equal((await f.call('/staff/redeem', {}, {method: 'OPTIONS', bearer: null,
    headers: {'access-control-request-method': 'POST'}})).status, 204);
  release(); assert.equal((await first).status, 200);
  assert.equal((await f.call('/inventory/create', {...f.context, ...createData})).status, 200);
});

test('verification deadline cannot resume dispatch after late account completion', async () => {
  const f = fixture({verificationTimeoutMs: 15, identityTimeoutMs: 100, httpTimeoutMs: 100});
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  f.hooks.transport = async url => { if (url.endsWith('accounts:lookup')) await gate; };
  assert.deepEqual(await f.call('/inventory/create', {...f.context, ...createData}),
    {status: 408, body: {error: 'deadline-exceeded'}});
  release(); await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(f.fake.calls.length, 0);
});

for (const uid of ['owner', 'staff']) for (const generation of [0, 7]) for (const [operation, payload] of operations) {
  test(`shared-store observation ${uid} generation=${generation} ${operation} is historically bound and write-free`, async () => {
    const f = fixture({generation}), request = {...f.context, ...payload};
    const original = await f.call('/inventory/' + operation, request);
    assert.equal(original.status, 200);
    const before = f.fake.snapshot(), count = commits(f).length;
    assert.deepEqual(await f.call('/inventory/reconcile', {operation, request}),
      {status: 200, body: {state: 'committed', result: original.body}});
    assert.deepEqual(f.fake.snapshot(), before);
    assert.deepEqual(commits(f)[count].body.writes, []);
  });
}

test('reconcile preflight is explicit, unknown receipts remain unknown and no extra routes activate', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('/inventory/reconcile', undefined, {method: 'OPTIONS', bearer: null,
    headers: {'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization,content-type'}}),
    {status: 204, body: null});
  assert.equal(f.wireCalls.length, 0);
  const envelope = {operation: 'adjust-stock', request: {...f.context, ...stockData}};
  assert.deepEqual(await f.call('/inventory/reconcile', envelope), {status: 200, body: {state: 'unknown'}});
  assert.deepEqual(commits(f).at(-1).body.writes, []);
  assert.equal((await f.call('/inventory/reconcile', envelope, {bearer: null})).status, 401);
  assert.equal((await f.call('/inventory/reconcile', envelope, {from: 'null'})).status, 403);
  assert.equal((await f.call('/inventory/reconcile', {...envelope, receiptPath: 'arbitrary'})).status, 400);
  assert.equal((await f.call('/inventory/reconcile', envelope, {uid: 'outsider'})).status, 403);
});

test('lost mutation acknowledgement is observed without reissuing mutation or exposing current stock', async () => {
  const f = fixture(), request = {...f.context, ...stockData}; f.fake.commitModes.push('applied-lost');
  assert.deepEqual(await f.call('/inventory/adjust-stock', request),
    {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 1);
  await f.call('/inventory/adjust-stock', {...request, expectedVersion: 2, quantity: 7,
    direction: 'out', idempotencyKey: 'stock-request-0002'});
  const before = f.fake.snapshot();
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'adjust-stock', request}),
    {status: 200, body: {state: 'committed', result: {cafeId: 'cafe', itemId: 'item', direction: 'in',
      quantity: 2, resultingQuantity: 7, version: 2, adjusted: true}}});
  assert.equal(f.fake.snapshot()['cafes/cafe/inventory/item'].quantity, 0);
  assert.deepEqual(f.fake.snapshot(), before); assert.deepEqual(commits(f).at(-1).body.writes, []);
});

test('observer denies wrong original workspace/generation and invalid signature before disclosure', async () => {
  const f = fixture({generation: 7}), request = {...f.context, ...stockData};
  await f.call('/inventory/adjust-stock', request);
  for (const changed of [{expectedCafeId: 'other'}, {expectedMembershipGeneration: 0}]) {
    assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'adjust-stock', request: {...request, ...changed}}),
      {status: 409, body: {error: 'aborted'}});
  }
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'adjust-stock', request}, {uid: 'staff'}),
    {status: 200, body: {state: 'unknown'}});
  assert.deepEqual(await f.call('/inventory/reconcile', {operation: 'adjust-stock', request}, {bearer: 'forged'}),
    {status: 401, body: {error: 'unauthenticated'}});
});

const setupData = {businessName: 'New bakery', businessType: 'bakery', address: 'Test street', inventoryUnit: 'kg',
  lowStockAlerts: true, expiryReminders: true, reminderDays: 3};
const removeData = {targetUid: 'staff', expectedCafeId: 'cafe', expectedActorGeneration: 0,
  expectedGeneration: 0, idempotencyKey: 'remove-request-0001'};

test('new workspace route uses fresh signed identity without requiring membership', async () => {
  let ids = 0;
  const f = fixture({workspaceIdFactory: () => { ids++; return 'new-bakery'; }});
  f.fake.commitModes.push('abort');
  assert.deepEqual(await f.call('/workspace/create', setupData, {uid: 'outsider'}),
    {status: 200, body: {cafeId: 'new-bakery', created: true}});
  assert.equal(ids, 1);
  assert.equal(f.fake.snapshot()['cafes/new-bakery'].ownerUid, 'outsider');
  assert.deepEqual(commits(f)[0].body.writes, commits(f)[1].body.writes);
  assert.deepEqual(await f.call('/workspace/create', setupData, {uid: 'outsider'}),
    {status: 200, body: {cafeId: 'new-bakery', created: false}});
  assert.equal((await f.call('/workspace/create', setupData, {uid: 'staff'})).status, 409);
  assert.equal((await f.call('/workspace/create', {...setupData, ownerUid: 'owner'}, {uid: 'joiner'})).status, 400);
});

for (const path of ['/workspace/create', '/staff/list', '/staff/remove']) {
  test(`new route ${path} has exact-origin preflight and requires verified identity`, async () => {
    const f = fixture();
    assert.equal((await f.call(path, {}, {method: 'OPTIONS', bearer: null,
      headers: {'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization,content-type'}})).status, 204);
    assert.equal(f.wireCalls.length, 0);
    assert.equal((await f.call(path, {}, {bearer: null})).status, 401);
    assert.equal((await f.call(path, {}, {from: 'null'})).status, 403);
    assert.equal((await f.call(path, {}, {bearer: f.token('owner', {aud: 'velora-73222'})})).status, 401);
    assert.equal(f.fake.calls.length, 0);
  });
}

test('Owner roster versus Staff visibility uses fresh bounded account directory and revalidation', async () => {
  const f = fixture(), created = await invite(f);
  await f.call('/staff/redeem', {code: created.body.code}, {uid: 'joiner'});
  const before = f.fake.snapshot();
  const owner = await f.call('/staff/list', {}), staff = await f.call('/staff/list', {}, {uid: 'staff'});
  assert.equal(owner.status, 200); assert.equal(owner.body.members.length, 3);
  assert.deepEqual(staff.body.members.map(member => member.uid), ['owner', 'staff']);
  assert.equal(JSON.stringify(owner.body).includes('validSince'), false);
  assert.deepEqual(f.fake.snapshot(), before);
  assert.equal((await f.call('/staff/list', {}, {uid: 'outsider'})).status, 403);
  assert.equal((await f.call('/staff/list', {targetUid: 'outsider'})).status, 400);
});

test('fresh account disablement blocks removal before any Firestore mutation', async () => {
  const f = fixture(); let lookups = 0;
  f.hooks.transport = url => { if (url.endsWith('accounts:lookup') && ++lookups === 2) f.accounts.owner.disabled = true; };
  assert.deepEqual(await f.call('/staff/remove', removeData),
    {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 0);
  assert.equal(f.fake.snapshot()['user_cafe_memberships/staff'].status, 'active');
});

test('default composition performs no email lookup and does not enable rejoin', async () => {
  const f = fixture();
  await f.call('/staff/remove', removeData);
  const created = await f.call('/staff/create', {...f.context, email: 'staff@example.test', requestId: 'rejoin_request_0001'});
  assert.equal(created.status, 200);
  const stored = f.fake.snapshot()[`workspace_invitations/${created.body.invitationId}`];
  assert.equal(stored.bindingVersion, undefined);
  assert.equal(f.wireCalls.some(call => call.url.endsWith('accounts:lookup') && JSON.parse(call.body).email), false);
  assert.deepEqual(await f.call('/staff/redeem', {code: created.body.code}, {uid: 'staff'}),
    {status: 409, body: {error: 'already-exists'}});
  assert.equal(f.fake.snapshot()['user_cafe_memberships/staff'].status, 'inactive');
});

test('offline trusted rejoin uses independent issuer/target bindings and replaces only proven tombstones', async () => {
  const f = fixture({generation: 7, allowInvitationRejoin: true});
  for (const path of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 3});
  }
  const request = {...removeData, expectedActorGeneration: 7, expectedGeneration: 3};
  const removed = await f.call('/staff/remove', request); assert.equal(removed.status, 200);
  assert.equal(removed.body.resultGeneration, 4);
  const removalEvent = f.fake.snapshot()[`cafes/cafe/membership_events/${removed.body.eventId}`];
  const created = await f.call('/staff/create', {...f.context, email: 'staff@example.test', requestId: 'rejoin_request_0001'});
  assert.equal(created.status, 200);
  const invitation = f.fake.snapshot()[`workspace_invitations/${created.body.invitationId}`];
  assert.equal(invitation.issuerMembershipGeneration, 7); assert.equal(invitation.targetGeneration, 4);
  assert.equal(invitation.targetUid, 'staff'); assert.equal(invitation.bindingVersion, 1);
  assert.deepEqual(Object.keys(created.body).sort(), ['code', 'expiresAt', 'invitationId']);
  assert.deepEqual(await f.call('/staff/redeem', {code: created.body.code}, {uid: 'staff'}),
    {status: 200, body: {joined: true, cafeId: 'cafe', generation: 5}});
  const before = f.fake.snapshot();
  assert.equal(before['user_cafe_memberships/staff'].status, 'active');
  assert.equal(Object.hasOwn(before['user_cafe_memberships/staff'], 'removedAt'), false);
  assert.deepEqual(before[`cafes/cafe/membership_events/${removed.body.eventId}`], removalEvent);
  assert.deepEqual(await f.call('/staff/remove', request), {status: 200, body: {...removed.body, changed: false}});
  assert.deepEqual(f.fake.snapshot(), before);
  const rejoinWrite = commits(f).find(call => call.body.writes.some(write => write.update?.name.includes('/membership_events/rejoin_')));
  for (const path of ['/user_cafe_memberships/staff', '/cafes/cafe/members/staff']) {
    const write = rejoinWrite.body.writes.find(write => write.update?.name.endsWith(path));
    assert.ok(write); assert.equal(write.updateMask, undefined);
  }
  assert.equal((await f.call('/staff/remove', {...request, expectedActorGeneration: 5,
    expectedGeneration: 7, idempotencyKey: 'remove-request-0002'})).status, 409);
});

test('old removal replay racing with rejoin cannot deactivate the later episode', async () => {
  const f = fixture({allowInvitationRejoin: true});
  const removed = await f.call('/staff/remove', removeData);
  const created = await f.call('/staff/create', {...f.context, email: 'staff@example.test', requestId: 'rejoin_request_0001'});
  const results = await Promise.all([f.call('/staff/remove', removeData),
    f.call('/staff/redeem', {code: created.body.code}, {uid: 'staff'})]);
  assert.deepEqual(results[0], {status: 200, body: {...removed.body, changed: false}});
  assert.deepEqual(results[1], {status: 200, body: {joined: true, cafeId: 'cafe', generation: 2}});
  assert.equal(f.fake.snapshot()['user_cafe_memberships/staff'].membershipGeneration, 2);
  assert.equal(f.fake.snapshot()['user_cafe_memberships/staff'].status, 'active');
});

test('issuer change invalidates a bound invitation while current Owner can still revoke it', async () => {
  const f = fixture({allowInvitationRejoin: true}); await f.call('/staff/remove', removeData);
  const created = await f.call('/staff/create', {...f.context, email: 'staff@example.test', requestId: 'rejoin_request_0001'});
  for (const path of ['user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 7});
  }
  assert.deepEqual(await f.call('/staff/redeem', {code: created.body.code}, {uid: 'staff'}),
    {status: 403, body: {error: 'permission-denied'}});
  assert.deepEqual(await f.call('/staff/revoke', {...f.context, expectedMembershipGeneration: 7, invitationId: created.body.invitationId}),
    {status: 200, body: {revoked: true}});
  assert.equal(f.fake.snapshot()['user_cafe_memberships/staff'].status, 'inactive');
});

test('target changed after invitation binding cannot be replaced by stale rejoin evidence', async () => {
  const f = fixture({allowInvitationRejoin: true}); await f.call('/staff/remove', removeData);
  const created = await f.call('/staff/create', {...f.context, email: 'staff@example.test', requestId: 'rejoin_request_0001'});
  for (const path of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], status: 'active', membershipGeneration: 2});
  }
  assert.equal((await f.call('/staff/redeem', {code: created.body.code}, {uid: 'staff'})).status, 409);
  assert.equal(f.fake.snapshot()['user_cafe_memberships/staff'].membershipGeneration, 2);
});

test('private account lookup failures disclose no raw response or credentials', async () => {
  const f = fixture({allowInvitationRejoin: true});
  f.hooks.transport = (url, options) => {
    if (url.endsWith('accounts:lookup') && JSON.parse(options.body).email) return Response.json({users: [{localId: 'SECRET'}, {localId: 'other'}]});
  };
  assert.deepEqual(await f.call('/staff/create', {...f.context, email: 'staff@example.test', requestId: 'rejoin_request_0001'}),
    {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 0);
  assert.equal((await f.call('/staff/accounts', {})).status, 404);
  assert.equal((await f.call('/staff/create', {...f.context, ...invitationData, allowRejoin: true})).status, 400);
});
