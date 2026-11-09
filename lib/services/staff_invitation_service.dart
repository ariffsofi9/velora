import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

import 'firebase_emulator_config.dart';
import '../models/cafe_workspace.dart';

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
  final bool outcomeUnknown;
  const StaffInvitationFailure._(
    this.stage,
    this.code, {
    this.outcomeUnknown = false,
  });

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
    final code = error is TimeoutException
        ? 'deadline-exceeded'
        : error is FirebaseException && allowed.contains(error.code)
        ? error.code
        : 'unknown';
    // Only explicit callable rejections establish rejection after invocation.
    // Transport, decoding and session errors cannot rule out a server commit.
    const rejections = {
      'unauthenticated',
      'permission-denied',
      'invalid-argument',
      'already-exists',
      'failed-precondition',
      'resource-exhausted',
      'not-found',
    };
    final afterInvocation =
        stage == StaffRedeemStage.callableInvocation ||
        stage == StaffRedeemStage.callableResponse;
    final rejected =
        stage == StaffRedeemStage.callableInvocation &&
        error is FirebaseFunctionsException &&
        rejections.contains(code);
    return StaffInvitationFailure._(
      stage,
      code,
      outcomeUnknown: afterInvocation && !rejected,
    );
  }

  @override
  String toString() => outcomeUnknown
      ? 'Invitation outcome unknown at ${stage.name} ($code).'
      : 'Invitation action failed at ${stage.name} ($code).';
}

/// The response boundary shared by real calls and offline callback tests.
/// It never retries, logs response data or grants workspace authority.
class StaffInvitationAcknowledgement {
  static Future<Map<String, dynamic>> confirm(
    String field,
    Future<Object?> Function() invoke,
  ) async {
    Object? response;
    try {
      response = await invoke();
    } catch (error) {
      throw StaffInvitationFailure.fromError(
        StaffRedeemStage.callableInvocation,
        error,
      );
    }
    if (response is! Map<String, dynamic> ||
        response[field] is! bool ||
        response[field] != true) {
      throw const StaffInvitationFailure._(
        StaffRedeemStage.callableResponse,
        'invalid-acknowledgement',
        outcomeUnknown: true,
      );
    }
    return response;
  }
}

class StaffInvitation {
  final String id;
  final String code;
  final String expiresAt;
  const StaffInvitation(this.id, this.code, this.expiresAt);
}

/// In-memory safety only: no recovery, persistence or cross-tab/device guarantee.
/// Retained per Auth instance and UID even when a page/service is reconstructed.
/// Signing out or changing email does not resolve an earlier uncertain issuance.
class StaffInvitationCreation {
  static final _sessions = Expando<Map<String, StaffInvitationCreation>>();
  static StaffInvitationCreation forSession(Object session, String uid) {
    final owners = _sessions[session] ??= <String, StaffInvitationCreation>{};
    return owners.putIfAbsent(uid, () => StaffInvitationCreation());
  }

  bool _blocked = false;
  bool _pending = false;
  bool get blocked => _blocked;

  // Monotonic: abandoning delivery or observing an unknown result never permits
  // fresh issuance. This stores no response/code and provides no recovery.
  void requireReconciliation() => _blocked = true;

  static StaffInvitation validate(Object? response, DateTime now) {
    if (response is Map<String, dynamic>) {
      final id = response['invitationId'];
      final code = response['code'];
      final expiry = response['expiresAt'];
      if (id is String &&
          id.length == 32 &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch(id) &&
          code is String &&
          code.length == 97 &&
          RegExp(r'^[a-f0-9]{32}\.[a-f0-9]{64}$').hasMatch(code) &&
          code.startsWith('$id.') &&
          expiry is String &&
          RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
          ).hasMatch(expiry)) {
        final parsed = DateTime.tryParse(expiry);
        // Round-trip rejects DateTime's permissive calendar overflow normalization.
        if (parsed != null &&
            parsed.toUtc().toIso8601String() == expiry &&
            parsed.isAfter(now.toUtc())) {
          return StaffInvitation(id, code, expiry);
        }
      }
    }
    throw const StaffInvitationFailure._(
      StaffRedeemStage.callableResponse,
      'invalid-creation-acknowledgement',
      outcomeUnknown: true,
    );
  }

  Future<StaffInvitation> issue(
    Future<Object?> Function(void Function(StaffRedeemStage) onStage)
    operation, {
    DateTime Function()? clock,
  }) async {
    if (_blocked) {
      throw const StaffInvitationFailure._(
        StaffRedeemStage.callableResponse,
        'creation-unconfirmed',
        outcomeUnknown: true,
      );
    }
    if (_pending) {
      throw const StaffInvitationFailure._(
        StaffRedeemStage.callableConfig,
        'creation-in-progress',
      );
    }
    _pending = true;
    var stage = StaffRedeemStage.callableConfig;
    var invoked = false;
    try {
      final response = await operation((value) {
        stage = value;
        if (value == StaffRedeemStage.callableInvocation) invoked = true;
      });
      stage = StaffRedeemStage.callableResponse;
      return validate(response, (clock ?? DateTime.now)());
    } catch (error) {
      var failure = error is StaffInvitationFailure
          ? error
          : StaffInvitationFailure.fromError(stage, error);
      // A duplicate receipt may describe an earlier commit, never recovered success.
      if (invoked && failure.code == 'already-exists') {
        failure = const StaffInvitationFailure._(
          StaffRedeemStage.callableInvocation,
          'already-exists',
          outcomeUnknown: true,
        );
      }
      if (invoked && failure.outcomeUnknown) _blocked = true;
      throw failure;
    } finally {
      _pending = false;
    }
  }
}

abstract interface class StaffInvitations {
  Future<StaffInvitation> create(
    String email, {
    required CafeWorkspace workspace,
  });
  Future<void> revoke(String id, {required CafeWorkspace workspace});
  Future<void> redeem(String code);
}

class FirebaseStaffInvitations implements StaffInvitations {
  final FirebaseFunctions? functions;
  final FirebaseAuth? auth;
  FirebaseStaffInvitations({this.functions, this.auth});

  bool get creationBlocked {
    final identity = auth ?? FirebaseAuth.instance;
    final uid = identity.currentUser?.uid;
    return uid != null &&
        StaffInvitationCreation.forSession(identity, uid).blocked;
  }

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, Object> data, {
    void Function(StaffRedeemStage)? onStage,
    String? acknowledgement,
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
      Future<Map<String, dynamic>> invoke() async {
        final result = await callable.call<Map<String, dynamic>>(data);
        if (changed || identity.currentUser?.uid != uid) {
          throw StateError('Session changed.');
        }
        onStage?.call(StaffRedeemStage.callableResponse);
        return result.data;
      }

      return acknowledgement == null
          ? await invoke()
          : await StaffInvitationAcknowledgement.confirm(
              acknowledgement,
              invoke,
            );
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<StaffInvitation> create(
    String email, {
    required CafeWorkspace workspace,
  }) async {
    final identity = auth ?? FirebaseAuth.instance;
    final uid = identity.currentUser?.uid;
    if (uid == null) {
      throw const StaffInvitationFailure._(
        StaffRedeemStage.authSession,
        'unauthenticated',
      );
    }
    final expected = _ownerData(workspace);
    final creation = StaffInvitationCreation.forSession(identity, uid);
    return creation.issue((onStage) async {
      // Unique local issuance request ID; not an authorization secret.
      final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
      return _call('createStaffInvitation', {
        'email': email,
        'requestId': id,
        ...expected,
      }, onStage: onStage);
    });
  }

  static int _sequence = 0;

  @override
  Future<void> revoke(String id, {required CafeWorkspace workspace}) async {
    var stage = StaffRedeemStage.callableConfig;
    try {
      final expected = _ownerData(workspace);
      await _call(
        'revokeStaffInvitation',
        {'invitationId': id, ...expected},
        acknowledgement: 'revoked',
        onStage: (value) => stage = value,
      );
    } on StaffInvitationFailure {
      rethrow;
    } catch (error) {
      throw StaffInvitationFailure.fromError(stage, error);
    }
  }

  // Capture the caller's original context; never refresh or adopt a new episode.
  // These are request preconditions, not backend authorization.
  Map<String, Object> _ownerData(CafeWorkspace workspace) {
    bool validId(String value) =>
        value.isNotEmpty &&
        value.length <= 128 &&
        value.trim() == value &&
        !['.', '..'].contains(value) &&
        !RegExp(r'[/\\\x00-\x1f]').hasMatch(value);
    if (!validId(workspace.uid) ||
        !validId(workspace.cafeId) ||
        (auth ?? FirebaseAuth.instance).currentUser?.uid != workspace.uid ||
        workspace.ownerUid != workspace.uid ||
        workspace.role != CafeRole.owner ||
        workspace.membershipGeneration < 0 ||
        workspace.membershipGeneration > 9007199254740991) {
      throw const StaffInvitationFailure._(
        StaffRedeemStage.callableConfig,
        'invalid-argument',
      );
    }
    return {
      'expectedCafeId': workspace.cafeId,
      'expectedMembershipGeneration': workspace.membershipGeneration,
    };
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
      await _call(
        'redeemStaffInvitation',
        {'code': code.trim()},
        acknowledgement: 'joined',
        onStage: (value) => stage = value,
      );
    } on StaffInvitationFailure {
      rethrow;
    } catch (error) {
      throw StaffInvitationFailure.fromError(stage, error);
    } finally {
      await subscription?.cancel();
    }
  }
}
