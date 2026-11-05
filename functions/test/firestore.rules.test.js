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
// D3B.1B generation cases below require the existing deliberately isolated
// disposable emulator. They are not executed by npm test or static checks.
const firestorePort = Number(process.env.FIRESTORE_RULES_TEST_PORT || 8080);

const link = (uid, cafeId, role) => ({
  uid,
  cafeId,
  ...(role ? {role} : {}),
  status: 'active',
  schemaVersion: 1,
});

for (const uid of ['owner-a', 'staff-a']) {
  for (const [name, mapped, joined, allowed] of [
    ['legacy', undefined, undefined, true],
    ['explicit zero', 0, 0, true],
    ['explicit positive', 7, 7, true],
    ['maximum safe', Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, true],
    ['one-sided mapping zero', 0, undefined, false],
    ['one-sided member zero', undefined, 0, false],
    ['mismatch', 1, 2, false],
    ['negative', -1, -1, false],
    ['fractional', 0.5, 0.5, false],
    ['string', '0', '0', false],
    ['null', null, null, false],
    ['unsafe', 9007199254740992, 9007199254740992, false],
  ]) {
    test(`generation pair ${uid}: ${name}`, async () => {
      await environment.withSecurityRulesDisabled(async context => {
        const db = context.firestore();
        if (mapped !== undefined) await db.doc(`user_cafe_memberships/${uid}`).update({membershipGeneration: mapped});
        if (joined !== undefined) await db.doc(`cafes/cafe-a/members/${uid}`).update({membershipGeneration: joined});
      });
      const staff = environment.authenticatedContext('staff-a').firestore();
      const owner = environment.authenticatedContext('owner-a').firestore();
      // A bad owner pair blocks staff as well; a bad staff pair must not
      // revoke an independently valid owner's access.
      const check = allowed ? assertSucceeds : assertFails;
      await check(staff.doc('cafes/cafe-a/inventory/item-a').get());
      await (uid === 'owner-a' ? check : assertSucceeds)(owner.doc('cafes/cafe-a/inventory/item-a').get());
      if (allowed) {
        for (const forbidden of [
          'user_cafe_memberships/staff-a', 'cafes/cafe-a/members/staff-a',
          'cafes/cafe-a/activities/forged', 'cafes/cafe-a/membership_events/forged',
          'cafes/cafe-a/membership_requests/forged',
        ]) await assertFails(owner.doc(forbidden).set({membershipGeneration: 8}));
      }
    });
  }
}

test.before(async () => {
  environment = await initializeTestEnvironment({
    projectId: 'demo-velora-workspaces',
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, '../../docs/firebase/workspace.firestore.rules'),
        'utf8',
      ),
      host: '127.0.0.1',
      port: firestorePort,
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
    await db.doc('cafes/cafe-a/inventory/item-a').set({name: 'Milk'});
    await db.doc('cafes/cafe-b/inventory/item-b').set({name: 'Coffee'});
    await db.doc('cafes/cafe-a/inventory_movements/movement-a').set({
      cafeId: 'cafe-a',
      itemId: 'item-a',
      type: 'stock_in',
      quantity: 2,
      createdAt: new Date(),
    });
    await db.doc('cafes/cafe-b/inventory_movements/movement-b').set({
      cafeId: 'cafe-b',
      itemId: 'item-b',
      type: 'stock_out',
      quantity: 1,
      createdAt: new Date(),
    });
    await db.doc('cafes/cafe-a/activities/activity-a').set({
      cafeId: 'cafe-a',
      itemId: 'item-a',
      actorUid: 'staff-a',
      type: 'inventory_created',
      createdAt: new Date(),
    });
    await db.doc('cafes/cafe-b/activities/activity-b').set({
      cafeId: 'cafe-b',
      itemId: 'item-b',
      actorUid: 'owner-b',
      type: 'inventory_created',
      createdAt: new Date(),
    });
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

test('active members can read only their cafe inventory', async () => {
  const owner = environment.authenticatedContext('owner-a').firestore();
  const staff = environment.authenticatedContext('staff-a').firestore();
  const outsider = environment.authenticatedContext('owner-b').firestore();

  await assertSucceeds(owner.doc('cafes/cafe-a/inventory/item-a').get());
  await assertSucceeds(staff.collection('cafes/cafe-a/inventory').get());
  await assertFails(outsider.doc('cafes/cafe-a/inventory/item-a').get());
  await assertFails(outsider.collection('cafes/cafe-a/inventory').get());
});

test('unauthenticated and inactive members cannot read cafe inventory', async () => {
  const anonymous = environment.unauthenticatedContext().firestore();
  await assertFails(anonymous.doc('cafes/cafe-a/inventory/item-a').get());

  await environment.withSecurityRulesDisabled(async (context) => {
    await context.firestore().doc('cafes/cafe-a/members/staff-a').update({
      status: 'disabled',
    });
  });
  const staff = environment.authenticatedContext('staff-a').firestore();
  await assertFails(staff.doc('cafes/cafe-a/inventory/item-a').get());
});

test('all client inventory mutations remain denied', async () => {
  const owner = environment.authenticatedContext('owner-a').firestore();
  const item = owner.doc('cafes/cafe-a/inventory/item-a');

  await assertFails(
    owner.doc('cafes/cafe-a/inventory/new-item').set({name: 'Tea'}),
  );
  await assertFails(item.update({name: 'Changed'}));
  await assertFails(item.delete());
});

test('active owner and staff can read only their cafe movements', async () => {
  const owner = environment.authenticatedContext('owner-a').firestore();
  const staff = environment.authenticatedContext('staff-a').firestore();
  const outsider = environment.authenticatedContext('owner-b').firestore();

  await assertSucceeds(
    owner.doc('cafes/cafe-a/inventory_movements/movement-a').get(),
  );
  await assertSucceeds(
    staff.collection('cafes/cafe-a/inventory_movements').get(),
  );
  await assertFails(
    outsider.doc('cafes/cafe-a/inventory_movements/movement-a').get(),
  );
  await assertFails(
    outsider.collection('cafes/cafe-a/inventory_movements').get(),
  );
  await assertFails(
    staff.collectionGroup('inventory_movements')
      .where('itemId', '==', 'item-a')
      .get(),
  );
});

test('unauthenticated and inactive members cannot read movements', async () => {
  const anonymous = environment.unauthenticatedContext().firestore();
  await assertFails(
    anonymous.doc('cafes/cafe-a/inventory_movements/movement-a').get(),
  );

  await environment.withSecurityRulesDisabled(async (context) => {
    await context.firestore().doc('cafes/cafe-a/members/staff-a').update({
      status: 'disabled',
    });
  });
  const staff = environment.authenticatedContext('staff-a').firestore();
  await assertFails(
    staff.collection('cafes/cafe-a/inventory_movements').get(),
  );
});

test('all client movement mutations remain denied, including owner writes', async () => {
  const owner = environment.authenticatedContext('owner-a').firestore();
  const movement = owner.doc(
    'cafes/cafe-a/inventory_movements/movement-a',
  );
  await assertFails(
    owner.doc('cafes/cafe-a/inventory_movements/forged').set({
      itemId: 'item-a',
      quantity: 99,
    }),
  );
  await assertFails(movement.update({quantity: 99}));
  await assertFails(movement.delete());
});

test('active owner and staff can read only their cafe activities', async () => {
  const owner = environment.authenticatedContext('owner-a').firestore();
  const staff = environment.authenticatedContext('staff-a').firestore();
  const outsider = environment.authenticatedContext('owner-b').firestore();

  await assertSucceeds(owner.doc('cafes/cafe-a/activities/activity-a').get());
  await assertSucceeds(staff.collection('cafes/cafe-a/activities').get());
  await assertFails(outsider.doc('cafes/cafe-a/activities/activity-a').get());
  await assertFails(outsider.collection('cafes/cafe-a/activities').get());
  await assertFails(staff.collectionGroup('activities').get());
});

test('anonymous inactive and revoked members cannot read activities', async () => {
  const anonymous = environment.unauthenticatedContext().firestore();
  await assertFails(
    anonymous.doc('cafes/cafe-a/activities/activity-a').get(),
  );

  await environment.withSecurityRulesDisabled(async (context) => {
    await context.firestore().doc('cafes/cafe-a/members/staff-a').update({
      status: 'disabled',
    });
  });
  let staff = environment.authenticatedContext('staff-a').firestore();
  await assertFails(staff.collection('cafes/cafe-a/activities').get());

  await environment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.doc('cafes/cafe-a/members/staff-a').update({status: 'active'});
    await db.doc('user_cafe_memberships/staff-a').delete();
  });
  staff = environment.authenticatedContext('staff-a').firestore();
  await assertFails(staff.collection('cafes/cafe-a/activities').get());
});

test('all client activity mutations remain denied including owner writes', async () => {
  const owner = environment.authenticatedContext('owner-a').firestore();
  const activity = owner.doc('cafes/cafe-a/activities/activity-a');
  await assertFails(
    owner.doc('cafes/cafe-a/activities/forged').set({
      cafeId: 'cafe-a',
      itemId: 'item-a',
      actorUid: 'owner-a',
      type: 'inventory_created',
    }),
  );
  await assertFails(activity.update({type: 'inventory_updated'}));
  await assertFails(activity.delete());
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

test('menu items enforce cafe isolation and deny client mutations', async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    await context.firestore().doc('cafes/cafe-a/menu_items/menu-a').set({
      name: 'Latte',
    });
  });

  const owner = environment.authenticatedContext('owner-a').firestore();
  const staff = environment.authenticatedContext('staff-a').firestore();
  const outsider = environment.authenticatedContext('owner-b').firestore();
  const anonymous = environment.unauthenticatedContext().firestore();

  const path = 'cafes/cafe-a/menu_items/menu-a';

  await assertSucceeds(owner.doc(path).get());
  await assertSucceeds(staff.collection('cafes/cafe-a/menu_items').get());
  await assertFails(outsider.doc(path).get());
  await assertFails(outsider.collection('cafes/cafe-a/menu_items').get());
  await assertFails(anonymous.doc(path).get());

  await assertFails(owner.doc('cafes/cafe-a/menu_items/new-menu').set({
    name: 'Tea',
  }));
  await assertFails(staff.doc(path).update({name: 'Changed'}));
  await assertFails(owner.doc(path).delete());

  await environment.withSecurityRulesDisabled(async (context) => {
    await context.firestore().doc('cafes/cafe-a/members/staff-a').update({
      status: 'disabled',
    });
  });
  await assertFails(staff.doc(path).get());
});

test('all client menu requests access remains denied', async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    await context.firestore().doc('cafes/cafe-a/menu_requests/request-a').set({
      name: 'Latte',
    });
  });

  const owner = environment.authenticatedContext('owner-a').firestore();
  const staff = environment.authenticatedContext('staff-a').firestore();
  const anonymous = environment.unauthenticatedContext().firestore();
  const path = 'cafes/cafe-a/menu_requests/request-a';

  await assertFails(owner.doc(path).get());
  await assertFails(staff.collection('cafes/cafe-a/menu_requests').get());
  await assertFails(anonymous.doc(path).get());

  await assertFails(owner.doc('cafes/cafe-a/menu_requests/new-request').set({
    name: 'Tea',
  }));
  await assertFails(staff.doc(path).update({name: 'Changed'}));
  await assertFails(owner.doc(path).delete());
});
