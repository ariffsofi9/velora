import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'android_pilot_policy.dart';

enum OwnerVerificationFailure {
  signedOut,
  changed,
  busy,
  cooldown,
  unavailable,
}

class OwnerVerificationException implements Exception {
  final OwnerVerificationFailure failure;
  const OwnerVerificationException(this.failure);
  @override
  String toString() => 'Email verification could not be completed.';
}

abstract interface class OwnerEmailVerification {
  String? get currentUid;
  Duration get resendRemaining;
  Future<bool> refreshVerified();
  Future<void> sendVerification();
  Future<void> signOut();
}

/// Fences work to the first Auth event. A later event, even for the same
/// UID, invalidates this verification session.
final class EmailVerificationSession {
  final FirebaseAuth auth;
  final String uid;
  final _initial = Completer<void>();
  late final StreamSubscription<User?> _subscription;
  bool _changed = false;

  EmailVerificationSession(this.auth, this.uid) {
    _subscription = auth.authStateChanges().listen(
      (user) {
        if (_initial.isCompleted || user?.uid != uid) _invalidate();
        if (!_initial.isCompleted) _initial.complete();
      },
      onError: (Object _) => _invalidate(),
      onDone: _invalidate,
    );
  }

  void _invalidate() {
    _changed = true;
    if (!_initial.isCompleted) _initial.complete();
  }

  bool get isCurrent =>
      _initial.isCompleted && !_changed && auth.currentUser?.uid == uid;

  Future<void> ready(Duration timeout) async {
    await _initial.future.timeout(timeout);
    requireCurrent();
  }

  void requireCurrent() {
    if (!isCurrent) {
      throw const OwnerVerificationException(OwnerVerificationFailure.changed);
    }
  }

  Future<void> close() {
    _invalidate();
    return _subscription.cancel();
  }
}

class FirebaseOwnerEmailVerification implements OwnerEmailVerification {
  static const defaultTimeout = Duration(seconds: 15);
  final AndroidPilotPolicy? _pilotPolicy;
  final FirebaseAuth? auth;
  final EmailVerificationSession? session;
  final DateTime Function() now;
  final Duration operationTimeout;
  DateTime? _lastAttempt;
  bool _busy = false;
  FirebaseOwnerEmailVerification({
    this.auth,
    this.session,
    AndroidPilotPolicy? pilotPolicy,
    DateTime Function()? now,
    this.operationTimeout = defaultTimeout,
  }) : _pilotPolicy = pilotPolicy,
       now = now ?? DateTime.now;

  void _requireCapability(AndroidPilotCapability capability) {
    final policy = _pilotPolicy;
    if (policy != null &&
        policy.state != AndroidPilotState.normal &&
        (!policy.isValid || !policy.permits(capability))) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.unavailable,
      );
    }
  }

  FirebaseAuth get _auth => session?.auth ?? auth ?? FirebaseAuth.instance;
  @override
  String? get currentUid => _auth.currentUser?.uid;
  @override
  Duration get resendRemaining {
    final last = _lastAttempt;
    if (last == null) return Duration.zero;
    final remaining = const Duration(seconds: 30) - now().difference(last);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  @override
  Future<bool> refreshVerified() async {
    _requireCapability(AndroidPilotCapability.existingAccountAuthentication);
    final policy = _pilotPolicy;
    if (policy?.isRestricted == true &&
        !policy!.bindings.any((binding) => binding.uid == currentUid)) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.signedOut,
      );
    }
    return _inSession((bound) async {
      await _auth.currentUser!.reload().timeout(operationTimeout);
      bound.requireCurrent();
      final refreshed = _auth.currentUser!;
      if (!refreshed.emailVerified) return false;
      final token = await refreshed
          .getIdTokenResult(true)
          .timeout(operationTimeout);
      bound.requireCurrent();
      return _auth.currentUser!.emailVerified &&
          token.claims?['email_verified'] == true;
    });
  }

  Future<T> _inSession<T>(
    Future<T> Function(EmailVerificationSession) action,
  ) async {
    if (_busy) {
      throw const OwnerVerificationException(OwnerVerificationFailure.busy);
    }
    final uid = currentUid;
    if (uid == null) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.signedOut,
      );
    }
    _busy = true;
    EmailVerificationSession? temporary;
    try {
      final bound =
          session ?? (temporary = EmailVerificationSession(_auth, uid));
      await bound.ready(operationTimeout);
      final result = await action(bound);
      bound.requireCurrent();
      return result;
    } on OwnerVerificationException {
      rethrow;
    } on FirebaseAuthException catch (error) {
      throw OwnerVerificationException(
        [
              'user-disabled',
              'user-token-expired',
              'invalid-user-token',
              'user-not-found',
            ].contains(error.code)
            ? OwnerVerificationFailure.signedOut
            : OwnerVerificationFailure.unavailable,
      );
    } catch (_) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.unavailable,
      );
    } finally {
      try {
        await temporary?.close();
      } finally {
        _busy = false;
      }
    }
  }

  @override
  Future<void> sendVerification() async {
    _requireCapability(AndroidPilotCapability.verificationEmail);
    await _inSession((_) async {
      if (resendRemaining > Duration.zero) {
        throw const OwnerVerificationException(
          OwnerVerificationFailure.cooldown,
        );
      }
      final user = _auth.currentUser!;
      if (user.emailVerified) return;
      _lastAttempt = now();
      await user.sendEmailVerification().timeout(operationTimeout);
    });
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut().timeout(operationTimeout);
      if (currentUid != null) {
        throw const OwnerVerificationException(
          OwnerVerificationFailure.unavailable,
        );
      }
    } catch (_) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.unavailable,
      );
    }
  }
}
