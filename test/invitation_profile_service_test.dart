// Offline Auth/Functions doubles; never dispatches network requests.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:velora/services/staff_invitation_service.dart';
import 'helpers/invitation_firebase.dart';

class _User extends Fake implements User {
  @override
  final String uid;
  bool verified = true;
  void Function()? afterRefresh;
  _User(this.uid);
  @override
  bool get emailVerified => verified;
  @override
  Future<void> reload() async {}
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    afterRefresh?.call();
    return 'synthetic-token';
  }
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('actor');
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void change(String? uid) {
    user = uid == null ? null : _User(uid);
    changes.add(user);
  }
}

class _Result<T> extends Fake implements HttpsCallableResult<T> {
  @override
  final T data;
  _Result(this.data);
}

class _Callable extends Fake implements HttpsCallable {
  final Future<Map<String, dynamic>> Function(dynamic) handler;
  _Callable(this.handler);
  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async =>
      _Result<T>((await handler(parameters)) as T);
}

class _Functions extends Fake implements FirebaseFunctions {
  final calls = <String>[];
  final payloads = <dynamic>[];
  int? port;
  Completer<void>? pending;
  @override
  FirebaseApp get app => Firebase.app();
  @override
  void useFunctionsEmulator(
    String host,
    int port, {
    bool automaticHostMapping = true,
  }) {
    expect(host, '127.0.0.1');
    this.port = port;
  }

  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) =>
      _Callable((data) async {
        calls.add(name);
        payloads.add(data);
        await pending?.future;
        return name == 'createStaffInvitation'
            ? {
                'invitationId': 'fixture-id',
                'code': 'fixture-code',
                'expiresAt': '2099-01-01',
              }
            : <String, dynamic>{};
      });
}

void main() {
  late InvitationFirebase core;
  late _Auth auth;
  late _Functions functions;
  late FirebaseStaffInvitations service;
  const allowed =
      FirebaseEmulatorConfig.enabled &&
      FirebaseEmulatorConfig.host == '127.0.0.1' &&
      !FirebaseEmulatorConfig.conflictingProfiles &&
      !FirebaseEmulatorConfig.recipeConnectivity &&
      (FirebaseEmulatorConfig.staffDemo || FirebaseEmulatorConfig.ai1Mock);
  setUp(() {
    core = installInvitationFirebase();
    auth = _Auth();
    functions = _Functions();
    service = FirebaseStaffInvitations(auth: auth, functions: functions);
  });
  tearDown(() async {
    await auth.changes.close();
  });
  test(
    'shared predicate permits only exact eligible project/profile combinations',
    () {
      expect(FirebaseEmulatorConfig.invitationsAvailable, allowed);
      for (final project in [
        'production',
        'demo-velora-ai-connectivity',
        'other',
      ]) {
        expect(FirebaseEmulatorConfig.invitationProfileAllows(project), false);
      }
      expect(
        FirebaseEmulatorConfig.invitationProfileAllows(
          FirebaseEmulatorConfig.ai1Mock
              ? 'demo-velora-staff'
              : 'demo-velora-ai1',
        ),
        false,
      );
    },
  );
  test(
    'wrong runtime project always denies create/redeem before dispatch',
    () async {
      core.projectId = 'production';
      await expectLater(service.create('staff@example.test'), throwsStateError);
      await expectLater(
        service.redeem('fixture-code'),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(functions.calls, isEmpty);
    },
  );
  test(
    'ineligible profiles cannot dispatch even with injected transport',
    () async {
      if (allowed) return;
      await expectLater(service.create('staff@example.test'), throwsStateError);
      await expectLater(
        service.redeem('fixture-code'),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(functions.calls, isEmpty);
    },
  );
  group('eligible invitation service', () {
    test(
      'create/revoke/redeem route to exact emulator; no cafe/role fields',
      () async {
        expect(
          (await service.create('staff@example.test')).code,
          'fixture-code',
        );
        await service.revoke('fixture-id');
        await service.redeem('fixture-code');
        expect(functions.calls, [
          'createStaffInvitation',
          'revokeStaffInvitation',
          'redeemStaffInvitation',
        ]);
        expect(functions.port, FirebaseEmulatorConfig.ai1Mock ? 15001 : 25001);
        expect((functions.payloads.first as Map).keys.toSet(), {
          'email',
          'requestId',
        });
        expect(functions.payloads.last, {'code': 'fixture-code'});
      },
    );
    test('unverified staff cannot redeem', () async {
      (auth.user! as _User).verified = false;
      await expectLater(
        service.redeem('fixture-code'),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(functions.calls, isEmpty);
    });
    test('identity change during token refresh prevents dispatch', () async {
      (auth.user! as _User).afterRefresh = () => auth.change('other');
      await expectLater(
        service.redeem('fixture-code'),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(functions.calls, isEmpty);
    });
    test('away-and-back during token refresh prevents dispatch', () async {
      (auth.user! as _User).afterRefresh = () {
        auth.change(null);
        auth.change('actor');
      };
      await expectLater(
        service.redeem('fixture-code'),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(functions.calls, isEmpty);
    });
    for (final action in ['create', 'redeem']) {
      for (final transition in ['signout', 'identity', 'away-back']) {
        test('$action pending result invalidated: $transition', () async {
          functions.pending = Completer<void>();
          final request = action == 'create'
              ? service.create('staff@example.test')
              : service.redeem('fixture-code');
          final rejected = expectLater(
            request,
            throwsA(anyOf(isA<Exception>(), isA<Error>())),
          );
          await Future<void>.delayed(Duration.zero);
          auth.change(transition == 'identity' ? 'other' : null);
          if (transition == 'away-back') auth.change('actor');
          functions.pending!.complete();
          await rejected;
        });
      }
    }
  }, skip: !allowed);
}
