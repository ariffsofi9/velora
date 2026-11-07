// Offline Auth SDK doubles; no Firebase initialization or mail delivery.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'helpers/workspace_bootstrap_fake.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/screens/auth/owner_email_verification_page.dart';
import 'package:velora/services/owner_email_verification.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'package:velora/services/firebase_startup_config.dart';
import 'package:velora/firebase_options.dart';

class _Token extends Fake implements IdTokenResult {
  final bool verified;
  _Token(this.verified);
  @override
  Map<String, dynamic> get claims => {'email_verified': verified};
}

class _User extends Fake implements User {
  @override
  final String uid;
  bool verified = false;
  bool tokenVerified = true;
  int sends = 0;
  int reloads = 0;
  int refreshes = 0;
  Future<void> Function()? reloadAction;
  Future<void> Function()? tokenAction;
  Future<void> Function()? sendAction;
  _User([this.uid = 'owner']);
  @override
  bool get emailVerified => verified;
  @override
  Future<void> reload() async {
    reloads++;
    await reloadAction?.call();
  }

  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async {
    expect(forceRefresh, true);
    refreshes++;
    await tokenAction?.call();
    return _Token(tokenVerified);
  }

  @override
  Future<void> sendEmailVerification([
    ActionCodeSettings? actionCodeSettings,
  ]) async {
    sends++;
    await sendAction?.call();
  }
}

class _Auth extends Fake implements FirebaseAuth {
  _User? user = _User();
  @override
  User? get currentUser => user;
  @override
  Future<void> signOut() async {
    user = null;
  }
}

void main() {
  test(
    'stalled Auth operation times out without automatic email/token continuation',
    () async {
      final auth = _Auth();
      final pending = Completer<void>();
      auth.user!.reloadAction = () => pending.future;
      final service = FirebaseOwnerEmailVerification(
        auth: auth,
        operationTimeout: const Duration(milliseconds: 5),
      );
      await expectLater(
        service.refreshVerified(),
        throwsA(isA<OwnerVerificationException>()),
      );
      auth.user!.verified = true;
      pending.complete();
      await Future<void>.delayed(Duration.zero);
      expect(auth.user!.refreshes, 0);
      expect(auth.user!.sends, 0);
    },
  );
  test('invalid type/unit/reminder choices fail before transport', () {
    for (final values in [
      ('Catering', 'kg', 3),
      ('Bakery', 'box', 3),
      ('Bakery', 'kg', 2),
    ]) {
      final request = WorkspaceCreationRequest(
        businessName: 'Cafe',
        businessType: values.$1,
        address: '',
        inventoryUnit: values.$2,
        lowStockAlerts: true,
        expiryReminders: true,
        reminderDays: values.$3,
      );
      expect(
        request.normalized,
        throwsA(isA<WorkspaceProvisioningException>()),
      );
    }
  });
  testWidgets('send failure stays safe and cooldown disables duplicate send', (
    tester,
  ) async {
    final auth = _Auth();
    auth.user!.sendAction = () async => throw StateError('private Auth detail');
    await tester.pumpWidget(
      MaterialApp(
        home: OwnerEmailVerificationPage(
          verification: FirebaseOwnerEmailVerification(auth: auth),
          verifiedBuilder: (_) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('owner-send-verification')));
    await tester.pump();
    expect(find.textContaining('could not be confirmed'), findsOneWidget);
    expect(find.textContaining('private Auth detail'), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('owner-send-verification')),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'unverified reload returns pending, no token or email request',
    () async {
      final auth = _Auth();
      final service = FirebaseOwnerEmailVerification(auth: auth);
      expect(await service.refreshVerified(), false);
      expect(auth.user!.reloads, 1);
      expect(auth.user!.refreshes, 0);
      expect(auth.user!.sends, 0);
    },
  );
  test(
    'reload reacquires current user and forces fresh verified token',
    () async {
      final auth = _Auth();
      final old = auth.user!;
      final fresh = _User()..verified = true;
      old.reloadAction = () async {
        auth.user = fresh;
      };
      expect(
        await FirebaseOwnerEmailVerification(auth: auth).refreshVerified(),
        true,
      );
      expect(fresh.refreshes, 1);
      expect(old.refreshes, 0);
    },
  );
  test(
    'stale unverified token cannot authorize a verified cached user',
    () async {
      final auth = _Auth();
      auth.user!
        ..verified = true
        ..tokenVerified = false;
      expect(
        await FirebaseOwnerEmailVerification(auth: auth).refreshVerified(),
        false,
      );
    },
  );
  for (final stage in ['reload', 'token']) {
    test('identity switch during $stage rejected', () async {
      final auth = _Auth();
      auth.user!.verified = true;
      Future<void> change() async {
        auth.user = _User('other')..verified = true;
      }

      if (stage == 'reload') {
        auth.user!.reloadAction = change;
      } else {
        auth.user!.tokenAction = change;
      }
      await expectLater(
        FirebaseOwnerEmailVerification(auth: auth).refreshVerified(),
        throwsA(isA<OwnerVerificationException>()),
      );
    });
  }
  test(
    'send success, cooldown and duplicate protection use no automatic send',
    () async {
      final auth = _Auth();
      var now = DateTime.utc(2026);
      final pending = Completer<void>();
      auth.user!.sendAction = () => pending.future;
      final service = FirebaseOwnerEmailVerification(
        auth: auth,
        now: () => now,
      );
      final first = service.sendVerification();
      await expectLater(
        service.sendVerification(),
        throwsA(isA<OwnerVerificationException>()),
      );
      pending.complete();
      await first;
      expect(auth.user!.sends, 1);
      await expectLater(
        service.sendVerification(),
        throwsA(isA<OwnerVerificationException>()),
      );
      now = now.add(const Duration(seconds: 30));
      await service.sendVerification();
      expect(auth.user!.sends, 2);
    },
  );
  test('send failure remains throttled and never leaks raw error', () async {
    final auth = _Auth();
    auth.user!.sendAction = () async => throw StateError('private token');
    final service = FirebaseOwnerEmailVerification(auth: auth);
    await expectLater(
      service.sendVerification(),
      throwsA(
        predicate(
          (e) =>
              e is OwnerVerificationException &&
              !e.toString().contains('private'),
        ),
      ),
    );
    expect(service.resendRemaining, greaterThan(Duration.zero));
  });
  test('signed out, expired session, offline and sign-out are safe', () async {
    final auth = _Auth();
    final service = FirebaseOwnerEmailVerification(auth: auth);
    auth.user!.reloadAction = () async =>
        throw FirebaseAuthException(code: 'user-token-expired');
    await expectLater(
      service.refreshVerified(),
      throwsA(
        predicate(
          (e) =>
              e is OwnerVerificationException &&
              e.failure == OwnerVerificationFailure.signedOut,
        ),
      ),
    );
    auth.user!.reloadAction = () async =>
        throw FirebaseAuthException(code: 'network-request-failed');
    await expectLater(
      service.refreshVerified(),
      throwsA(
        predicate(
          (e) =>
              e is OwnerVerificationException &&
              e.failure == OwnerVerificationFailure.unavailable,
        ),
      ),
    );
    await service.signOut();
    expect(service.currentUid, isNull);
    await expectLater(
      service.refreshVerified(),
      throwsA(isA<OwnerVerificationException>()),
    );
  });
  testWidgets(
    'pending screen never sends automatically; explicit send/check continues',
    (tester) async {
      final auth = _Auth();
      final service = FirebaseOwnerEmailVerification(auth: auth);
      await tester.pumpWidget(
        MaterialApp(
          home: OwnerEmailVerificationPage(
            verification: service,
            verifiedBuilder: (_) =>
                const Scaffold(body: Text('Verified continuation')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.user!.sends, 0);
      await tester.tap(find.byKey(const ValueKey('owner-send-verification')));
      await tester.pump();
      expect(auth.user!.sends, 1);
      expect(find.textContaining('Resend available'), findsOneWidget);
      auth.user!.verified = true;
      await tester.tap(find.byKey(const ValueKey('owner-check-verification')));
      await tester.pumpAndSettle();
      expect(find.text('Verified continuation'), findsOneWidget);
      expect(auth.user!.refreshes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('already-verified user continues without email; safe sign out', (
    tester,
  ) async {
    final auth = _Auth();
    auth.user!.verified = true;
    await tester.pumpWidget(
      MaterialApp(
        home: OwnerEmailVerificationPage(
          verification: FirebaseOwnerEmailVerification(auth: auth),
          verifiedBuilder: (_) => const Scaffold(body: Text('Setup')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Setup'), findsOneWidget);
    expect(auth.user!.sends, 0);
    final other = _Auth();
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: OwnerEmailVerificationPage(
          verification: FirebaseOwnerEmailVerification(auth: other),
          loginBuilder: (_) => const Scaffold(body: Text('Safe Login')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(other.user, isNull);
    expect(find.text('Safe Login'), findsOneWidget);
  });
  test(
    'real provisioner rejects unverified user without transaction invocation',
    () async {
      final auth = _Auth();
      final callable = BootstrapFake();
      final provisioner = FirebaseWorkspaceProvisioner(
        store: callable,
        currentUid: () => auth.currentUser?.uid,
        verification: FirebaseOwnerEmailVerification(auth: auth),
        resolveProfile: () => const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
        ).resolve(isWeb: true, platform: TargetPlatform.windows),
        activeOptions: () => DefaultFirebaseOptions.web,
      );
      const request = WorkspaceCreationRequest(
        businessName: 'Cafe',
        businessType: 'Bakery',
        address: '',
        inventoryUnit: 'kg',
        lowStockAlerts: true,
        expiryReminders: true,
        reminderDays: 3,
      );
      await expectLater(
        provisioner.createWorkspace(request),
        throwsA(
          predicate(
            (e) =>
                e is WorkspaceProvisioningException &&
                e.failure == WorkspaceProvisioningFailure.emailUnverified,
          ),
        ),
      );
      expect(callable.calls, 0);
      auth.user!.verified = true;
      expect((await provisioner.createWorkspace(request)).created, true);
      expect(callable.calls, 1);
    },
  );
  test('backend-aligned normalization and all seven fields', () {
    const raw = WorkspaceCreationRequest(
      businessName: '  Cafe\n  Owner  ',
      businessType: 'Bakery',
      address: '  Main\t Street ',
      inventoryUnit: 'pcs',
      lowStockAlerts: false,
      expiryReminders: true,
      reminderDays: 7,
    );
    expect(raw.normalized().toCallableData(), {
      'businessName': 'Cafe Owner',
      'businessType': 'Bakery',
      'address': 'Main Street',
      'inventoryUnit': 'pcs',
      'lowStockAlerts': false,
      'expiryReminders': true,
      'reminderDays': 7,
    });
    for (final name in ['', 'a', 'a' * 81, 'ab\u0000']) {
      expect(WorkspaceCreationRequest.validateBusinessName(name), isNotNull);
    }
    for (final name in ['ab', 'a' * 80]) {
      expect(WorkspaceCreationRequest.validateBusinessName(name), isNull);
    }
    expect(WorkspaceCreationRequest.validateAddress('a' * 200), isNull);
    expect(WorkspaceCreationRequest.validateAddress('a' * 201), isNotNull);
    expect(WorkspaceCreationRequest.validateAddress('Main\u0080'), isNotNull);
  });
}
