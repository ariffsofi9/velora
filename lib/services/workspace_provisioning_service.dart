import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'workspace_store.dart';
import 'workspace_resolver.dart';

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

  /// False only when this provisioner has not entered a transaction at all.
  /// Defaults conservatively for injected/legacy callers and unknown outcomes.
  final bool outcomeUncertain;
  const WorkspaceProvisioningException(
    this.failure, {
    this.outcomeUncertain = true,
  });
}

abstract interface class WorkspaceProvisioner {
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  );
}

/// Injectable transaction boundary; production uses the installed Firestore SDK.
abstract interface class WorkspaceBootstrapTransaction
    implements WorkspaceReader {
  void set(String path, Map<String, dynamic> data);
}

abstract interface class WorkspaceBootstrapStore {
  String newCafeId();
  Object serverTimestamp();
  Future<T> runTransaction<T>(
    Future<T> Function(WorkspaceBootstrapTransaction) action,
  );
}

class FirestoreWorkspaceBootstrapStore implements WorkspaceBootstrapStore {
  final FirebaseFirestore? firestore;
  FirestoreWorkspaceBootstrapStore({this.firestore});
  FirebaseFirestore get _db => firestore ?? FirebaseFirestore.instance;
  @override
  String newCafeId() => _db.collection('cafes').doc().id;
  @override
  Object serverTimestamp() => FieldValue.serverTimestamp();
  @override
  Future<T> runTransaction<T>(
    Future<T> Function(WorkspaceBootstrapTransaction) action,
  ) => _db.runTransaction((tx) => action(_BootstrapTransaction(_db, tx)));
}

class _BootstrapTransaction implements WorkspaceBootstrapTransaction {
  final FirebaseFirestore db;
  final Transaction tx;
  _BootstrapTransaction(this.db, this.tx);
  @override
  Future<Map<String, dynamic>?> readDocument(String path) async =>
      (await tx.get(db.doc(path))).data();
  // Flutter has no Transaction.create(). Local draft Rules allow create only,
  // require all three documents absent before commit, and deny update/delete.
  @override
  void set(String path, Map<String, dynamic> data) =>
      tx.set(db.doc(path), data);
}

class FirebaseWorkspaceProvisioner implements WorkspaceProvisioner {
  final WorkspaceBootstrapStore _store;
  final FirebaseOptions Function() _resolveProfile;
  final FirebaseOptions Function() _activeOptions;
  final String? Function() _currentUid;
  final OwnerEmailVerification _verification;
  FirebaseWorkspaceProvisioner({
    WorkspaceBootstrapStore? store,
    FirebaseOptions Function()? resolveProfile,
    FirebaseOptions Function()? activeOptions,
    String? Function()? currentUid,
    OwnerEmailVerification? verification,
  }) : _verification = verification ?? FirebaseOwnerEmailVerification(),
       _store = store ?? FirestoreWorkspaceBootstrapStore(),
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
    var transactionStarted = false;
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
      final input = request.normalized();
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
          outcomeUncertain: false,
        );
      }
      if (_currentUid() != uid || _verification.currentUid != uid) {
        throw const WorkspaceProvisioningException(
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
      final cafeId = _store.newCafeId(); // Stable across SDK callback retries.
      if (!_validId(uid) || !_validId(cafeId)) _conflict();
      transactionStarted = true;
      final result = await _store.runTransaction((tx) async {
        _sameUser(uid);
        final mapping = await tx.readDocument('user_cafe_memberships/$uid');
        _sameUser(uid);
        if (mapping != null) {
          final existingId = mapping['cafeId'];
          if (!_validId(existingId) || !_link(mapping, uid, existingId)) {
            _conflict();
          }
          final cafe = await tx.readDocument('cafes/$existingId');
          final member = await tx.readDocument(
            'cafes/$existingId/members/$uid',
          );
          _sameUser(uid);
          if (cafe == null ||
              member == null ||
              !_link(member, uid, existingId) ||
              member['role'] != 'owner' ||
              cafe['ownerUid'] != uid ||
              cafe['status'] != 'active' ||
              cafe['schemaVersion'] != 1) {
            _conflict();
          }
          try {
            WorkspaceResolver.validateGenerationPair(mapping, member);
          } catch (_) {
            _conflict();
          }
          final prefs = cafe['inventoryPreferences'];
          if (cafe['name'] != input.businessName ||
              cafe['businessType'] != _type(input.businessType) ||
              cafe['address'] != input.address ||
              prefs is! Map ||
              prefs['unit'] != input.inventoryUnit ||
              prefs['lowStockAlerts'] != input.lowStockAlerts ||
              prefs['expiryReminders'] != input.expiryReminders ||
              prefs['reminderDays'] != input.reminderDays) {
            _conflict();
          }
          return const WorkspaceCreationResult(created: false);
        }
        // Do not read nonexistent cafe/member paths: protected reads are denied.
        // Server-side Rules check their absence and the final three-way graph.
        _sameUser(uid);
        final now = _store.serverTimestamp();
        final base = <String, dynamic>{
          'status': 'active',
          'schemaVersion': 1,
          'createdAt': now,
          'updatedAt': now,
        };
        tx.set('cafes/$cafeId', {
          ...base,
          'ownerUid': uid,
          'name': input.businessName,
          'businessType': _type(input.businessType),
          'address': input.address,
          'inventoryPreferences': {
            'unit': input.inventoryUnit,
            'lowStockAlerts': input.lowStockAlerts,
            'expiryReminders': input.expiryReminders,
            'reminderDays': input.reminderDays,
          },
        });
        tx.set('cafes/$cafeId/members/$uid', {
          ...base,
          'uid': uid,
          'cafeId': cafeId,
          'role': 'owner',
        });
        tx.set('user_cafe_memberships/$uid', {
          ...base,
          'uid': uid,
          'cafeId': cafeId,
        });
        return const WorkspaceCreationResult(created: true);
      });
      _sameUser(uid);
      return result;
    } on FirebaseException catch (error) {
      throw WorkspaceProvisioningException(switch (error.code) {
        'permission-denied' => WorkspaceProvisioningFailure.permissionDenied,
        'unauthenticated' => WorkspaceProvisioningFailure.unauthenticated,
        'already-exists' => WorkspaceProvisioningFailure.existingMembership,
        'deadline-exceeded' => WorkspaceProvisioningFailure.timedOut,
        'aborted' ||
        'unavailable' ||
        'failed-precondition' ||
        'network-request-failed' => WorkspaceProvisioningFailure.unavailable,
        _ => WorkspaceProvisioningFailure.internal,
      }, outcomeUncertain: transactionStarted);
    } on TimeoutException {
      throw WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.timedOut,
        outcomeUncertain: transactionStarted,
      );
    } on WorkspaceProvisioningException {
      rethrow;
    } catch (_) {
      throw WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.unavailable,
        outcomeUncertain: transactionStarted,
      );
    }
  }

  void _sameUser(String uid) {
    if (_currentUid() != uid || _verification.currentUid != uid) {
      throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.unauthenticated,
      );
    }
  }

  static bool _validId(dynamic value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 128 &&
      value.trim() == value &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !RegExp(r'[\x00-\x1f]').hasMatch(value);
  static bool _link(Map<String, dynamic> value, String uid, String cafeId) =>
      value['uid'] == uid &&
      value['cafeId'] == cafeId &&
      value['status'] == 'active' &&
      value['schemaVersion'] == 1;
  static String _type(String type) =>
      const {
        'cafe': 'Caf\u00e9',
        'restaurant': 'Restaurant',
        'bakery': 'Bakery',
      }[type] ??
      type;
  static Never _conflict() => throw const WorkspaceProvisioningException(
    WorkspaceProvisioningFailure.existingMembership,
  );
}
