'use strict';

// Structural checks only. No Firebase SDK, Rules evaluation or dispatch.
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {readFileSync} = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const matrix = require('./fixtures/firestore-policy-matrix.json');

const rulesPath = 'docs/firebase/workspace.firestore.rules';
const rules = readFileSync(path.resolve(__dirname, '../..', rulesPath), 'utf8')
  .replace(/\r\n/g, '\n');
const lines = rules.split('\n');
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const syntheticId = /^synthetic-[a-z0-9-]+$/;
const operations = ['get', 'list', 'create', 'update', 'delete', 'batch_create'];

function checkPath(value, collection = false) {
  assert.equal(typeof value, 'string');
  const segments = value.split('/');
  assert.equal(segments.length % 2, collection ? 1 : 0, value);
  assert.ok(segments.every((segment, index) => (index % 2 === 0
    ? /^[a-z_]+$/.test(segment) : syntheticId.test(segment))), value);
}

function checkDocument(key, data) {
  checkPath(key);
  assert.ok(record(data), key);
  const [collection, id, subcollection, member] = key.split('/');
  if (collection === 'user_cafe_memberships') {
    assert.equal(data.uid, id);
    assert.match(data.cafeId, syntheticId);
  } else if (subcollection === 'members') {
    assert.equal(data.uid, member);
    assert.equal(data.cafeId, id);
    assert.ok(['owner', 'staff'].includes(data.role), key);
  } else if (collection === 'cafes' && !subcollection) {
    assert.match(data.ownerUid, syntheticId);
  }
}

test('matrix is bound to the reviewed canonical Rules', () => {
  assert.equal(matrix.schemaVersion, 1);
  assert.deepEqual(matrix.baseline, {
    projectId: 'velora-73222',
    commit: '6e679c9c67efa7050732cc635b722cb86cad545d',
    rulesPath,
    hashEncoding: 'UTF-8 with LF line endings',
    rulesSha256: '73844e2174c028696bf5b36f22fbc2a6e2a3f6849ad9848913135e393d173611',
  });
  assert.equal(createHash('sha256').update(rules, 'utf8').digest('hex'), matrix.baseline.rulesSha256);
});

test('matrix case IDs are unique and fixtures are synthetic documents', () => {
  assert.ok(matrix.cases.length > 0);
  const ids = matrix.cases.map(entry => entry.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const fixture of Object.values(matrix.fixtures)) {
    for (const [key, data] of Object.entries(fixture)) checkDocument(key, data);
  }
});

for (const entry of matrix.cases) {
  test(`structure: ${entry.id}`, () => {
    assert.match(entry.id, /^[a-z0-9]+(?:-[a-z0-9]+)*$/);
    for (const field of ['description', 'predicate', 'source', 'fixtureDependencyNotes']) {
      assert.equal(typeof entry[field], 'string', field);
      assert.ok(entry[field].trim(), field);
    }
    assert.ok(operations.includes(entry.operation));
    assert.ok(['ALLOW', 'DENY'].includes(entry.expected));
    checkPath(entry.path, entry.operation === 'list');
    if (entry.auth !== null) {
      assert.match(entry.auth.uid, syntheticId);
      assert.ok(record(entry.auth.token));
      assert.ok(Object.keys(entry.auth.token).every(key => key === 'email_verified'));
    }
    const [file, line] = entry.source.split(':');
    assert.equal(file, rulesPath);
    const reference = lines[Number(line) - 1];
    assert.ok(reference, entry.source);
    const predicate = entry.predicate === 'default deny' ? 'match /{document=**}' : entry.predicate;
    assert.ok(reference.includes(predicate), entry.source);

    const {fixture, replace = {}, omit = [], absent = []} = entry.prerequisites;
    assert.ok(Object.hasOwn(matrix.fixtures, fixture));
    const documents = {...matrix.fixtures[fixture]};
    for (const [key, data] of Object.entries(replace)) {
      assert.ok(Object.hasOwn(documents, key), key);
      checkDocument(key, data);
      documents[key] = data;
    }
    for (const key of omit) {
      assert.ok(Object.hasOwn(documents, key) && !Object.hasOwn(replace, key), key);
      delete documents[key];
    }
    for (const key of absent) {
      checkPath(key);
      assert.ok(!Object.hasOwn(documents, key), key);
    }

    if (entry.operation === 'batch_create') {
      const uid = entry.auth.uid;
      const cafeId = entry.path.split('/')[1];
      const companionPaths = [entry.path, `${entry.path}/members/${uid}`, `user_cafe_memberships/${uid}`];
      assert.deepEqual(absent, companionPaths);
      const writePaths = entry.writes.map(write => write.path);
      assert.equal(new Set(writePaths).size, writePaths.length);
      assert.ok(writePaths.includes(entry.path));
      for (const write of entry.writes) {
        assert.ok(companionPaths.includes(write.path));
        assert.equal(write.operation, 'create');
        checkDocument(write.path, write.data);
        assert.equal(write.data.createdAt, 'REQUEST_TIME');
        assert.equal(write.data.updatedAt, 'REQUEST_TIME');
        assert.equal(write.data.status, 'active');
        assert.equal(write.data.schemaVersion, 1);
        assert.ok(!Object.hasOwn(write.data, 'membershipGeneration'));
        if (write.path === entry.path) assert.equal(write.data.ownerUid, uid);
        else assert.equal(write.data.cafeId, cafeId);
      }
    } else if (entry.operation === 'list') {
      assert.ok(Object.keys(documents).some(key => key.startsWith(`${entry.path}/`)));
    } else {
      assert.equal(Object.hasOwn(documents, entry.path), entry.operation !== 'create');
      if (['create', 'update'].includes(entry.operation)) assert.ok(record(entry.writeData));
      else assert.ok(!Object.hasOwn(entry, 'writeData'));
    }
  });
}
