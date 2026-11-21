import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/firebase_spark_test_options.dart';

import '../tool/spark_test_owner_email_verification.dart';

const _owner = 'synthetic-approved-owner';

class _App extends Fake implements FirebaseApp {
  @override
  final String name;
  @override
  final FirebaseOptions options;

  _App({
    this.name = SparkTestOwnerEmailVerification.appName,
    this.options = SparkTestFirebaseOptions.web,
  });
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  FirebaseApp app;
  User? user;
  int sessionReads = 0;

  _Auth(this.user, {FirebaseApp? app}) : app = app ?? _App();

  @override
  User? get currentUser {
    sessionReads++;
    return user;
  }
}

class _User extends Fake implements User {
  @override
  final String uid;
  @override
  final bool emailVerified;
  final Future<void> Function()? onReload;
  int reloads = 0;

  _User({this.uid = _owner, this.emailVerified = false, this.onReload});

  @override
  Future<void> reload() async {
    reloads++;
    await onReload?.call();
  }
}

SparkTestOwnerEmailVerification _harness() =>
    SparkTestOwnerEmailVerification.forTesting(isWeb: true);

Matcher _reports(String text) => isA<SparkTestOwnerEmailResult>().having(
  (result) => result.displayText,
  'display text',
  text,
);

void main() {
  test(
    'non-Web, missing Auth and absent approval do not read a session',
    () async {
      final user = _User();
      final auth = _Auth(user);
      expect(
        await SparkTestOwnerEmailVerification.forTesting(
          isWeb: false,
        ).check(existingAuth: auth, approvedOwnerUid: _owner),
        _reports('UNKNOWN — CONFIG_REJECTED'),
      );
      expect(
        await _harness().check(existingAuth: null, approvedOwnerUid: _owner),
        _reports('UNKNOWN — CONFIG_REJECTED'),
      );
      expect(
        await _harness().check(existingAuth: auth, approvedOwnerUid: null),
        _reports('UNKNOWN — CONFIG_REJECTED'),
      );
      expect(auth.sessionReads, 0);
      expect(user.reloads, 0);
    },
  );

  test(
    'refuses default app, other projects and mismatched TEST options',
    () async {
      const options = SparkTestFirebaseOptions.web;
      for (final app in [
        _App(name: '[DEFAULT]'),
        _App(name: 'unapproved-name'),
        _App(options: options.copyWith(projectId: 'velora-73222')),
        _App(options: options.copyWith(projectId: 'unknown-project')),
        _App(options: options.copyWith(apiKey: 'synthetic-wrong-option')),
        _App(
          options: options.copyWith(databaseURL: 'https://unexpected.invalid'),
        ),
      ]) {
        final user = _User();
        final auth = _Auth(user, app: app);
        expect(
          await _harness().check(existingAuth: auth, approvedOwnerUid: _owner),
          _reports('UNKNOWN — CONFIG_REJECTED'),
        );
        expect(auth.sessionReads, 0);
        expect(user.reloads, 0);
      }
    },
  );

  test('requires an already-loaded session for the approved account', () async {
    expect(
      await _harness().check(
        existingAuth: _Auth(null),
        approvedOwnerUid: _owner,
      ),
      _reports('UNKNOWN — OWNER_MISMATCH'),
    );
    final other = _User(uid: 'different-synthetic-user');
    expect(
      await _harness().check(
        existingAuth: _Auth(other),
        approvedOwnerUid: _owner,
      ),
      _reports('UNKNOWN — OWNER_MISMATCH'),
    );
    expect(other.reloads, 0);
  });

  for (final verified in [false, true]) {
    test('reports refreshed email status, verified=$verified', () async {
      final auth = _Auth(null);
      final initial = _User(
        emailVerified: !verified,
        onReload: () async {
          auth.user = _User(emailVerified: verified);
        },
      );
      auth.user = initial;
      final runner = _harness();
      expect(
        await runner.check(existingAuth: auth, approvedOwnerUid: _owner),
        _reports(verified ? 'VERIFIED' : 'NOT_VERIFIED'),
      );
      expect(
        await runner.check(existingAuth: auth, approvedOwnerUid: _owner),
        _reports('UNKNOWN — CONFIG_REJECTED'),
      );
      expect(auth.sessionReads, 2);
      expect(initial.reloads, 1);
    });
  }

  test('rejects account or app replacement during reload', () async {
    for (final switchApp in [false, true]) {
      final auth = _Auth(null);
      final initial = _User(
        onReload: () async {
          if (switchApp) {
            auth.app = _App(name: '[DEFAULT]');
          } else {
            auth.user = _User(
              uid: 'different-synthetic-user',
              emailVerified: true,
            );
          }
        },
      );
      auth.user = initial;
      expect(
        await _harness().check(existingAuth: auth, approvedOwnerUid: _owner),
        _reports(
          switchApp ? 'UNKNOWN — CONFIG_REJECTED' : 'UNKNOWN — OWNER_MISMATCH',
        ),
      );
      expect(initial.reloads, 1);
    }
  });

  testWidgets('timeout consumes the only attempt and ignores a late reload', (
    tester,
  ) async {
    final reload = Completer<void>();
    final user = _User(emailVerified: true, onReload: () => reload.future);
    final auth = _Auth(user);
    final runner = _harness();
    final result = runner.check(existingAuth: auth, approvedOwnerUid: _owner);
    expect(
      await runner.check(existingAuth: auth, approvedOwnerUid: _owner),
      _reports('UNKNOWN — CONFIG_REJECTED'),
    );
    await tester.pump(SparkTestOwnerEmailVerification.timeout);
    expect(await result, _reports('UNKNOWN — RELOAD_TIMEOUT'));
    reload.complete();
    await tester.pump();
    expect(user.reloads, 1);
    expect(auth.sessionReads, 1);
  });

  test('a raw SDK failure produces only UNKNOWN and no log output', () async {
    final lines = <String>[];
    final user = _User(
      onReload: () async {
        throw StateError('synthetic private SDK failure');
      },
    );
    final result = await runZoned(
      () =>
          _harness().check(existingAuth: _Auth(user), approvedOwnerUid: _owner),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => lines.add(line),
      ),
    );
    expect(result, _reports('UNKNOWN — RELOAD_FAILED'));
    expect(lines, isEmpty);
    expect(user.reloads, 1);
  });
}
