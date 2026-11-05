import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:velora/firebase_options.dart';
import 'package:velora/services/firebase_startup_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'helpers/owner_verification_fake.dart';

class _Callable implements WorkspaceCreationCallable {
  int calls = 0;
  Object? error;
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    calls++;
    if (error != null) throw error!;
    return pending == null
        ? {'created': true, 'cafeId': 'cafe-a'}
        : pending!.future;
  }
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
    _Callable transport, {
    FirebaseStartupConfig config = const FirebaseStartupConfig(
      cloudProject: 'velora-73222',
    ),
    String? Function()? uid,
    bool mismatch = false,
  }) => FirebaseWorkspaceProvisioner(
    callable: transport,
    resolveProfile: () =>
        config.resolve(isWeb: true, platform: TargetPlatform.windows),
    activeOptions: () =>
        mismatch ? DefaultFirebaseOptions.windows : DefaultFirebaseOptions.web,
    currentUid: uid ?? () => 'owner',
    verification: VerifiedOwnerFake(uid: uid ?? () => 'owner'),
  );

  test('verified explicit profile reaches mocked callable only', () async {
    final transport = _Callable();
    expect((await adapter(transport).createWorkspace(_request)).created, true);
    expect(transport.calls, 1);
  });
  for (final config in [
    const FirebaseStartupConfig(),
    const FirebaseStartupConfig(cloudProject: 'wrong'),
    const FirebaseStartupConfig(
      cloudProject: 'velora-73222',
      stagingFlagPresent: true,
    ),
    const FirebaseStartupConfig(
      cloudProject: 'velora-73222',
      emulatorFlagPresent: true,
    ),
  ]) {
    test(
      'invalid or conflicting profile blocks dispatch ${config.hashCode}',
      () async {
        final transport = _Callable();
        await expectLater(
          adapter(transport, config: config).createWorkspace(_request),
          throwsA(isA<WorkspaceProvisioningException>()),
        );
        expect(transport.calls, 0);
      },
    );
  }
  test('initialized app mismatch blocks dispatch', () async {
    final transport = _Callable();
    await expectLater(
      adapter(transport, mismatch: true).createWorkspace(_request),
      throwsA(isA<WorkspaceProvisioningException>()),
    );
    expect(transport.calls, 0);
  });
  test('missing authentication blocks dispatch', () async {
    final transport = _Callable();
    await expectLater(
      adapter(transport, uid: () => null).createWorkspace(_request),
      throwsA(isA<WorkspaceProvisioningException>()),
    );
    expect(transport.calls, 0);
  });
  test('identity change during callable rejects late success', () async {
    final transport = _Callable()..pending = Completer();
    String? uid = 'owner';
    final pending = adapter(
      transport,
      uid: () => uid,
    ).createWorkspace(_request);
    uid = 'different';
    transport.pending!.complete({'created': true, 'cafeId': 'a'});
    await expectLater(pending, throwsA(isA<WorkspaceProvisioningException>()));
  });
  for (final entry in {
    'Verify your email and refresh your sign-in before creating a workspace.':
        WorkspaceProvisioningFailure.emailUnverified,
    'Existing workspace membership is inconsistent.':
        WorkspaceProvisioningFailure.existingMembership,
  }.entries) {
    test('precondition is mapped distinctly ${entry.value}', () async {
      final transport = _Callable()
        ..error = FirebaseFunctionsException(
          code: 'failed-precondition',
          message: entry.key,
        );
      await expectLater(
        adapter(transport).createWorkspace(_request),
        throwsA(
          isA<WorkspaceProvisioningException>().having(
            (e) => e.failure,
            'failure',
            entry.value,
          ),
        ),
      );
    });
  }
  for (final entry in {
    'not-found': WorkspaceProvisioningFailure.callableNotFound,
    'permission-denied': WorkspaceProvisioningFailure.permissionDenied,
    'unauthenticated': WorkspaceProvisioningFailure.unauthenticated,
    'unavailable': WorkspaceProvisioningFailure.unavailable,
    'deadline-exceeded': WorkspaceProvisioningFailure.timedOut,
    'already-exists': WorkspaceProvisioningFailure.existingMembership,
    'internal': WorkspaceProvisioningFailure.internal,
  }.entries) {
    test('offline callable classification ${entry.key}', () async {
      final transport = _Callable()
        ..error = FirebaseFunctionsException(
          code: entry.key,
          message: 'offline fixture',
        );
      await expectLater(
        adapter(transport).createWorkspace(_request),
        throwsA(
          isA<WorkspaceProvisioningException>().having(
            (e) => e.failure,
            'failure',
            entry.value,
          ),
        ),
      );
      expect(transport.calls, 1);
    });
  }
  test(
    'offline transport timeout is classified without claiming cancellation',
    () async {
      final transport = _Callable()
        ..error = TimeoutException('offline timeout');
      await expectLater(
        adapter(transport).createWorkspace(_request),
        throwsA(
          isA<WorkspaceProvisioningException>().having(
            (e) => e.failure,
            'failure',
            WorkspaceProvisioningFailure.timedOut,
          ),
        ),
      );
    },
  );
  test('offline opaque network exception is unavailable', () async {
    final transport = _Callable()
      ..error = StateError('offline network failure');
    await expectLater(
      adapter(transport).createWorkspace(_request),
      throwsA(
        isA<WorkspaceProvisioningException>().having(
          (e) => e.failure,
          'failure',
          WorkspaceProvisioningFailure.unavailable,
        ),
      ),
    );
  });
}
