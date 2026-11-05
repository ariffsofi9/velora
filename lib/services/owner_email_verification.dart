import 'package:firebase_auth/firebase_auth.dart';

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

class FirebaseOwnerEmailVerification implements OwnerEmailVerification {
  final FirebaseAuth? auth;
  final DateTime Function() now;
  final Duration operationTimeout;
  DateTime? _lastAttempt;
  bool _busy = false;
  FirebaseOwnerEmailVerification({
    this.auth,
    DateTime Function()? now,
    this.operationTimeout = const Duration(seconds: 15),
  }) : now = now ?? DateTime.now;
  FirebaseAuth get _auth => auth ?? FirebaseAuth.instance;
  @override
  String? get currentUid => _auth.currentUser?.uid;
  @override
  Duration get resendRemaining {
    final last = _lastAttempt;
    if (last == null) return Duration.zero;
    final remaining = const Duration(seconds: 30) - now().difference(last);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _same(String uid) {
    if (currentUid != uid) {
      throw const OwnerVerificationException(OwnerVerificationFailure.changed);
    }
  }

  @override
  Future<bool> refreshVerified() async {
    if (_busy) {
      throw const OwnerVerificationException(OwnerVerificationFailure.busy);
    }
    final user = _auth.currentUser;
    if (user == null) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.signedOut,
      );
    }
    _busy = true;
    try {
      await user.reload().timeout(operationTimeout);
      _same(user.uid);
      final refreshed = _auth.currentUser!;
      if (!refreshed.emailVerified) return false;
      final token = await refreshed
          .getIdTokenResult(true)
          .timeout(operationTimeout);
      _same(user.uid);
      return _auth.currentUser!.emailVerified &&
          token.claims?['email_verified'] == true;
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
      _busy = false;
    }
  }

  @override
  Future<void> sendVerification() async {
    if (_busy) {
      throw const OwnerVerificationException(OwnerVerificationFailure.busy);
    }
    final user = _auth.currentUser;
    if (user == null) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.signedOut,
      );
    }
    if (resendRemaining > Duration.zero) {
      throw const OwnerVerificationException(OwnerVerificationFailure.cooldown);
    }
    if (user.emailVerified) return;
    _busy = true;
    _lastAttempt = now();
    try {
      await user.sendEmailVerification().timeout(operationTimeout);
      _same(user.uid);
    } on OwnerVerificationException {
      rethrow;
    } catch (_) {
      throw const OwnerVerificationException(
        OwnerVerificationFailure.unavailable,
      );
    } finally {
      _busy = false;
    }
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
