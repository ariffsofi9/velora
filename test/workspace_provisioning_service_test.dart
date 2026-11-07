import 'package:velora/services/owner_email_verification.dart';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'dart:io';
import 'helpers/workspace_bootstrap_fake.dart';
import 'package:velora/firebase_options.dart';
import 'package:velora/services/firebase_startup_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'helpers/owner_verification_fake.dart';

class _UnavailableVerification extends VerifiedOwnerFake {
  @override
  Future<bool> refreshVerified() async =>
      throw const OwnerVerificationException(
        OwnerVerificationFailure.unavailable,
      );
}

const _request = WorkspaceCreationRequest(
  businessName: 'Cafe',
  businessType: 'Bakery',
  address: '',
  inventoryUnit: 'kg',
  lowStockAlerts: true,
  expiryReminders: true,
  reminderDays: 3,
);
void main() {
  test('Callable request maps the complete trusted backend contract', () {
    const request = WorkspaceCreationRequest(
      businessName: 'Sunrise Cafe',
      businessType: 'Café',
      address: '12 Market Street',
      inventoryUnit: 'L',
      lowStockAlerts: false,
      expiryReminders: true,
      reminderDays: 7,
    );

    expect(request.toCallableData(), {
      'businessName': 'Sunrise Cafe',
      'businessType': 'Café',
      'address': '12 Market Street',
      'inventoryUnit': 'L',
      'lowStockAlerts': false,
      'expiryReminders': true,
      'reminderDays': 7,
    });
    expect(request.toCallableData(), isNot(contains('uid')));
    expect(request.toCallableData(), isNot(contains('role')));
    expect(request.toCallableData(), isNot(contains('cafeId')));
  });

  test('Missing explicit profile blocks before Firebase access', () async {
    await expectLater(
      FirebaseWorkspaceProvisioner().createWorkspace(
        const WorkspaceCreationRequest(
          businessName: 'Sunrise Cafe',
          businessType: 'Bakery',
          address: '',
          inventoryUnit: 'kg',
          lowStockAlerts: true,
          expiryReminders: true,
          reminderDays: 3,
        ),
      ),
      throwsA(
        isA<WorkspaceProvisioningException>().having(
          (error) => error.failure,
          'failure',
          WorkspaceProvisioningFailure.invalidProfile,
        ),
      ),
    );
  });
  FirebaseWorkspaceProvisioner adapter(
    BootstrapFake store, {
    String? Function()? uid,
    bool verified = true,
    bool mismatch = false,
    OwnerEmailVerification? verification,
    FirebaseStartupConfig config = const FirebaseStartupConfig(
      cloudProject: 'velora-73222',
    ),
  }) => FirebaseWorkspaceProvisioner(
    store: store,
    resolveProfile: () =>
        config.resolve(isWeb: true, platform: TargetPlatform.windows),
    activeOptions: () =>
        mismatch ? DefaultFirebaseOptions.windows : DefaultFirebaseOptions.web,
    currentUid: uid ?? () => 'owner',
    verification:
        verification ??
        VerifiedOwnerFake(uid: uid ?? () => 'owner', verified: verified),
  );
  Matcher failure(WorkspaceProvisioningFailure expected) => throwsA(
    isA<WorkspaceProvisioningException>().having(
      (e) => e.failure,
      'failure',
      expected,
    ),
  );

  test(
    'verified Owner commits three exact generation-zero records and all seven fields',
    () async {
      final store = BootstrapFake();
      expect((await adapter(store).createWorkspace(_request)).created, true);
      expect(store.commits, 1);
      expect(store.docs.keys.toSet(), {
        'cafes/cafe-1',
        'cafes/cafe-1/members/owner',
        'user_cafe_memberships/owner',
      });
      final cafe = store.docs['cafes/cafe-1']!;
      expect(cafe, {
        'ownerUid': 'owner',
        'name': 'Cafe',
        'businessType': 'Bakery',
        'address': '',
        'inventoryPreferences': {
          'unit': 'kg',
          'lowStockAlerts': true,
          'expiryReminders': true,
          'reminderDays': 3,
        },
        'status': 'active',
        'schemaVersion': 1,
        'createdAt': 'server-time',
        'updatedAt': 'server-time',
      });
      expect(store.docs['cafes/cafe-1/members/owner']!['role'], 'owner');
      for (final value in store.docs.values) {
        expect(value.containsKey('membershipGeneration'), false);
      }
    },
  );
  test('matching duplicate is read-only created false', () async {
    final store = BootstrapFake();
    final service = adapter(store);
    await service.createWorkspace(_request);
    expect((await service.createWorkspace(_request)).created, false);
    expect(store.docs.length, 3);
    expect(store.commits, 1);
  });
  test('two concurrent creates converge on one canonical workspace', () async {
    final store = BootstrapFake();
    final results = await Future.wait([
      adapter(store).createWorkspace(_request),
      adapter(store).createWorkspace(_request),
    ]);
    expect(results.where((r) => r.created).length, 1);
    expect(store.docs.length, 3);
    expect(store.commits, 1);
    expect(store.callbacks, greaterThan(2));
  });
  test('callback retry keeps one proposed cafe ID and one commit', () async {
    final store = BootstrapFake()..retryOnce = true;
    await adapter(store).createWorkspace(_request);
    expect(store.ids, 1);
    expect(store.callbacks, 2);
    expect(store.commits, 1);
  });
  test('no callable or Cloud Functions transport remains', () {
    final source = File(
      'lib/services/workspace_provisioning_service.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('httpsCallable')));
    expect(source, isNot(contains('package:cloud_functions')));
    expect(source, contains('tx.set(db.doc(path), data)'));
  });
  for (final verified in [false, true]) {
    test(
      'authentication preflight blocks ${verified ? 'signed out' : 'unverified'}',
      () async {
        final store = BootstrapFake();
        await expectLater(
          adapter(
            store,
            verified: verified,
            uid: () => verified ? null : 'owner',
          ).createWorkspace(_request),
          failure(
            verified
                ? WorkspaceProvisioningFailure.unauthenticated
                : WorkspaceProvisioningFailure.emailUnverified,
          ),
        );
        expect(store.calls, 0);
        expect(store.docs, isEmpty);
      },
    );
  }
  test('UID change during transactional read rejects before writes', () async {
    final store = BootstrapFake();
    String? uid = 'owner';
    store.onRead = () async {
      uid = 'different';
    };
    await expectLater(
      adapter(store, uid: () => uid).createWorkspace(_request),
      failure(WorkspaceProvisioningFailure.unauthenticated),
    );
    expect(store.docs, isEmpty);
  });
  test(
    'UID change after commit withholds success and does not retry writes',
    () async {
      final store = BootstrapFake();
      String? uid = 'owner';
      store.beforeCommit = () {
        uid = null;
      };
      await expectLater(
        adapter(store, uid: () => uid).createWorkspace(_request),
        failure(WorkspaceProvisioningFailure.unauthenticated),
      );
      expect(store.commits, 1);
      expect(store.docs.length, 3);
    },
  );
  for (final config in [
    const FirebaseStartupConfig(),
    const FirebaseStartupConfig(cloudProject: 'wrong'),
    const FirebaseStartupConfig(
      cloudProject: 'velora-73222',
      emulatorFlagPresent: true,
    ),
    const FirebaseStartupConfig(
      cloudProject: 'velora-73222',
      stagingFlagPresent: true,
    ),
  ]) {
    test(
      'invalid/conflicting profile blocks transaction ${config.hashCode}',
      () async {
        final store = BootstrapFake();
        await expectLater(
          adapter(store, config: config).createWorkspace(_request),
          failure(WorkspaceProvisioningFailure.invalidProfile),
        );
        expect(store.calls, 0);
      },
    );
  }
  test('initialized app mismatch blocks transaction', () async {
    final store = BootstrapFake();
    await expectLater(
      adapter(store, mismatch: true).createWorkspace(_request),
      failure(WorkspaceProvisioningFailure.invalidProfile),
    );
    expect(store.calls, 0);
  });
  for (final defect in [
    'staff',
    'inactive',
    'wrong-uid',
    'wrong-cafe',
    'missing-member',
    'missing-cafe',
    'wrong-owner',
    'conflicting-setup',
    'one-sided-zero',
    'generation-mismatch',
    'null-generation',
    'unsafe-generation',
    'bad-schema',
    'bad-cafe-id',
  ]) {
    test('existing graph fails closed: $defect', () async {
      final store = BootstrapFake();
      await adapter(store).createWorkspace(_request);
      final mapping = store.docs['user_cafe_memberships/owner']!;
      final member = store.docs['cafes/cafe-1/members/owner']!;
      final cafe = store.docs['cafes/cafe-1']!;
      switch (defect) {
        case 'staff':
          member['role'] = 'staff';
        case 'inactive':
          mapping['status'] = 'inactive';
        case 'wrong-uid':
          mapping['uid'] = 'other';
        case 'wrong-cafe':
          member['cafeId'] = 'other';
        case 'missing-member':
          store.docs.remove('cafes/cafe-1/members/owner');
        case 'missing-cafe':
          store.docs.remove('cafes/cafe-1');
        case 'wrong-owner':
          cafe['ownerUid'] = 'other';
        case 'conflicting-setup':
          cafe['address'] = 'different';
        case 'one-sided-zero':
          mapping['membershipGeneration'] = 0;
        case 'generation-mismatch':
          mapping['membershipGeneration'] = 1;
          member['membershipGeneration'] = 2;
        case 'null-generation':
          mapping['membershipGeneration'] = null;
          member['membershipGeneration'] = null;
        case 'unsafe-generation':
          mapping['membershipGeneration'] = 9007199254740992;
          member['membershipGeneration'] = 9007199254740992;
        case 'bad-schema':
          member['schemaVersion'] = 2;
        case 'bad-cafe-id':
          mapping['cafeId'] = '../bad';
      }
      final before = store.docs.toString();
      await expectLater(
        adapter(store).createWorkspace(_request),
        failure(WorkspaceProvisioningFailure.existingMembership),
      );
      expect(store.docs.toString(), before);
      expect(store.commits, 1);
    });
  }
  test(
    'matching explicit generations remain compatible for existing active Owner',
    () async {
      final store = BootstrapFake();
      await adapter(store).createWorkspace(_request);
      store.docs['user_cafe_memberships/owner']!['membershipGeneration'] = 2;
      store.docs['cafes/cafe-1/members/owner']!['membershipGeneration'] = 2;
      expect((await adapter(store).createWorkspace(_request)).created, false);
    },
  );
  for (final entry in {
    'permission-denied': WorkspaceProvisioningFailure.permissionDenied,
    'unauthenticated': WorkspaceProvisioningFailure.unauthenticated,
    'aborted': WorkspaceProvisioningFailure.unavailable,
    'unavailable': WorkspaceProvisioningFailure.unavailable,
    'deadline-exceeded': WorkspaceProvisioningFailure.timedOut,
    'internal': WorkspaceProvisioningFailure.internal,
  }.entries) {
    test(
      'commit failure ${entry.key} has no partial writes or success',
      () async {
        final store = BootstrapFake()
          ..error = FirebaseException(
            plugin: 'cloud_firestore',
            code: entry.key,
          );
        await expectLater(
          adapter(store).createWorkspace(_request),
          failure(entry.value),
        );
        expect(store.docs, isEmpty);
        expect(store.commits, 0);
      },
    );
  }
  test('timeout remains uncertain and returns no success', () async {
    final store = BootstrapFake()..error = TimeoutException('fixture');
    await expectLater(
      adapter(store).createWorkspace(_request),
      failure(WorkspaceProvisioningFailure.timedOut),
    );
    expect(store.docs, isEmpty);
  });
  test(
    'non-default preferences and lowercase alias preserve exact storage mapping',
    () async {
      final store = BootstrapFake();
      await adapter(store).createWorkspace(
        const WorkspaceCreationRequest(
          businessName: '  My  Cafe ',
          businessType: 'cafe',
          address: ' Main Street ',
          inventoryUnit: 'ml',
          lowStockAlerts: false,
          expiryReminders: false,
          reminderDays: 7,
        ),
      );
      final cafe = store.docs['cafes/cafe-1']!;
      expect(cafe['name'], 'My Cafe');
      expect(cafe['businessType'], 'Caf\u00e9');
      expect(cafe['address'], 'Main Street');
      expect(cafe['inventoryPreferences'], {
        'unit': 'ml',
        'lowStockAlerts': false,
        'expiryReminders': false,
        'reminderDays': 7,
      });
    },
  );
  test(
    'optional create-only Rules model rejects collision; SDK set alone does not',
    () async {
      final store = BootstrapFake()
        ..rejectExistingWrites = true
        ..docs['cafes/cafe-1'] = {'ownerUid': 'other'};
      await expectLater(
        adapter(store).createWorkspace(_request),
        failure(WorkspaceProvisioningFailure.unavailable),
      );
      expect(store.docs, {
        'cafes/cafe-1': {'ownerUid': 'other'},
      });
    },
  );
  test('concurrent conflicting setups allow one creation only', () async {
    final store = BootstrapFake();
    const other = WorkspaceCreationRequest(
      businessName: 'Different',
      businessType: 'Bakery',
      address: '',
      inventoryUnit: 'kg',
      lowStockAlerts: true,
      expiryReminders: true,
      reminderDays: 3,
    );
    final outcomes = await Future.wait(
      [_request, other].map((r) async {
        try {
          return await adapter(store).createWorkspace(r);
        } on WorkspaceProvisioningException catch (e) {
          return e;
        }
      }),
    );
    expect(outcomes.whereType<WorkspaceCreationResult>().length, 1);
    expect(
      outcomes.whereType<WorkspaceProvisioningException>().single.failure,
      WorkspaceProvisioningFailure.existingMembership,
    );
    expect(store.docs.length, 3);
    expect(store.commits, 1);
  });
  for (final generation in [-1, 0.5, '0']) {
    test('malformed existing generation rejected: $generation', () async {
      final store = BootstrapFake();
      await adapter(store).createWorkspace(_request);
      store.docs['user_cafe_memberships/owner']!['membershipGeneration'] =
          generation;
      store.docs['cafes/cafe-1/members/owner']!['membershipGeneration'] =
          generation;
      await expectLater(
        adapter(store).createWorkspace(_request),
        failure(WorkspaceProvisioningFailure.existingMembership),
      );
      expect(store.commits, 1);
    });
  }
  test('opaque offline failure returns no partial success', () async {
    final store = BootstrapFake()..error = StateError('network');
    await expectLater(
      adapter(store).createWorkspace(_request),
      failure(WorkspaceProvisioningFailure.unavailable),
    );
    expect(store.docs, isEmpty);
  });
  test(
    'verification failure before transaction is definitely not dispatched',
    () async {
      final store = BootstrapFake();
      await expectLater(
        adapter(
          store,
          verification: _UnavailableVerification(),
        ).createWorkspace(_request),
        throwsA(
          isA<WorkspaceProvisioningException>()
              .having(
                (e) => e.failure,
                'failure',
                WorkspaceProvisioningFailure.unavailable,
              )
              .having((e) => e.outcomeUncertain, 'uncertainty', false),
        ),
      );
      expect(store.calls, 0);
      expect(store.docs, isEmpty);
    },
  );
  test(
    'commit then lost response remains uncertain; explicit unchanged retry is idempotent',
    () async {
      final store = BootstrapFake()
        ..afterCommitError = TimeoutException('lost response');
      final service = adapter(store);
      await expectLater(
        service.createWorkspace(_request),
        throwsA(
          isA<WorkspaceProvisioningException>().having(
            (e) => e.outcomeUncertain,
            'uncertainty',
            true,
          ),
        ),
      );
      expect(store.docs.length, 3);
      expect(store.commits, 1);
      store.afterCommitError = null;
      expect((await service.createWorkspace(_request)).created, false);
      expect(store.docs.length, 3);
      expect(store.commits, 1);
    },
  );
  test(
    'SDK-like set fake exposes overwrite risk without a Rules model',
    () async {
      final store = BootstrapFake()
        ..docs['cafes/cafe-1'] = {'ownerUid': 'other'};
      await adapter(store).createWorkspace(_request);
      expect(store.docs['cafes/cafe-1']!['ownerUid'], 'owner');
      // This is why actual Rules acceptance remains mandatory before activation.
    },
  );
}
