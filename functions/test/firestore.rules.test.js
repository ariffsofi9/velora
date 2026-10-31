'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {serverTimestamp} = require('firebase/firestore');

let environment;

const link = (uid, cafeId, role) => ({
  uid,
  cafeId,
  ...(role ? {role} : {}),
  status: 'active',
  schemaVersion: 1,
});

test.before(async () => {
  environment = await initializeTestEnvironment({
    projectId: 'demo-velora-workspaces',
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, '../../docs/firebase/workspace.firestore.rules'),
        'utf8',
      ),
      host: '127.0.0.1',
      port: 8080,
    },
  });
});

test.after(async () => environment?.cleanup());

test.beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.doc('cafes/cafe-a').set({
      ownerUid: 'owner-a',
      status: 'active',
      schemaVersion: 1,
    });
    await db.doc('cafes/cafe-a/members/owner-a').set(
      link('owner-a', 'cafe-a', 'owner'),
    );
    await db.doc('cafes/cafe-a/members/staff-a').set(
      link('staff-a', 'cafe-a', 'staff'),
    );
    await db.doc('user_cafe_memberships/owner-a').set(
      link('owner-a', 'cafe-a'),
    );
    await db.doc('user_cafe_memberships/staff-a').set(
      link('staff-a', 'cafe-a'),
    );
    await db.doc('cafes/cafe-b').set({
      ownerUid: 'owner-b',
      status: 'active',
      schemaVersion: 1,
    });
    await db.doc('cafes/cafe-b/members/owner-b').set(
      link('owner-b', 'cafe-b', 'owner'),
    );
    await db.doc('user_cafe_memberships/owner-b').set(
      link('owner-b', 'cafe-b'),
    );
  });
});

test('unauthenticated workspace reads and writes are denied', async () => {
  const db = environment.unauthenticatedContext().firestore();
  await assertFails(db.doc('cafes/cafe-a').get());
  await assertFails(db.doc('user_cafe_memberships/owner-a').get());
  await assertFails(db.doc('cafes/new-cafe').set({ownerUid: 'attacker'}));
});

test('valid owner and staff can resolve only their workspace links', async () => {
  const owner = environment.authenticatedContext('owner-a').firestore();
  const staff = environment.authenticatedContext('staff-a').firestore();
  await assertSucceeds(owner.doc('cafes/cafe-a').get());
  await assertSucceeds(owner.collection('cafes/cafe-a/members').get());
  await assertSucceeds(staff.doc('cafes/cafe-a').get());
  await assertSucceeds(staff.doc('user_cafe_memberships/staff-a').get());
  await assertSucceeds(staff.doc('user_cafe_memberships/owner-a').get());
  await assertSucceeds(staff.doc('cafes/cafe-a/members/staff-a').get());
  await assertSucceeds(staff.doc('cafes/cafe-a/members/owner-a').get());
  await assertFails(staff.collection('cafes/cafe-a/members').get());
  await assertFails(staff.doc('cafes/cafe-b').get());
  await assertFails(staff.doc('user_cafe_memberships/owner-b').get());
});

test('clients cannot forge mappings, roles or owner workspaces', async () => {
  const db = environment.authenticatedContext('attacker').firestore();
  await assertFails(db.doc('user_cafe_memberships/attacker').set(
    link('attacker', 'cafe-a'),
  ));
  await assertFails(db.doc('cafes/cafe-a/members/attacker').set(
    link('attacker', 'cafe-a', 'owner'),
  ));
  await assertFails(db.doc('cafes/forged').set({
    ownerUid: 'attacker',
    status: 'active',
    schemaVersion: 1,
  }));
});

test('users can create only their own validated profile', async () => {
  const owner = environment.authenticatedContext('owner-a', {
    email: 'owner@example.test',
  }).firestore();
  const profile = {
    username: 'Cafe Owner',
    email: 'owner@example.test',
    photoUrl: '',
    role: 'owner',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };

  await assertSucceeds(owner.doc('users/owner-a').set(profile));
  await assertFails(owner.doc('users/other-user').set(profile));
  await assertFails(owner.doc('users/forged-extra').set({
    ...profile,
    uid: 'forged-extra',
  }));
  await assertFails(owner.doc('users/forged-email').set({
    ...profile,
    email: 'different@example.test',
  }));
});

test('profile updates cannot change email, role or creation time', async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    await context.firestore().doc('users/owner-a').set({
      username: 'Cafe Owner',
      email: 'owner@example.test',
      photoUrl: '',
      role: 'owner',
      createdAt: new Date(),
      updatedAt: new Date(),
    });
  });
  const owner = environment.authenticatedContext('owner-a', {
    email: 'owner@example.test',
  }).firestore();

  await assertSucceeds(owner.doc('users/owner-a').update({
    username: 'Updated Owner',
    photoUrl: 'https://example.test/photo.png',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(owner.doc('users/owner-a').update({role: 'staff'}));
  await assertFails(owner.doc('users/owner-a').update({
    email: 'different@example.test',
  }));
});
