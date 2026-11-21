import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_inventory_firebase_token_provider.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';

import 'workspace_inventory_https_transport_test.dart'
    show Fixture, acknowledgement, create, snapshot, workspace;

const _project = 'velora-spark-test';
const _email = 'synthetic-owner@example.invalid';
final _now = DateTime.utc(2026, 11, 21);
final _seconds = _now.millisecondsSinceEpoch ~/ 1000;

String _token([Map<String, Object?> changes = const {}]) {
  String segment(Object data) =>
      base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
  final header = segment({'alg': 'RS256', 'kid': 'synthetic-key'});
  final payload = segment({
    'aud': _project,
    'iss': 'https://securetoken.google.com/$_project',
    'sub': 'owner',
    'email': _email,
    'email_verified': true,
    'iat': _seconds,
    'auth_time': _seconds - 10,
    'exp': _seconds + 3600,
    ...changes,
  });
  return '$header.$payload.c3ludGhldGlj';
}

class _App extends Fake implements FirebaseApp {
  @override
  final FirebaseOptions options;

  _App(String project)
    : options = FirebaseOptions(
        appId: 'synthetic-app',
        apiKey: 'synthetic-key',
        messagingSenderId: 'synthetic-sender',
        projectId: project,
      );
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  final FirebaseApp app;

  @override
  User? currentUser;

  _Auth(String project, this.currentUser) : app = _App(project);
}

class _User extends Fake implements User {
  @override
  final String uid;
  @override
  final bool emailVerified;
  @override
  String get email => _email;
  final Future<String?> Function() acquire;
  final requests = <bool>[];

  _User(this.acquire, {this.uid = 'owner', this.emailVerified = true});

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) {
    requests.add(forceRefresh);
    return acquire();
  }
}

void main() {
  late Fixture fixture;
  late _Auth auth;
  late _User user;
  late HttpsWorkspaceInventory adapter;

  void configure({String authProject = _project, _User? account}) {
    user = account ?? _User(() async => _token());
    auth = _Auth(authProject, user);
    fixture.token = WorkspaceInventoryFirebaseTokenProvider(
      auth: auth,
      projectId: _project,
      currentSession: () => fixture.current,
      now: () => _now,
    ).call;
    adapter = fixture.adapter();
  }

  setUp(() {
    fixture = Fixture()..body = acknowledgement('create');
    configure();
  });
  tearDown(() => fixture.close());

  Future<void> expectRejected() async {
    await expectLater(adapter.createItem(create()), throwsException);
    expect(fixture.client.requests, isEmpty);
  }

  test(
    'fresh bound bearer is dispatched in the authorization header only',
    () async {
      await adapter.createItem(create());
      final request = fixture.client.requests.single;
      expect(user.requests, [true]);
      expect(request.headers['authorization'], 'Bearer ${_token()}');
      expect(request.followRedirects, isFalse);
      expect(request.url.toString(), isNot(contains(_token())));
      final body = utf8.decode(await request.finalize().toBytes());
      expect(body, isNot(contains(_token())));
    },
  );

  test('wrong Firebase project blocks before refresh', () async {
    configure(authProject: 'velora-73222');
    await expectRejected();
    expect(user.requests, isEmpty);
  });

  test('wrong authenticated UID blocks before refresh', () async {
    configure(account: _User(() async => _token(), uid: 'other'));
    await expectRejected();
    expect(user.requests, isEmpty);
  });

  test('unverified authenticated user blocks before refresh', () async {
    configure(account: _User(() async => _token(), emailVerified: false));
    await expectRejected();
    expect(user.requests, isEmpty);
  });

  final invalidClaims = <String, Map<String, Object?>>{
    'audience': {'aud': 'velora-73222'},
    'issuer': {'iss': 'https://securetoken.google.com/velora-73222'},
    'subject': {'sub': 'other'},
    'email': {'email': 'other@example.invalid'},
    'verified claim': {'email_verified': 'true'},
    'missing expiry': {'exp': null},
    'expired token': {'exp': _seconds},
    'future issue time': {'iat': _seconds + 1},
    'future auth time': {'auth_time': _seconds + 1},
    'future not-before': {'nbf': _seconds + 1},
  };
  for (final entry in invalidClaims.entries) {
    test('rejects invalid ${entry.key} without dispatch', () async {
      configure(account: _User(() async => _token(entry.value)));
      await expectRejected();
      expect(user.requests, [true]);
    });
  }

  test('malformed token does not dispatch', () async {
    configure(account: _User(() async => 'not-a-token'));
    await expectRejected();
  });

  test('refresh failure is contained and does not dispatch', () async {
    configure(
      account: _User(() async => throw StateError('synthetic failure')),
    );
    await expectRejected();
    expect(user.requests, [true]);
  });

  for (final transition in [
    'logout',
    'workspace replacement',
    'revision change',
  ]) {
    test('rejects $transition during token acquisition', () async {
      final began = Completer<void>();
      final pending = Completer<String?>();
      configure(
        account: _User(() {
          began.complete();
          return pending.future;
        }),
      );
      final result = expectRejected();
      await began.future;
      switch (transition) {
        case 'logout':
          auth.currentUser = null;
        case 'workspace replacement':
          fixture.current = snapshot(workspace());
        case 'revision change':
          fixture.current = snapshot(fixture.current!.workspace, revision: 2);
      }
      pending.complete(_token());
      await result;
      expect(user.requests, [true]);
    });
  }

  test(
    'same-UID sign-out and return cannot reuse an earlier revision',
    () async {
      final began = Completer<void>();
      final pending = Completer<String?>();
      configure(
        account: _User(() {
          began.complete();
          return pending.future;
        }),
      );
      final earlier = fixture.current!;
      final result = expectRejected();
      await began.future;
      auth.currentUser = null;
      fixture.current = null;
      auth.currentUser = _User(() async => _token());
      fixture.current = snapshot(
        earlier.workspace,
        revision: earlier.revision + 1,
      );
      pending.complete(_token());
      await result;
    },
  );
}
