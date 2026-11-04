// Offline Firebase interface doubles only.
// ignore_for_file: subtype_of_sealed_class
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/team/staff_invitation_page.dart';
import 'package:velora/services/staff_invitation_service.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:firebase_core/firebase_core.dart';

class _Invites implements StaffInvitations {
  int creates = 0;
  int revokes = 0;
  int redeems = 0;
  String? email;
  Object? redeemError;
  @override
  Future<StaffInvitation> create(String value) async {
    creates++;
    email = value;
    return const StaffInvitation(
      'synthetic-id',
      'synthetic-display-code',
      '2030-01-01',
    );
  }

  @override
  Future<void> revoke(String id) async {
    revokes++;
  }

  @override
  Future<void> redeem(String code) async {
    redeems++;
    if (redeemError != null) throw redeemError!;
  }
}

class _Auth extends Fake implements FirebaseAuth {
  User? user;
  @override
  User? get currentUser => user;
}

class _User extends Fake implements User {
  bool verified = true;
  Object? reloadError, tokenError;
  VoidCallback? afterReload;
  bool refreshed = false;
  @override
  String get uid => 'synthetic-staff';
  @override
  bool get emailVerified => verified;
  @override
  Future<void> reload() async {
    if (reloadError != null) throw reloadError!;
    afterReload?.call();
  }

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    refreshed = forceRefresh;
    if (tokenError != null) throw tokenError!;
    return 'synthetic-token';
  }
}

void main() {
  test('diagnostics retain only stage and allowlisted Firebase error code', () {
    final error = FirebaseAuthException(
      code: 'network-request-failed',
      message: 'PRIVATE-CODE-AND-TOKEN',
    );
    final failure = StaffInvitationFailure.fromError(
      StaffRedeemStage.authReload,
      error,
    );
    expect(
      failure.toString(),
      'Redemption failed at authReload (network-request-failed).',
    );
    for (final error in [
      StateError('PRIVATE-CODE-AND-TOKEN'),
      FirebaseAuthException(code: 'PRIVATE-CODE-AND-TOKEN', message: 'PRIVATE'),
    ]) {
      expect(
        StaffInvitationFailure.fromError(
          StaffRedeemStage.tokenRefresh,
          error,
        ).code,
        'unknown',
      );
    }
  });
  for (final scenario in [
    'signed-out',
    'reload',
    'unverified',
    'token',
    'session-changed',
    'reloaded-user',
  ]) {
    test(
      'redeem diagnoses $scenario before callable invocation',
      () async {
        final auth = _Auth();
        final user = _User();
        auth.user = user;
        var expectedStage = StaffRedeemStage.authSession;
        var expectedCode = 'unauthenticated';
        switch (scenario) {
          case 'signed-out':
            auth.user = null;
          case 'reload':
            user.reloadError = FirebaseAuthException(
              code: 'network-request-failed',
              message: 'PRIVATE',
            );
            expectedStage = StaffRedeemStage.authReload;
            expectedCode = 'network-request-failed';
          case 'unverified':
            user.verified = false;
            expectedStage = StaffRedeemStage.emailVerification;
            expectedCode = 'email-not-verified';
          case 'token':
            user.tokenError = FirebaseAuthException(
              code: 'user-token-expired',
              message: 'PRIVATE',
            );
            expectedStage = StaffRedeemStage.tokenRefresh;
            expectedCode = 'user-token-expired';
          case 'session-changed':
            user.afterReload = () => auth.user = null;
            expectedCode = 'session-changed';
          case 'reloaded-user':
            user.verified = false;
            user.afterReload = () => auth.user = (_User()
              ..tokenError = FirebaseAuthException(
                code: 'network-request-failed',
              ));
            expectedStage = StaffRedeemStage.tokenRefresh;
            expectedCode = 'network-request-failed';
        }
        await expectLater(
          FirebaseStaffInvitations(auth: auth).redeem('PRIVATE-INVITE'),
          throwsA(
            isA<StaffInvitationFailure>()
                .having((e) => e.stage, 'stage', expectedStage)
                .having((e) => e.code, 'code', expectedCode),
          ),
        );
        if (scenario == 'token') expect(user.refreshed, true);
      },
      skip:
          !FirebaseEmulatorConfig.staffDemo || !FirebaseEmulatorConfig.enabled,
    );
  }
  testWidgets(
    'redeem failure displays safe stage and code without provider message',
    (tester) async {
      final invites = _Invites()
        ..redeemError = StaffInvitationFailure.fromError(
          StaffRedeemStage.tokenRefresh,
          FirebaseAuthException(
            code: 'user-token-expired',
            message: 'PRIVATE-TOKEN',
          ),
        );
      await tester.pumpWidget(
        MaterialApp(home: StaffInvitationPage(invitations: invites)),
      );
      await tester.enterText(find.byType(TextField), 'PRIVATE-INVITE');
      await tester.tap(find.text('Redeem invitation'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('tokenRefresh (user-token-expired)'),
        findsOneWidget,
      );
      expect(find.textContaining('PRIVATE-TOKEN'), findsNothing);
    },
  );
  testWidgets('owner creates one-time code and revokes without persistence', (
    tester,
  ) async {
    final invites = _Invites();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: StaffInvitationPage(ownerMode: true, invitations: invites),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'staff@example.test');
    await tester.tap(find.text('Create invitation'));
    await tester.pumpAndSettle();
    expect(invites.creates, 1);
    expect(invites.email, 'staff@example.test');
    expect(find.text('synthetic-display-code'), findsOneWidget);
    await tester.ensureVisible(find.text('Revoke invitation'));
    await tester.tap(find.text('Revoke invitation'));
    await tester.pumpAndSettle();
    expect(invites.revokes, 1);
    expect(find.text('synthetic-display-code'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'staff redeems and re-enters gate callback only after service success',
    (tester) async {
      final invites = _Invites();
      var joined = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: StaffInvitationPage(
            invitations: invites,
            onJoined: () => joined = true,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'synthetic-code');
      await tester.tap(find.text('Redeem invitation'));
      await tester.pumpAndSettle();
      expect(invites.redeems, 1);
      expect(joined, true);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );
  test(
    'staff demo requires explicit loopback routing and uses only demo project',
    () {
      const normal = FirebaseOptions(
        apiKey: 'public-placeholder',
        appId: 'public-placeholder',
        messagingSenderId: 'public-placeholder',
        projectId: 'normal-placeholder',
      );
      if (FirebaseEmulatorConfig.staffDemo) {
        if (!FirebaseEmulatorConfig.enabled ||
            FirebaseEmulatorConfig.host != '127.0.0.1') {
          expect(
            () => FirebaseEmulatorConfig.optionsFor(normal),
            throwsStateError,
          );
          return;
        }
        final options = FirebaseEmulatorConfig.optionsFor(normal);
        expect(options.projectId, 'demo-velora-staff');
        expect(FirebaseEmulatorConfig.enabled, true);
        expect(FirebaseEmulatorConfig.host, '127.0.0.1');
      } else {
        expect(FirebaseEmulatorConfig.optionsFor(normal), same(normal));
      }
    },
  );
}
