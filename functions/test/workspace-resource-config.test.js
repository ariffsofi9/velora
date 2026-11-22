'use strict';

const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {createRequire, isBuiltin, registerHooks} = require('node:module');
const path = require('node:path');
const {fileURLToPath} = require('node:url');
const vm = require('node:vm');
const {test} = require('node:test');

function declarations({firestore, captureHandlers = false, log = console.error} = {}) {
  const filename = path.resolve(__dirname, '../src/index.js');
  const localRequire = createRequire(filename);
  const https = localRequire('firebase-functions/v2/https');
  const options = new Map();
  const exports = {};
  const unexpectedAdmin = () => { throw new Error('Admin access forbidden in config test'); };
  vm.runInNewContext(readFileSync(filename, 'utf8'), {
    exports,
    require(name) {
      if (name === 'firebase-admin/app') return {initializeApp() {}};
      if (name === 'firebase-admin/auth') return {getAuth: unexpectedAdmin};
      if (name === 'firebase-admin/firestore') {
        return {getFirestore: () => firestore ?? new Proxy({}, {get: unexpectedAdmin}),
          FieldValue: {}, Timestamp: {}, FieldPath: {}};
      }
      if (name === 'firebase-functions/v2/https') {
        return {...https, onCall(config, handler) {
          // The default path checks installed SDK metadata. Handler tests only
          // capture the application callback and never invoke the SDK wrapper.
          const callable = captureHandlers ? handler : https.onCall(config, handler);
          options.set(callable, JSON.parse(JSON.stringify(config)));
          return callable;
        }};
      }
      return localRequire(name);
    },
    console: {error: log},
  }, {filename});
  return {exports, options};
}

test('independent REST composition loads only its runtime and shared domain modules', async t => {
  const functionsRoot = path.resolve(__dirname, '..');
  const resolvedFiles = new Set();
  const forbidden = [];
  const denyIo = t.mock.method(globalThis, 'fetch', () => assert.fail('Unexpected network access'));
  const hooks = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (isBuiltin(specifier)) return nextResolve(specifier, context);
      const resolved = nextResolve(specifier, context);
      const relative = resolved.url.startsWith('file:')
        ? path.relative(functionsRoot, fileURLToPath(resolved.url)).replaceAll(path.sep, '/')
        : resolved.url;
      // Keep SDKs, the legacy entry point and feasibility controllers out of
      // the actual transitive module graph, including CommonJS dependencies.
      if (relative === 'src/index.js' ||
          !/^(?:(?:runtime|backend|https|src)\/[^/]+\.(?:js|mjs)|ai1\/recipe-service\.js)$/.test(relative)) {
        forbidden.push(relative);
        assert.fail(`Unexpected REST runtime dependency: ${relative}`);
      }
      resolvedFiles.add(relative);
      return resolved;
    },
  });
  try {
    const {startCloudRun} = await import('../runtime/cloud-run-entry.mjs');
    const {createApplication} = await import('../backend/application.mjs');
    const denyDependency = t.mock.fn(() => assert.fail('Unexpected REST dependency access'));
    const projectId = 'velora-spark-test';
    const origin = 'https://velora.test.invalid';
    const app = createApplication({projectId, publicOrigin: origin, allowedOrigins: [origin],
      transport: denyDependency, accessToken: Object.assign(denyDependency, {projectId})});
    assert.equal(typeof startCloudRun, 'function');
    assert.equal(app.projectId, projectId);
    assert.equal(typeof app.fetch, 'function');
    for (const module of ['runtime/node-entry.mjs', 'backend/application.mjs',
      'src/inventory-stock.js', 'src/mutation-episode.js', 'ai1/recipe-service.js']) {
      assert.ok(resolvedFiles.has(module), `Missing verified module: ${module}`);
    }
    assert.deepEqual(forbidden, []);
    assert.equal(denyDependency.mock.callCount(), 0);
    assert.equal(denyIo.mock.callCount(), 0);
  } finally {
    hooks.deregister();
  }
});

test('createWorkspace resource limits are accepted by installed SDK metadata', () => {
  const {exports, options} = declarations();
  assert.deepEqual(options.get(exports.createWorkspace), {
    region: 'asia-southeast1', memory: '256MiB', cpu: 1,
    timeoutSeconds: 30, minInstances: 0, maxInstances: 1, concurrency: 1,
  });
  const endpoint = exports.createWorkspace.__endpoint;
  assert.deepEqual(endpoint.region, ['asia-southeast1']);
  assert.equal(endpoint.availableMemoryMb, 256);
  for (const [field, expected] of Object.entries({cpu: 1, timeoutSeconds: 30,
    minInstances: 0, maxInstances: 1, concurrency: 1})) {
    assert.equal(endpoint[field], expected, field);
  }
  assert.ok(endpoint.callableTrigger);
});

test('other callable declarations retain their existing region and timeout only', () => {
  const {exports, options} = declarations();
  const others = Object.entries(exports).filter(([name]) => name !== 'createWorkspace');
  assert.ok(others.length > 0);
  for (const [name, callable] of others) {
    assert.deepEqual(options.get(callable), {
      region: 'asia-southeast1', timeoutSeconds: 30,
    }, name);
  }
});

const auth = {uid: 'owner-a', token: {email_verified: true}};
const inventoryData = {expectedCafeId: 'cafe-a', expectedMembershipGeneration: 0,
  idempotencyKey: 'synthetic-key-0001'};
const existingItem = {...inventoryData, itemId: 'item-a', expectedVersion: 1};
const stockData = {...existingItem, direction: 'out', quantity: 3};
const operations = {
  createWorkspace: [{businessName: 'Example Café', businessType: 'cafe'}, 'Workspace creation failed.'],
  createInventoryItem: [{...inventoryData, name: 'Flour', category: 'Dry Goods', quantity: 4,
    unit: 'kg', expiryDate: '2030-01-02T00:00:00.000Z'}, 'Inventory creation failed.'],
  updateInventoryItem: [{...existingItem, name: 'Flour'}, 'Inventory update failed.'],
  adjustInventoryStock: [stockData, 'Stock adjustment failed.'],
  setInventoryLifecycle: [{...existingItem, action: 'archive'}, 'Inventory lifecycle update failed.'],
};

function callableFixture({failure, documents = new Map()} = {}) {
  const logs = [];
  let transactions = 0;
  const {exports} = declarations({captureHandlers: true, log: (...args) => logs.push(args), firestore: {
    collection(name) {
      assert.equal(name, 'cafes');
      return {doc: () => ({id: 'cafe-a'})};
    },
    doc: name => name,
    async runTransaction(operation) {
      transactions++;
      if (failure) throw failure;
      return operation({async get(name) {
        return {exists: documents.has(name), data: () => documents.get(name)};
      }});
    },
  }});
  return {exports, logs, get transactions() { return transactions; }};
}

async function assertCallableError(promise, expected) {
  await assert.rejects(promise, error => {
    assert.equal(error.code, expected.code);
    assert.deepEqual(JSON.parse(JSON.stringify(error.toJSON())), expected.response);
    return true;
  });
}

for (const [name, [data, message]] of Object.entries(operations)) {
  test(`${name} emits a fixed event and generic response for an unexpected failure`, async () => {
    const failure = Object.assign(new Error(`message-${name}`,
      {cause: new Error(`cause-${name}`)}), {
      stack: `stack-${name}`, request: {headers: {authorization: `token-${name}`},
        data: {private: `payload-${name}`}},
    });
    const fixture = callableFixture({failure});
    await assertCallableError(fixture.exports[name]({auth, data}), {
      code: 'internal', response: {status: 'INTERNAL', message},
    });
    assert.equal(fixture.transactions, 1);
    // Exact primitive arguments rule out the exception and all sentinel fields.
    assert.deepEqual(fixture.logs, [['callable-failure', name, 'unexpected']]);
  });

  test(`${name} rejects unknown fields without reflecting the field name`, async () => {
    const fixture = callableFixture();
    const unknownField = `private-${name}\nfield`;
    await assertCallableError(fixture.exports[name]({auth, data: {...data, [unknownField]: true}}), {
      code: 'invalid-argument',
      response: {status: 'INVALID_ARGUMENT', message: 'Request contains an unsupported field.'},
    });
    assert.equal(fixture.transactions, 0);
    assert.deepEqual(fixture.logs, []);
  });
}

test('callable admission and safe typed validation messages are preserved', async () => {
  const fixture = callableFixture();
  for (const [name, [data]] of Object.entries(operations)) {
    await assertCallableError(fixture.exports[name]({data}), {code: 'unauthenticated',
      response: {status: 'UNAUTHENTICATED', message: 'Authentication is required.'}});
  }
  await assertCallableError(fixture.exports.createWorkspace({auth: {uid: auth.uid},
    data: operations.createWorkspace[0]}), {code: 'failed-precondition', response: {
    status: 'FAILED_PRECONDITION', message: 'Verify your email and refresh your sign-in before creating a workspace.',
  }});
  const validation = {
    createWorkspace: [{businessType: 'invalid'}, 'Unsupported business type.'],
    createInventoryItem: [{quantity: -1}, 'Quantity must be a non-negative integer.'],
    updateInventoryItem: [{unit: 'invalid'}, 'Unsupported inventory unit.'],
    adjustInventoryStock: [{quantity: 0}, 'Quantity must be a positive safe integer.'],
    setInventoryLifecycle: [{action: 'invalid'}, 'Invalid action.'],
  };
  for (const [name, [fields, message]] of Object.entries(validation)) {
    await assertCallableError(fixture.exports[name]({auth, data: {...operations[name][0], ...fields}}), {
      code: 'invalid-argument', response: {status: 'INVALID_ARGUMENT', message},
    });
  }
  assert.equal(fixture.transactions, 0);
  assert.deepEqual(fixture.logs, []);
});

test('inventory callables still deny access without an active membership', async () => {
  const fixture = callableFixture();
  for (const name of ['createInventoryItem', 'updateInventoryItem', 'adjustInventoryStock', 'setInventoryLifecycle']) {
    await assertCallableError(fixture.exports[name]({auth, data: operations[name][0]}), {code: 'permission-denied',
      response: {status: 'PERMISSION_DENIED', message: 'An active workspace membership is required.'}});
  }
  assert.equal(fixture.transactions, 4);
  assert.deepEqual(fixture.logs, []);
});

test('stock callable preserves the typed insufficient-stock detail', async () => {
  const link = {uid: auth.uid, cafeId: 'cafe-a', status: 'active', schemaVersion: 1};
  const fixture = callableFixture({documents: new Map([
    ['user_cafe_memberships/owner-a', link],
    ['cafes/cafe-a', {ownerUid: auth.uid, status: 'active', schemaVersion: 1}],
    ['cafes/cafe-a/members/owner-a', {...link, role: 'owner'}],
    ['cafes/cafe-a/inventory/item-a', {quantity: 1, unit: 'kg', version: 1}],
  ])});
  await assertCallableError(fixture.exports.adjustInventoryStock({auth, data: stockData}), {
    code: 'failed-precondition', response: {status: 'FAILED_PRECONDITION',
      message: 'Stock out quantity exceeds available stock.', details: {reason: 'insufficient-stock'}},
  });
  assert.equal(fixture.transactions, 1);
  assert.deepEqual(fixture.logs, []);
});
