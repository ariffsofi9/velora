import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'firebase_startup_config.dart';
import 'owner_email_verification.dart';

class WorkspaceCreationRequest {
  final String businessName;
  final String businessType;
  final String address;
  final String inventoryUnit;
  final bool lowStockAlerts;
  final bool expiryReminders;
  final int reminderDays;

  const WorkspaceCreationRequest({
    required this.businessName,
    required this.businessType,
    required this.address,
    required this.inventoryUnit,
    required this.lowStockAlerts,
    required this.expiryReminders,
    required this.reminderDays,
  });

  Map<String, Object> toCallableData() => {
    'businessName': businessName,
    'businessType': businessType,
    'address': address,
    'inventoryUnit': inventoryUnit,
    'lowStockAlerts': lowStockAlerts,
    'expiryReminders': expiryReminders,
    'reminderDays': reminderDays,
  };

  static String normalizeText(String value) =>
      value.trim().replaceAll(RegExp(r'\s+', unicode: true), ' ');
  static String? validateBusinessName(String value) {
    final text = normalizeText(value);
    if (text.length < 2 || text.length > 80) {
      return 'Business name must be between 2 and 80 characters.';
    }
    if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text)) {
      return 'Business name contains invalid characters.';
    }
    return null;
  }

  static String? validateAddress(String value) {
    final text = normalizeText(value);
    if (text.length > 200) {
      return 'Business address must be 200 characters or fewer.';
    }
    if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text)) {
      return 'Business address contains invalid characters.';
    }
    return null;
  }

  WorkspaceCreationRequest normalized() {
    final type = normalizeText(businessType);
    if (validateBusinessName(businessName) != null ||
        validateAddress(address) != null ||
        ![
          'Restaurant',
          'Café',
          'Bakery',
          'cafe',
          'restaurant',
          'bakery',
        ].contains(type) ||
        !['kg', 'g', 'L', 'ml', 'pcs'].contains(inventoryUnit) ||
        ![1, 3, 7].contains(reminderDays)) {
      throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.invalidInput,
      );
    }
    return WorkspaceCreationRequest(
      businessName: normalizeText(businessName),
      businessType: type,
      address: normalizeText(address),
      inventoryUnit: inventoryUnit,
      lowStockAlerts: lowStockAlerts,
      expiryReminders: expiryReminders,
      reminderDays: reminderDays,
    );
  }
}

class WorkspaceCreationResult {
  final bool created;
  const WorkspaceCreationResult({required this.created});
}

enum WorkspaceProvisioningFailure {
  callableNotFound,
  permissionDenied,
  timedOut,
  invalidProfile,
  emailUnverified,
  unauthenticated,
  invalidInput,
  existingMembership,
  unavailable,
  internal,
}

class WorkspaceProvisioningException implements Exception {
  final WorkspaceProvisioningFailure failure;
  const WorkspaceProvisioningException(this.failure);
}

abstract interface class WorkspaceProvisioner {
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  );
}

abstract interface class WorkspaceCreationCallable {
  Future<Map<String, dynamic>> call(Map<String, Object> data);
}

class FirebaseWorkspaceCreationCallable implements WorkspaceCreationCallable {
  final FirebaseFunctions? functions;
  FirebaseWorkspaceCreationCallable({this.functions});
  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    final response =
        await (functions ??
                FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
            .httpsCallable('createWorkspace')
            .call<Map<String, dynamic>>(data);
    return response.data;
  }
}

class FirebaseWorkspaceProvisioner implements WorkspaceProvisioner {
  final WorkspaceCreationCallable _callable;
  final FirebaseOptions Function() _resolveProfile;
  final FirebaseOptions Function() _activeOptions;
  final String? Function() _currentUid;
  final OwnerEmailVerification _verification;
  FirebaseWorkspaceProvisioner({
    FirebaseFunctions? functions,
    WorkspaceCreationCallable? callable,
    FirebaseOptions Function()? resolveProfile,
    FirebaseOptions Function()? activeOptions,
    String? Function()? currentUid,
    OwnerEmailVerification? verification,
  }) : _verification = verification ?? FirebaseOwnerEmailVerification(),
       _callable =
           callable ?? FirebaseWorkspaceCreationCallable(functions: functions),
       _resolveProfile =
           resolveProfile ??
           (() => FirebaseStartupConfig.current.resolve(
             isWeb: kIsWeb,
             platform: defaultTargetPlatform,
           )),
       _activeOptions = activeOptions ?? (() => Firebase.app().options),
       _currentUid =
           currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid);

  @override
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  ) async {
    // Revalidate explicit selection and the initialized app before transport.
    try {
      final expected = _resolveProfile();
      final actual = _activeOptions();
      if (expected.projectId != actual.projectId ||
          expected.appId != actual.appId ||
          expected.apiKey != actual.apiKey ||
          expected.messagingSenderId != actual.messagingSenderId ||
          expected.authDomain != actual.authDomain ||
          expected.storageBucket != actual.storageBucket) {
        throw StateError('Mismatched initialized Firebase app.');
      }
    } catch (_) {
      throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.invalidProfile,
      );
    }
    try {
      final uid = _currentUid();
      if (uid == null || uid.isEmpty) {
        throw const WorkspaceProvisioningException(
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
      final payload = request.normalized().toCallableData();
      try {
        if (_verification.currentUid != uid) {
          throw const WorkspaceProvisioningException(
            WorkspaceProvisioningFailure.unauthenticated,
          );
        }
        if (!await _verification.refreshVerified()) {
          throw const WorkspaceProvisioningException(
            WorkspaceProvisioningFailure.emailUnverified,
          );
        }
      } on OwnerVerificationException catch (error) {
        throw WorkspaceProvisioningException(
          error.failure == OwnerVerificationFailure.signedOut ||
                  error.failure == OwnerVerificationFailure.changed
              ? WorkspaceProvisioningFailure.unauthenticated
              : WorkspaceProvisioningFailure.unavailable,
        );
      }
      if (_currentUid() != uid || _verification.currentUid != uid) {
        throw const WorkspaceProvisioningException(
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
      final data = await _callable.call(payload);
      if (_currentUid() != uid) {
        throw const WorkspaceProvisioningException(
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
      if (data['created'] is! bool || data['cafeId'] is! String) {
        throw const WorkspaceProvisioningException(
          WorkspaceProvisioningFailure.internal,
        );
      }
      return WorkspaceCreationResult(created: data['created'] as bool);
    } on FirebaseFunctionsException catch (error) {
      throw WorkspaceProvisioningException(_mapError(error));
    } on TimeoutException {
      throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.timedOut,
      );
    } on WorkspaceProvisioningException {
      rethrow;
    } catch (_) {
      throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.unavailable,
      );
    }
  }

  static WorkspaceProvisioningFailure _mapError(
    FirebaseFunctionsException error,
  ) {
    // Existing backend has no reason details. Match its exact public email error;
    // all other precondition failures remain membership conflicts.
    if (error.code == 'failed-precondition' &&
        error.message ==
            'Verify your email and refresh your sign-in before creating a workspace.') {
      return WorkspaceProvisioningFailure.emailUnverified;
    }
    return switch (error.code) {
      'not-found' => WorkspaceProvisioningFailure.callableNotFound,
      'permission-denied' => WorkspaceProvisioningFailure.permissionDenied,
      'deadline-exceeded' => WorkspaceProvisioningFailure.timedOut,
      'unauthenticated' => WorkspaceProvisioningFailure.unauthenticated,
      'invalid-argument' => WorkspaceProvisioningFailure.invalidInput,
      'already-exists' ||
      'failed-precondition' => WorkspaceProvisioningFailure.existingMembership,
      'unavailable' => WorkspaceProvisioningFailure.unavailable,
      _ => WorkspaceProvisioningFailure.internal,
    };
  }
}
