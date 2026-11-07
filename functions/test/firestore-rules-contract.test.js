'use strict';

// Source-contract checks only. No Firebase SDK, network, Rules compiler or
// emulator is invoked; passing these does not establish Rules runtime behavior.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createHash} = require('node:crypto');
const rules = fs.readFileSync(path.resolve(__dirname,
  '../../docs/firebase/workspace.firestore.rules'), 'utf8').replace(/\r/g, '');
const compact = value => value.replace(/\s+/g, ' ').trim();
const between = (start, end) => {
  assert.ok(rules.includes(start) && rules.includes(end));
  return rules.slice(rules.indexOf(start), rules.indexOf(end));
};

test('default regression explicitly includes offline generation and Rules contract tests', () => {
  const script = require('../package.json').scripts.test;
  assert.ok(script.startsWith('node --test '));
  assert.ok(script.split(' ').includes('test/membership-generation.test.js'));
  assert.ok(script.split(' ').includes('test/firestore-rules-contract.test.js'));
  assert.ok(!script.includes('test/firestore.rules.test.js'));
  assert.ok(!script.includes('emulators'));
});

test('Rules source requires both absent fields or both matching bounded integer fields', () => {
  const source = between('    function matchingGeneration(', '    function member(');
  assert.equal(compact(source), compact(`
    function matchingGeneration(mapping, membership) {
      return (!('membershipGeneration' in mapping) &&
              !('membershipGeneration' in membership)) ||
        (('membershipGeneration' in mapping) &&
         ('membershipGeneration' in membership) &&
         mapping.membershipGeneration is int &&
         membership.membershipGeneration is int &&
         mapping.membershipGeneration >= 0 &&
         mapping.membershipGeneration <= 9007199254740991 &&
         membership.membershipGeneration >= 0 &&
         membership.membershipGeneration <= 9007199254740991 &&
         mapping.membershipGeneration == membership.membershipGeneration);
    }`));
});

test('generation checks are conjunctive with existing caller and owner authorization', () => {
  const member = compact(between('    function member(', '    function isMember('));
  assert.ok(member.includes('link(mapping, uid, cafeId) && link(membership, uid, cafeId) && matchingGeneration(mapping, membership) &&'));
  assert.ok(member.includes("cafe.status == 'active' && cafe.schemaVersion == 1"));
  assert.ok(member.includes("membership.role in ['owner', 'staff']"));
  assert.ok(member.includes("((membership.role == 'owner' && uid == owner) || (membership.role == 'staff' && uid != owner)) &&"));
  assert.ok(member.includes("link(ownerMember, owner, cafeId) && ownerMember.role == 'owner' && link(ownerMapping, owner, cafeId) && matchingGeneration(ownerMapping, ownerMember);"));
  assert.ok(!member.includes('|| matchingGeneration'));
});

test('active link schema and signed-in/owner gates remain unchanged', () => {
  const link = between('    function link(', '    // Active-link');
  assert.equal(compact(link), compact(`function link(data, uid, cafeId) {
    return data.uid == uid && data.cafeId == cafeId &&
      data.status == 'active' && data.schemaVersion == 1;
  }`));
  assert.ok(rules.includes('function signedIn() { return request.auth != null; }'));
  assert.equal(compact(between('    function isMember(', '    // S2 LOCAL DRAFT:')), compact(`
    function isMember(cafeId) { return signedIn() && member(cafeId); }
    function isOwner(cafeId) {
      return isMember(cafeId) &&
        get(/databases/$(database)/documents/cafes/$(cafeId)).data.ownerUid == request.auth.uid;
    }`));
});

test('only the three bootstrap create grants change the previous match contract', () => {
  let blocks = rules.slice(rules.indexOf('    match /users/{uid}'));
  blocks = blocks.replace(`      allow create: if signedIn() && request.auth.uid == uid &&
        ownerBootstrap(request.resource.data.cafeId);
      allow list, update, delete: if false;`, '      allow list, write: if false;');
  blocks = blocks.replace(`      allow create: if signedIn() && ownerBootstrap(cafeId);
      allow list, update, delete: if false;`, '      allow list, write: if false;');
  blocks = blocks.replace(`        allow create: if signedIn() && request.auth.uid == uid && ownerBootstrap(cafeId);
        allow update, delete: if false;`, '        allow write: if false;');
  assert.equal(createHash('sha256').update(blocks).digest('hex'),
    '569d218433c691470338c24388b9db7c032fc16aab6de67c57009e3e8a375459');
});

test('bootstrap uses verified identity, prior absence and all final companion records', () => {
  const bootstrap = between('    function ownerBootstrap(', '    function validProfileCreate(');
  for (const text of ['request.auth.uid', 'request.auth.token.email_verified == true',
    '!exists(cafePath)', '!exists(memberPath)', '!exists(mappingPath)',
    'bootstrapCafe(getAfter(cafePath).data, uid)',
    'bootstrapMember(getAfter(memberPath).data, uid, cafeId)',
    'bootstrapMapping(getAfter(mappingPath).data, uid, cafeId)']) assert.ok(bootstrap.includes(text), text);
  assert.equal((bootstrap.match(/getAfter\(/g) || []).length, 3);
  assert.equal((bootstrap.match(/!exists\(/g) || []).length, 3);
});

test('bootstrap exact keys exclude generation and impose role, schema, time and preference bounds', () => {
  const helpers = between('    function bootstrapKeys(', '    function ownerBootstrap(');
  for (const text of ['data.keys().hasAll(keys)', 'data.keys().hasOnly(keys)',
    "data.status == 'active'", 'data.schemaVersion == 1', 'data.createdAt == request.time',
    'data.updatedAt == request.time', 'data.ownerUid == uid', 'data.uid == uid',
    'data.cafeId == cafeId', "data.role == 'owner'", 'data.name.size() >= 2',
    'data.name.size() <= 80', 'data.address.size() <= 200', 'prefs is map',
    'prefs.lowStockAlerts is bool', 'prefs.expiryReminders is bool', 'prefs.reminderDays is int',
    "['unit', 'lowStockAlerts', 'expiryReminders', 'reminderDays']"]) assert.ok(helpers.includes(text), text);
  assert.ok(!helpers.includes('membershipGeneration'));
});


// Offline host-regex examples only; this does not compile or execute Rules.
// Extract the actual Rules literals so a predicate change cannot leave tests
// exercising an unrelated hard-coded implementation. Only doubled backslashes
// are decoded; the exact policy is asserted before host execution.
function textPolicy(field) {
  const line = rules.split('\n').find(value => value.includes(`data.${field}.matches(`));
  assert.ok(line, `${field} policy exists`);
  assert.ok(!line.includes('!data.'), 'positive whole-string policy required');
  const literal = line.match(/matches\('([^']*)'\)/)[1];
  const slash = String.fromCharCode(92);
  const pattern = literal.split(slash.repeat(2)).join(slash);
  assert.equal(pattern, String.raw`[^\x00-\x1f\x7f-\x9f]*`);
  // JS $ can also match before a final newline. This end assertion cannot.
  const expression = new RegExp(String.raw`^(?:${pattern})(?![\s\S])`, 'u');
  return value => typeof value === 'string' && expression.test(value);
}
const validName = value => typeof value === 'string' &&
  value.length >= 2 && value.length <= 80 && textPolicy('name')(value);
const validAddress = value => typeof value === 'string' &&
  value.length <= 200 && textPolicy('address')(value);

test('both text predicates use the same positive control-free whole-string policy', () => {
  textPolicy('name');
  textPolicy('address');
  const source = between('    function bootstrapCafe(', '    function bootstrapMapping(');
  assert.ok(source.includes('data.name is string && data.name.size() >= 2 && data.name.size() <= 80'));
  assert.ok(source.includes('data.address is string && data.address.size() <= 200'));
});

for (const [label, value] of [
  ['ordinary name', 'Sunrise Cafe'],
  ['Unicode name', 'Caf\u00e9 \u5496\u5561 \u0645\u0642\u0647\u0649 \ud83c\udf70'],
  ['punctuation and spacing', "O'Brien & Sons - Bakery #2, (Main)."],
  ['Unicode combining mark', 'Cafe\u0301'],
]) {
  test(`offline host policy accepts ${label}`, () => {
    assert.equal(validName(value), true);
    assert.equal(validAddress(value), true);
  });
}
test('offline host policy accepts multiline-free address and existing Unicode spacing', () => {
  assert.equal(validAddress('12 Main Street, Unit #2 / East'), true);
  assert.equal(validName('Cafe\u00a0Owner'), true);
  assert.equal(validAddress('Main\u3000Street'), true);
});
for (const [label, value] of [
  ['single newline', 'A\nB'], ['multiple newlines', 'A\nB\nC'],
  ['carriage return', 'A\rB'], ['tab', 'A\tB'],
  ['multiline mixed controls', 'A\r\nB\tC\nD'],
  ['control at beginning', '\nAB'], ['control at end', 'AB\n'],
  ['multiple final newlines', 'AB\n\n'],
]) {
  test(`offline host policy rejects ${label}`, () => {
    assert.equal(validName(value), false);
    assert.equal(validAddress(value), false);
  });
}
test('offline host policy rejects every C0, DEL and C1 code point at every position', () => {
  for (const point of [...Array.from({length: 32}, (_, i) => i),
    ...Array.from({length: 33}, (_, i) => i + 0x7f)]) {
    const control = String.fromCodePoint(point);
    for (const value of [control + 'AB', 'A' + control + 'B', 'AB' + control,
      'A\n' + control + '\nB']) {
      assert.equal(validName(value), false, `name control ${point}`);
      assert.equal(validAddress(value), false, `address control ${point}`);
    }
  }
});
test('offline host model preserves ASCII length boundaries, optional address and types', () => {
  // Host length is UTF-16; Unicode boundary equivalence to Rules is not claimed.
  for (const [value, expected] of [['', false], ['A', false], ['AB', true],
    ['A'.repeat(80), true], ['A'.repeat(81), false]]) {
    assert.equal(validName(value), expected);
  }
  for (const [value, expected] of [['', true], ['A'.repeat(200), true],
    ['A'.repeat(201), false]]) assert.equal(validAddress(value), expected);
  for (const value of [null, 12, {}, []]) {
    assert.equal(validName(value), false);
    assert.equal(validAddress(value), false);
  }
});
