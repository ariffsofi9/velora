import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/firebase_spark_test_options.dart';
import 'package:velora/services/firebase_startup_config.dart';

import '../tool/spark_test_owner_email_flow.dart';
import '../tool/spark_test_owner_email_verification.dart';

const _owner = 'synthetic-owner';
const _project = 'velora-spark-test';
const _startup = FirebaseStartupConfig(cloudProject: _project);

class _App extends Fake implements FirebaseApp {
  final List<String> events;
  final bool failDelete;
  @override
  final FirebaseOptions options;

  _App(this.events, this.options, {required this.failDelete});

  @override
  String get name => SparkTestOwnerEmailVerification.appName;
  @override
  Future<void> delete() async {
    events.add('dispose');
    if (failDelete) throw StateError('synthetic app cleanup failure');
  }
}

class _User extends Fake implements User {
  @override
  final String uid;
  @override
  final bool emailVerified;
  final Future<void> Function() onReload;
  final List<String> events;

  _User(this.events, this.uid, this.onReload, {this.emailVerified = true});

  @override
  Future<void> reload() async {
    events.add('reload');
    await onReload();
  }
}

class _Credential extends Fake implements UserCredential {
  @override
  final User user;
  _Credential(this.user);
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  final FirebaseApp app;
  final List<String> events;
  final User user;
  Object? signInError;
  bool failSignOut = false;
  bool failPersistence = false;
  bool preexistingSession = false;
  User? _current;

  _Auth(this.app, this.events, this.user);

  @override
  User? get currentUser => preexistingSession ? user : _current;

  @override
  Future<void> setPersistence(Persistence persistence) async {
    expect(persistence, Persistence.NONE);
    events.add('memory-only');
    if (failPersistence) {
      throw FirebaseAuthException(code: 'network-request-failed');
    }
  }

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    events.add('sign-in');
    expect(email.isNotEmpty && password.isNotEmpty, isTrue);
    final error = signInError;
    if (error != null) throw error;
    _current = user;
    return _Credential(user);
  }

  @override
  Future<void> signOut() async {
    events.add('sign-out');
    if (failSignOut) throw StateError('synthetic cleanup failure');
    _current = null;
  }
}

class _Fixture {
  final events = <String>[];
  late final SparkTestOwnerEmailFlow flow;
  late final _Auth auth;

  _Fixture({
    FirebaseStartupConfig startup = _startup,
    FirebaseOptions initializedOptions = SparkTestFirebaseOptions.web,
    String authenticatedUid = _owner,
    bool clean = true,
    bool failBrowserCheck = false,
    bool failDelete = false,
    bool emailVerified = true,
    Future<void> Function()? reload,
  }) {
    final app = _App(events, initializedOptions, failDelete: failDelete);
    auth = _Auth(
      app,
      events,
      _User(
        events,
        authenticatedUid,
        reload ?? () async {},
        emailVerified: emailVerified,
      ),
    );
    flow = SparkTestOwnerEmailFlow(
      startup: startup,
      isWeb: true,
      cleanBrowser: () async {
        events.add('browser-check');
        if (failBrowserCheck) throw StateError('synthetic browser failure');
        return clean;
      },
      initializeNamedApp: (options) async {
        expect(options == SparkTestFirebaseOptions.web, isTrue);
        events.add('initialize');
        return app;
      },
      authForApp: (app) {
        expect(app, same(auth.app));
        events.add('bind-auth');
        return auth;
      },
      verifyForTesting: (auth, uid) =>
          SparkTestOwnerEmailVerification.forTesting(
            isWeb: true,
          ).check(existingAuth: auth, approvedOwnerUid: uid),
    );
  }

  Future<SparkTestOwnerEmailResult> submit({String uid = _owner}) =>
      flow.submit(
        email: 'owner@example.invalid',
        password: 'synthetic-password',
        approvedOwnerUid: uid,
      );
}

const _authSteps = [
  'browser-check',
  'initialize',
  'bind-auth',
  'memory-only',
  'sign-in',
];

void main() {
  for (final project in ['', 'velora-73222', 'unexpected-project']) {
    test(
      'rejects non-TEST startup before any client creation [$project]',
      () async {
        final fixture = _Fixture(
          startup: FirebaseStartupConfig(cloudProject: project),
        );
        expect(
          (await fixture.submit()).displayText,
          'UNKNOWN — CONFIG_REJECTED',
        );
        expect(fixture.events, isEmpty);
      },
    );
  }

  test(
    'conflicting startup flags and missing approval prevent client creation',
    () async {
      final conflict = _Fixture(
        startup: const FirebaseStartupConfig(
          cloudProject: _project,
          emulatorFlagPresent: true,
        ),
      );
      final missing = _Fixture();
      expect(
        (await conflict.submit()).displayText,
        'UNKNOWN — CONFIG_REJECTED',
      );
      expect(
        (await missing.submit(uid: '')).displayText,
        'UNKNOWN — CONFIG_REJECTED',
      );
      expect(conflict.events, isEmpty);
      expect(missing.events, isEmpty);
    },
  );

  test(
    'fails closed on nonempty browser storage and mismatched app options',
    () async {
      final browser = _Fixture(clean: false);
      final mismatch = _Fixture(
        initializedOptions: SparkTestFirebaseOptions.web.copyWith(
          databaseURL: 'https://unexpected.invalid',
        ),
      );
      expect(
        (await browser.submit()).displayText,
        'UNKNOWN — BROWSER_PREFLIGHT_FAILED',
      );
      expect(browser.events, ['browser-check']);
      expect(
        (await mismatch.submit()).displayText,
        'UNKNOWN — CONFIG_REJECTED',
      );
      expect(mismatch.events, ['browser-check', 'initialize']);
    },
  );

  test('browser exceptions fail before initialization', () async {
    final fixture = _Fixture(failBrowserCheck: true);
    expect(
      (await fixture.submit()).displayText,
      'UNKNOWN — BROWSER_PREFLIGHT_FAILED',
    );
    expect(fixture.events, ['browser-check']);
  });

  testWidgets('loads private approval before one explicit sign-in', (
    tester,
  ) async {
    final fixture = _Fixture();
    var approvalReads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SparkTestOwnerEmailEntry(
          flow: fixture.flow,
          readApprovedOwnerFile: () async {
            approvalReads++;
            return '$_owner\r\n';
          },
        ),
      ),
    );
    expect(fixture.events, isEmpty);
    final inputs = find.byType(TextField);
    expect(inputs, findsNWidgets(2));
    expect(
      tester.widgetList<TextField>(inputs).every((input) => input.obscureText),
      isTrue,
    );
    await tester.enterText(inputs.at(0), 'owner@example.invalid');
    await tester.enterText(inputs.at(1), 'synthetic-password');
    final submit = find.widgetWithText(FilledButton, 'Sign in and check once');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(approvalReads, 0);
    await tester.tap(find.text('Choose approved Owner file'));
    await tester.pumpAndSettle();
    expect(fixture.events, isEmpty);
    expect(approvalReads, 1);
    expect(find.text('Owner identity loaded.'), findsOneWidget);
    expect(find.textContaining(_owner), findsNothing);
    final submitOnce = tester.widget<FilledButton>(submit).onPressed!;
    await tester.tap(submit);
    submitOnce();
    await tester.pumpAndSettle();
    expect(fixture.events, [..._authSteps, 'reload', 'sign-out', 'dispose']);
    expect(find.text('VERIFIED'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect((await fixture.submit()).status, 'UNKNOWN');
    expect(fixture.events, [..._authSteps, 'reload', 'sign-out', 'dispose']);
  });

  testWidgets('a cancelled or malformed replacement clears prior approval', (
    tester,
  ) async {
    final fixture = _Fixture();
    String? approval = _owner;
    await tester.pumpWidget(
      MaterialApp(
        home: SparkTestOwnerEmailEntry(
          flow: fixture.flow,
          readApprovedOwnerFile: () async => approval,
        ),
      ),
    );
    final choose = find.text('Choose approved Owner file');
    final submit = find.byType(FilledButton);
    for (final rejected in [null, '', '$_owner\nanother-uid']) {
      approval = _owner;
      await tester.tap(choose);
      await tester.pumpAndSettle();
      final staleSubmit = tester.widget<FilledButton>(submit).onPressed!;
      approval = rejected;
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(find.text('No valid Owner identity loaded.'), findsOneWidget);
      staleSubmit();
      expect(fixture.events, isEmpty);
    }
  });

  test('does not reuse an unexpected restored session', () async {
    final fixture = _Fixture()..auth.preexistingSession = true;
    expect((await fixture.submit()).displayText, 'UNKNOWN — AUTH_SETUP_FAILED');
    expect(fixture.events, [
      'browser-check',
      'initialize',
      'bind-auth',
      'dispose',
    ]);
  });

  test('persistence failure prevents sign-in and disposes the app', () async {
    final fixture = _Fixture()..auth.failPersistence = true;
    expect((await fixture.submit()).displayText, 'UNKNOWN — AUTH_SETUP_FAILED');
    expect(fixture.events, [..._authSteps.take(4), 'dispose']);
  });

  test(
    'unexpected sign-in exception uses the generic label and cleans up',
    () async {
      final fixture = _Fixture()
        ..auth.signInError = StateError('synthetic private sign-in error');
      final prints = <String>[];
      final result = await runZoned(
        fixture.submit,
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, text) => prints.add(text),
        ),
      );
      expect(result.displayText, 'UNKNOWN — SIGN_IN_FAILED');
      expect(prints, isEmpty);
      expect(fixture.events, [..._authSteps, 'sign-out', 'dispose']);
    },
  );

  const signInCases = {
    'CREDENTIALS_REJECTED': [
      'wrong-password',
      'user-not-found',
      'user-disabled',
      'invalid-credential',
      'invalid-login-credentials',
      'invalid-email',
      'account-exists-with-different-credential',
      'multi-factor-auth-required',
      'login-blocked',
    ],
    'AUTH_CONFIGURATION': [
      'operation-not-allowed',
      'invalid-api-key',
      'app-not-authorized',
      'unauthorized-domain',
      'auth-domain-config-required',
      'invalid-app-id',
    ],
    'NETWORK_UNAVAILABLE': ['network-request-failed'],
    'RATE_LIMITED': ['too-many-requests'],
    'SIGN_IN_FAILED': ['synthetic-unknown-code'],
  };
  for (final MapEntry(key: label, value: codes) in signInCases.entries) {
    for (final code in codes) {
      test('password error $code reports $label without retrying', () async {
        final fixture = _Fixture()
          ..auth.signInError = FirebaseAuthException(
            code: code,
            message: 'synthetic wrong-password detail',
          );
        expect((await fixture.submit()).displayText, 'UNKNOWN — $label');
        expect((await fixture.submit()).status, 'UNKNOWN');
        expect(fixture.events, [..._authSteps, 'sign-out', 'dispose']);
        expect(fixture.auth.currentUser, isNull);
      });
    }
  }

  testWidgets('shows only the fixed diagnostic after failed sign-in', (
    tester,
  ) async {
    final fixture = _Fixture()
      ..auth.signInError = FirebaseAuthException(
        code: 'user-not-found',
        email: 'owner@example.invalid',
        message:
            'private inputs: owner@example.invalid synthetic-password $_owner',
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SparkTestOwnerEmailEntry(
          flow: fixture.flow,
          readApprovedOwnerFile: () async => _owner,
        ),
      ),
    );
    await tester.tap(find.text('Choose approved Owner file'));
    await tester.pumpAndSettle();
    final inputs = find.byType(TextField);
    await tester.enterText(inputs.at(0), 'owner@example.invalid');
    await tester.enterText(inputs.at(1), 'synthetic-password');
    await tester.tap(find.text('Sign in and check once'));
    await tester.pumpAndSettle();
    expect(find.text('UNKNOWN — CREDENTIALS_REJECTED'), findsOneWidget);
    for (final value in [
      _owner,
      'owner@example.invalid',
      'synthetic-password',
      'user-not-found',
    ]) {
      expect(find.textContaining(value), findsNothing);
    }
    expect(fixture.events, [..._authSteps, 'sign-out', 'dispose']);
  });

  test('cleanup failure overrides a classified sign-in error', () async {
    final fixture = _Fixture()
      ..auth.signInError = FirebaseAuthException(code: 'wrong-password')
      ..auth.failSignOut = true;
    expect((await fixture.submit()).displayText, 'UNKNOWN — CLEANUP_FAILED');
    expect(fixture.events, [..._authSteps, 'sign-out', 'dispose']);
  });

  test(
    'account mismatch bypasses reload and clears the temporary session',
    () async {
      final fixture = _Fixture(authenticatedUid: 'different-synthetic-account');
      expect((await fixture.submit()).displayText, 'UNKNOWN — OWNER_MISMATCH');
      expect(fixture.events, [..._authSteps, 'sign-out', 'dispose']);
      expect(fixture.auth.currentUser, isNull);
    },
  );

  test('a reload exception is sanitized and triggers cleanup', () async {
    final fixture = _Fixture(
      reload: () async => throw StateError('synthetic private reload failure'),
    );
    expect((await fixture.submit()).displayText, 'UNKNOWN — RELOAD_FAILED');
    expect(fixture.events, [..._authSteps, 'reload', 'sign-out', 'dispose']);
  });

  test('a reload timeout stops the check and triggers cleanup', () async {
    final late = Completer<void>();
    final fixture = _Fixture(reload: () => late.future);
    expect((await fixture.submit()).displayText, 'UNKNOWN — RELOAD_TIMEOUT');
    expect(fixture.auth.currentUser, isNull);
    expect(fixture.events, [..._authSteps, 'reload', 'sign-out', 'dispose']);
    late.complete();
  });

  test('app disposal still runs when sign-out fails', () async {
    final fixture = _Fixture()..auth.failSignOut = true;
    expect((await fixture.submit()).displayText, 'UNKNOWN — CLEANUP_FAILED');
    expect(fixture.events, [..._authSteps, 'reload', 'sign-out', 'dispose']);
  });

  test(
    'app deletion failure is reported even after an Owner mismatch',
    () async {
      final fixture = _Fixture(
        authenticatedUid: 'other-owner',
        failDelete: true,
      );
      expect((await fixture.submit()).displayText, 'UNKNOWN — CLEANUP_FAILED');
      expect(fixture.events, [..._authSteps, 'sign-out', 'dispose']);
    },
  );

  test('a confirmed unverified account is reported after cleanup', () async {
    final fixture = _Fixture(emailVerified: false);
    expect((await fixture.submit()).displayText, 'NOT_VERIFIED');
    expect(fixture.events, [..._authSteps, 'reload', 'sign-out', 'dispose']);
  });
}
