import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

import 'firebase_emulator_config.dart';

enum StaffRedeemStage {
  emulatorConfig,
  authSession,
  authReload,
  emailVerification,
  tokenRefresh,
  callableConfig,
  callableInvocation,
  callableResponse,
}

class StaffInvitationFailure implements Exception {
  final StaffRedeemStage stage;
  final String code;
  const StaffInvitationFailure._(this.stage, this.code);

  factory StaffInvitationFailure.fromError(
    StaffRedeemStage stage,
    Object error,
  ) {
    // Never include Firebase messages, details, credentials or arbitrary codes.
    const allowed = {
      'unauthenticated',
      'permission-denied',
      'invalid-argument',
      'already-exists',
      'failed-precondition',
      'resource-exhausted',
      'unavailable',
      'not-found',
      'deadline-exceeded',
      'internal',
      'cancelled',
      'unknown',
      'no-app',
      'network-request-failed',
      'user-disabled',
      'user-not-found',
      'user-token-expired',
      'invalid-user-token',
      'requires-recent-login',
      'too-many-requests',
      'invalid-api-key',
      'app-not-authorized',
    };
    final code = error is FirebaseException && allowed.contains(error.code)
        ? error.code
        : 'unknown';
    return StaffInvitationFailure._(stage, code);
  }

  @override
  String toString() => 'Redemption failed at ${stage.name} ($code).';
}

class StaffInvitation {
  final String id;
  final String code;
  final String expiresAt;
  const StaffInvitation(this.id, this.code, this.expiresAt);
}

abstract interface class StaffInvitations {
  Future<StaffInvitation> create(String email);
  Future<void> revoke(String id);
  Future<void> redeem(String code);
}

class FirebaseStaffInvitations implements StaffInvitations {
  final FirebaseFunctions? functions;
  final FirebaseAuth? auth;
  FirebaseStaffInvitations({this.functions, this.auth});

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, Object> data, {
    void Function(StaffRedeemStage)? onStage,
  }) async {
    onStage?.call(StaffRedeemStage.callableConfig);
    if (!FirebaseEmulatorConfig.invitationsAvailable) {
      throw StateError(
        'Invitations are available in the verified local emulator environment only.',
      );
    }
    final transport =
        functions ?? FirebaseFunctions.instanceFor(region: 'asia-southeast1');
    if (!FirebaseEmulatorConfig.invitationProfileAllows(
      transport.app.options.projectId,
    )) {
      throw StateError('Invitation transport project mismatch.');
    }
    transport.useFunctionsEmulator(
      '127.0.0.1',
      FirebaseEmulatorConfig.invitationFunctionsPort,
      automaticHostMapping: false,
    );
    final identity = auth ?? FirebaseAuth.instance;
    final uid = identity.currentUser?.uid;
    if (uid == null) throw StateError('Sign in required.');
    var changed = false;
    final subscription = identity.authStateChanges().listen(
      (user) {
        if (user?.uid != uid) changed = true;
      },
      onError: (Object _) {
        changed = true;
      },
    );
    try {
      final callable = transport.httpsCallable(name);
      onStage?.call(StaffRedeemStage.callableInvocation);
      final result = await callable.call<Map<String, dynamic>>(data);
      if (changed || identity.currentUser?.uid != uid) {
        throw StateError('Session changed.');
      }
      onStage?.call(StaffRedeemStage.callableResponse);
      return result.data;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<StaffInvitation> create(String email) async {
    // Unique local issuance request ID; not an authorization secret.
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final data = await _call('createStaffInvitation', {
      'email': email,
      'requestId': id,
    });
    if (data['invitationId'] is! String ||
        data['code'] is! String ||
        data['expiresAt'] is! String) {
      throw StateError('Invalid invitation response.');
    }
    return StaffInvitation(
      data['invitationId'],
      data['code'],
      data['expiresAt'],
    );
  }

  static int _sequence = 0;

  @override
  Future<void> revoke(String id) async {
    await _call('revokeStaffInvitation', {'invitationId': id});
  }

  @override
  Future<void> redeem(String code) async {
    var stage = StaffRedeemStage.emulatorConfig;
    StreamSubscription<User?>? subscription;
    var changed = false;
    try {
      if (!FirebaseEmulatorConfig.invitationsAvailable) {
        throw StaffInvitationFailure._(stage, 'emulator-required');
      }
      stage = StaffRedeemStage.authSession;
      final user = (auth ?? FirebaseAuth.instance).currentUser;
      if (user == null) {
        throw StaffInvitationFailure._(stage, 'unauthenticated');
      }
      stage = StaffRedeemStage.authReload;
      subscription = (auth ?? FirebaseAuth.instance).authStateChanges().listen(
        (current) {
          if (current?.uid != user.uid) changed = true;
        },
        onError: (Object _) {
          changed = true;
        },
      );
      await user.reload();
      stage = StaffRedeemStage.authSession;
      final current = (auth ?? FirebaseAuth.instance).currentUser;
      if (changed || current?.uid != user.uid) {
        throw StaffInvitationFailure._(stage, 'session-changed');
      }
      stage = StaffRedeemStage.emailVerification;
      if (current?.emailVerified != true) {
        throw StaffInvitationFailure._(stage, 'email-not-verified');
      }
      stage = StaffRedeemStage.tokenRefresh;
      await current!.getIdToken(true);
      if (changed ||
          (auth ?? FirebaseAuth.instance).currentUser?.uid != user.uid) {
        throw StaffInvitationFailure._(
          StaffRedeemStage.authSession,
          'session-changed',
        );
      }
      await _call('redeemStaffInvitation', {
        'code': code.trim(),
      }, onStage: (value) => stage = value);
    } on StaffInvitationFailure {
      rethrow;
    } catch (error) {
      throw StaffInvitationFailure.fromError(stage, error);
    } finally {
      await subscription?.cancel();
    }
  }
}
