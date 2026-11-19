'use strict';

// Validate the design against local source and fixtures only.
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {readFileSync} = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const matrix = require('./fixtures/firestore-policy-matrix.json');
const design = require('./fixtures/firestore-policy-payload-design.json');

const selectedCases = {
  'owner-verified-get': ['typed-claims', 'member-get-mocks'],
  'staff-verified-get': ['typed-claims', 'member-get-mocks'],
  'owner-missing-claim': ['omitted-claim'],
  'owner-malformed-claim': ['typed-claims'],
  'staff-revoked-mapping': ['typed-claims', 'member-get-mocks'],
  'owner-inventory-update': ['typed-claims', 'update-context'],
};
const prefix = '/databases/(default)/documents/';

test('design selects six distinct matrix cases and binds to the canonical LF Rules hash', () => {
  assert.equal(design.schemaVersion, 1);
  assert.deepEqual(design.baseline, matrix.baseline);
  const rules = readFileSync(path.resolve(__dirname, '../..', design.baseline.rulesPath), 'utf8')
    .replace(/\r\n/g, '\n');
  assert.equal(createHash('sha256').update(rules).digest('hex'), design.baseline.rulesSha256);
  assert.deepEqual(design.cases.map(entry => entry.matrixId), Object.keys(selectedCases));
  assert.ok(!Object.hasOwn(design, 'endpoint'));
  assert.ok(!Object.hasOwn(design, 'testSuite'));
});

test('boolean, string, explicit null and omitted claims remain distinct', () => {
  assert.deepEqual(design.claimVariants, {
    booleanTrue: {email_verified: true},
    stringTrue: {email_verified: 'true'},
    explicitNull: {email_verified: null},
    omitted: {},
  });
  const claimFor = id => design.cases.find(entry => entry.matrixId === id)
    .candidateTestCase.request.auth.token;
  assert.deepEqual(claimFor('owner-verified-get'), design.claimVariants.booleanTrue);
  assert.deepEqual(claimFor('owner-malformed-claim'), design.claimVariants.stringTrue);
  assert.deepEqual(claimFor('owner-missing-claim'), design.claimVariants.omitted);
});

for (const entry of design.cases) {
  test(`payload structure: ${entry.matrixId}`, () => {
    const row = matrix.cases.find(candidate => candidate.id === entry.matrixId);
    assert.ok(row);
    assert.equal(entry.classification, 'Conditional on API semantics');
    assert.deepEqual(entry.unresolved, [...selectedCases[row.id], 'isolation']);
    for (const assumption of entry.unresolved) {
      assert.equal(typeof design.unresolved[assumption], 'string');
      assert.ok(design.unresolved[assumption].trim());
    }
    assert.deepEqual(entry.rules, {source: row.source, predicate: row.predicate});

    const {fixture, replace, omit = [], absent = []} = row.prerequisites;
    const documents = {...matrix.fixtures[fixture], ...replace};
    for (const key of omit) delete documents[key];
    assert.deepEqual(entry.missingDocuments, [...omit, ...absent]);
    for (const key of entry.missingDocuments) assert.ok(!Object.hasOwn(documents, key));

    const targetData = documents[row.path];
    assert.ok(targetData);
    const request = {auth: row.auth, path: prefix + row.path, method: row.operation};
    if (row.operation === 'update') request.resource = {data: {...targetData, ...row.writeData}};

    const {functionMocks} = entry.candidateTestCase;
    const mockPaths = functionMocks.map(mock => mock.args[0].exactValue);
    assert.equal(new Set(mockPaths).size, mockPaths.length);
    const requiredPaths = new Set();
    if (selectedCases[row.id].includes('member-get-mocks')) {
      const cafe = row.path.split('/').slice(0, 2).join('/');
      requiredPaths.add(cafe);
      for (const uid of [row.auth.uid, documents[cafe].ownerUid]) {
        requiredPaths.add(`user_cafe_memberships/${uid}`);
        requiredPaths.add(`${cafe}/members/${uid}`);
      }
    }
    assert.deepEqual(new Set(entry.existingDocuments), new Set([row.path, ...requiredPaths]));
    assert.equal(entry.existingDocuments.length, requiredPaths.size + 1);
    assert.deepEqual(new Set(mockPaths), new Set([...requiredPaths].map(key => prefix + key)));
    for (const key of requiredPaths) assert.ok(Object.hasOwn(documents, key), key);

    assert.deepEqual(entry.candidateTestCase, {
      expectation: row.expected,
      request,
      resource: {data: targetData},
      functionMocks: functionMocks.map((_, index) => ({
        function: 'get',
        args: [{exactValue: mockPaths[index]}],
        result: {value: {data: documents[mockPaths[index].slice(prefix.length)]}},
      })),
    });
  });
}
