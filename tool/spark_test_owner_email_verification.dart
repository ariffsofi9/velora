// The caller supplies an existing named TEST Auth
// session and the privately approved Owner UID. This helper never initializes
// an app, obtains a new session, or accesses Firestore.
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:velora/firebase_spark_test_options.dart';

enum SparkTestOwnerEmailFailure {
  configRejected('CONFIG_REJECTED'),
  browserPreflightFailed('BROWSER_PREFLIGHT_FAILED'),
  authSetupFailed('AUTH_SETUP_FAILED'),
  signInFailed('SIGN_IN_FAILED'),
  credentialsRejected('CREDENTIALS_REJECTED'),
  authConfiguration('AUTH_CONFIGURATION'),
  networkUnavailable('NETWORK_UNAVAILABLE'),
  rateLimited('RATE_LIMITED'),
  ownerMismatch('OWNER_MISMATCH'),
  reloadFailed('RELOAD_FAILED'),
  reloadTimeout('RELOAD_TIMEOUT'),
  cleanupFailed('CLEANUP_FAILED');

  const SparkTestOwnerEmailFailure(this.code);

  final String code;
}

final class SparkTestOwnerEmailResult {
  const SparkTestOwnerEmailResult._(this.status, this.failure);

  const SparkTestOwnerEmailResult.unknown(SparkTestOwnerEmailFailure failure)
    : this._('UNKNOWN', failure);

  static const verified = SparkTestOwnerEmailResult._('VERIFIED', null);
  static const notVerified = SparkTestOwnerEmailResult._('NOT_VERIFIED', null);

  final String status;
  final SparkTestOwnerEmailFailure? failure;

  String get displayText {
    final reason = failure;
    return reason == null ? status : '$status — ${reason.code}';
  }
}

final class SparkTestOwnerEmailVerification {
  static const appName = 'velora-spark-test';
  static const timeout = Duration(seconds: 5);

  final bool _isWeb;
  bool _used = false;

  SparkTestOwnerEmailVerification() : _isWeb = kIsWeb;

  @visibleForTesting
  SparkTestOwnerEmailVerification.forTesting({required bool isWeb})
    : _isWeb = isWeb;

  /// Consume one check and return only a status and a fixed failure reason.
  Future<SparkTestOwnerEmailResult> check({
    required FirebaseAuth? existingAuth,
    required String? approvedOwnerUid,
  }) async {
    const configRejected = SparkTestOwnerEmailResult.unknown(
      SparkTestOwnerEmailFailure.configRejected,
    );
    const ownerMismatch = SparkTestOwnerEmailResult.unknown(
      SparkTestOwnerEmailFailure.ownerMismatch,
    );
    if (_used) return configRejected;
    _used = true;
    if (!_isWeb ||
        existingAuth == null ||
        approvedOwnerUid == null ||
        approvedOwnerUid.isEmpty ||
        approvedOwnerUid.trim() != approvedOwnerUid) {
      return configRejected;
    }

    var stage = SparkTestOwnerEmailFailure.authSetupFailed;
    try {
      final app = existingAuth.app;
      if (app.name != appName || app.options != SparkTestFirebaseOptions.web) {
        return configRejected;
      }
      final user = existingAuth.currentUser;
      if (user == null || user.uid != approvedOwnerUid) return ownerMismatch;

      stage = SparkTestOwnerEmailFailure.reloadFailed;
      try {
        await user.reload().timeout(timeout);
      } on TimeoutException {
        return const SparkTestOwnerEmailResult.unknown(
          SparkTestOwnerEmailFailure.reloadTimeout,
        );
      }
      final refreshedApp = existingAuth.app;
      if (refreshedApp.name != appName ||
          refreshedApp.options != SparkTestFirebaseOptions.web) {
        return configRejected;
      }
      final refreshed = existingAuth.currentUser;
      if (refreshed == null || refreshed.uid != approvedOwnerUid) {
        return ownerMismatch;
      }
      return refreshed.emailVerified
          ? SparkTestOwnerEmailResult.verified
          : SparkTestOwnerEmailResult.notVerified;
    } catch (_) {
      return SparkTestOwnerEmailResult.unknown(stage);
    }
  }
}
