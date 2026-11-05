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
  assert.equal(compact(between('    function isMember(', '    function validProfileCreate(')), compact(`
    function isMember(cafeId) { return signedIn() && member(cafeId); }
    function isOwner(cafeId) {
      return isMember(cafeId) &&
        get(/databases/$(database)/documents/cafes/$(cafeId)).data.ownerUid == request.auth.uid;
    }`));
});

test('all existing match/allow blocks are unchanged, including write denials and catch-all', () => {
  const blocks = rules.slice(rules.indexOf('    match /users/{uid}'));
  // Baseline taken before D3B.1B: protects mapping/member/audit/receipt write
  // denials, profile exceptions, read scope and denied undeclared lifecycle paths.
  assert.equal(createHash('sha256').update(blocks).digest('hex'),
    '569d218433c691470338c24388b9db7c032fc16aab6de67c57009e3e8a375459');
});
