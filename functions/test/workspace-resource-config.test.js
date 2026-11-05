'use strict';

const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {createRequire} = require('node:module');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');

// Evaluate declarations with the installed Functions SDK, without initializing
// Admin or invoking any handler. All Admin imports are replaced and fail closed.
function declarations() {
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
        return {getFirestore: () => new Proxy({}, {get: unexpectedAdmin}),
          FieldValue: {}, Timestamp: {}, FieldPath: {}};
      }
      if (name === 'firebase-functions/v2/https') {
        return {...https, onCall(config, handler) {
          const callable = https.onCall(config, handler);
          options.set(callable, JSON.parse(JSON.stringify(config)));
          return callable;
        }};
      }
      return localRequire(name);
    },
    console,
  }, {filename});
  return {exports, options};
}

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
