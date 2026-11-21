import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/services/offline_verified_workspace_inventory.dart';

import 'workspace_inventory_https_transport_test.dart'
    show acknowledgement, create, workspace;

const _project = 'velora-spark-test';
const _email = 'synthetic@example.invalid';
final _now = DateTime.utc(2026, 11, 21);

String _token({bool expired = false}) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = _now.millisecondsSinceEpoch ~/ 1000;
  final header = encode({'alg': 'RS256', 'kid': 'fake'});
  final payload = encode({
    'sub': 'owner',
    'aud': _project,
    'iss': 'https://securetoken.google.com/$_project',
    'email': _email,
    'email_verified': true,
    'iat': now - 100,
    'auth_time': now - 120,
    'exp': expired ? now : now + 100,
  });
  return '$header.$payload.c3ludGhldGlj';
}

class _App extends Fake implements FirebaseApp {
  @override
  final FirebaseOptions options = const FirebaseOptions(
    apiKey: 'fixture',
    appId: 'fixture',
    messagingSenderId: 'fixture',
    projectId: _project,
  );
}

class _User extends Fake implements User {
  final Future<String?> Function() acquire;
  int refreshes = 0;

  _User(this.acquire);

  @override
  String get uid => 'owner';
  @override
  String get email => _email;
  @override
  bool get emailVerified => true;
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) {
    expect(forceRefresh, isTrue);
    refreshes++;
    return acquire();
  }
}

class _Auth extends Fake implements FirebaseAuth {
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  final FirebaseApp app = _App();
  @override
  User? currentUser;
  @override
  Stream<User?> authStateChanges() => changes.stream;

  void replace(User? user) {
    currentUser = user;
    changes.add(user);
  }
}

void main() {
  late _Auth auth;
  late OfflineVerifiedWorkspaceInventory composition;
  late List<http.Request> requests;

  setUp(() {
    auth = _Auth();
    requests = [];
    composition = OfflineVerifiedWorkspaceInventory(
      auth: auth,
      projectId: _project,
      policy: AndroidPilotPolicy.parse(
        const {},
        isWeb: false,
        platform: TargetPlatform.android,
      ),
      now: () => _now,
      respond: (request) async {
        requests.add(request);
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            ...acknowledgement('create'),
            'cafeId': payload['expectedCafeId'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
  });

  tearDown(() async {
    await composition.close();
    await auth.changes.close();
  });

  test(
    'requires verified workspace and dispatches only the bound bearer',
    () async {
      final verified = workspace(generation: 7);
      expect(
        composition.bindVerifiedWorkspace(verified, expectedRevision: 0),
        isFalse,
      );
      final user = _User(() async => _token());
      auth.replace(user);
      await expectLater(
        composition.transport.createItem(create()),
        throwsException,
      );
      expect(requests, isEmpty);
      expect(user.refreshes, 0);

      expect(
        composition.bindVerifiedWorkspace(
          verified,
          expectedRevision: composition.revision,
        ),
        isTrue,
      );
      await composition.transport.createItem(create());
      final request = requests.single;
      expect(
        request.url.toString(),
        'https://inventory.offline.invalid/inventory/create',
      );
      expect(request.headers['authorization'], 'Bearer ${_token()}');
      expect(request.followRedirects, isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['expectedCafeId'], 'cafe');
      expect(body['expectedMembershipGeneration'], 7);
      expect(request.body, isNot(contains(_token())));
    },
  );

  for (final mode in ['logout', 'same UID', 'workspace replacement']) {
    test('$mode fences an in-flight token and stale resolution', () async {
      final acquiring = Completer<void>();
      final pending = Completer<String?>();
      auth.replace(
        _User(() {
          acquiring.complete();
          return pending.future;
        }),
      );
      final original = workspace();
      expect(
        composition.bindVerifiedWorkspace(
          original,
          expectedRevision: composition.revision,
        ),
        isTrue,
      );

      final revision = composition.revision;
      final request = expectLater(
        composition.transport.createItem(create()),
        throwsException,
      );
      await acquiring.future;
      switch (mode) {
        case 'logout':
          auth.replace(null);
        case 'same UID':
          auth.replace(_User(() async => _token()));
        case 'workspace replacement':
          expect(
            composition.bindVerifiedWorkspace(
              workspace(cafe: 'other-cafe'),
              expectedRevision: revision,
            ),
            isTrue,
          );
      }
      expect(composition.revision, revision + 1);
      expect(
        composition.bindVerifiedWorkspace(
          workspace(),
          expectedRevision: revision,
        ),
        isFalse,
      );
      expect(
        composition.bindVerifiedWorkspace(
          original,
          expectedRevision: composition.revision,
        ),
        isFalse,
      );
      pending.complete(_token());
      await request;
      expect(requests, isEmpty);

      if (mode == 'same UID') {
        expect(
          composition.bindVerifiedWorkspace(
            workspace(),
            expectedRevision: composition.revision,
          ),
          isTrue,
        );
        await composition.transport.createItem(create());
        expect(requests, hasLength(1));
      }
    });
  }

  test('sign-out and sign-in each advance the revision for the same UID', () {
    auth.replace(_User(() async => _token()));
    final revision = composition.revision;
    auth.replace(null);
    auth.replace(_User(() async => _token()));
    expect(composition.revision, revision + 2);
    expect(
      composition.bindVerifiedWorkspace(
        workspace(),
        expectedRevision: revision,
      ),
      isFalse,
    );
  });

  test('revoked workspace blocks without acquiring a token', () async {
    final user = _User(() async => _token());
    auth.replace(user);
    final verified = workspace();
    expect(
      composition.bindVerifiedWorkspace(
        verified,
        expectedRevision: composition.revision,
      ),
      isTrue,
    );
    verified.invalidate();
    await expectLater(
      composition.transport.createItem(create()),
      throwsException,
    );
    expect(user.refreshes, 0);
    expect(requests, isEmpty);
  });

  for (final expired in [true, false]) {
    test(
      expired
          ? 'expired token blocks dispatch'
          : 'refresh failure blocks dispatch',
      () async {
        auth.replace(
          _User(() async {
            if (expired) return _token(expired: true);
            throw StateError('synthetic failure');
          }),
        );
        expect(
          composition.bindVerifiedWorkspace(
            workspace(),
            expectedRevision: composition.revision,
          ),
          isTrue,
        );
        await expectLater(
          composition.transport.createItem(create()),
          throwsException,
        );
        expect(requests, isEmpty);
      },
    );
  }

  test('closing composition revokes its existing transport', () async {
    final user = _User(() async => _token());
    auth.replace(user);
    expect(
      composition.bindVerifiedWorkspace(
        workspace(),
        expectedRevision: composition.revision,
      ),
      isTrue,
    );
    await composition.close();
    await expectLater(
      composition.transport.createItem(create()),
      throwsException,
    );
    expect(user.refreshes, 0);
    expect(requests, isEmpty);
  });
}
