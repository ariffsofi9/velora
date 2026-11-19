import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
import 'android_pilot_policy.dart';

class ProfileValidationException implements Exception {
  final String message;
  const ProfileValidationException(this.message);
  @override
  String toString() => message;
}

class UserProfileService {
  final FirebaseFirestore? _instance;
  final void Function(String message)? _debugLog;
  final AndroidPilotPolicy? _pilotPolicy;

  UserProfileService({
    FirebaseFirestore? firestore,
    void Function(String message)? debugLog,
    AndroidPilotPolicy? pilotPolicy,
  }) : _instance = firestore,
       _debugLog = debugLog,
       _pilotPolicy = pilotPolicy;

  void _requireCapability(AndroidPilotCapability capability) {
    final policy = _pilotPolicy;
    if (policy == null || policy.state == AndroidPilotState.normal) return;
    if (!policy.isValid || !policy.permits(capability)) {
      throw const ProfileValidationException(
        'This profile operation is unavailable under the pilot policy.',
      );
    }
  }

  FirebaseFirestore get _firestore => _instance ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _usersRef {
    return _firestore.collection('users');
  }

  Future<void> createUserProfileIfNeeded(
    User user, {
    String? initialUsername,
  }) async {
    _requireCapability(AndroidPilotCapability.profileWrites);
    var operation = 'read-self-profile';
    try {
      final docRef = _usersRef.doc(user.uid);
      final doc = await docRef.get();

      if (doc.exists) return;

      final displayName = initialUsername ?? user.displayName;
      final username = displayName == null || displayName.trim().isEmpty
          ? 'Velora User'
          : displayName;
      final photoUrl = user.photoURL ?? '';
      _validate(username, photoUrl);
      // Email remains Auth-owned, with no trimming or fabricated fallback.
      if (user.email == null) {
        throw const ProfileValidationException(
          'An account email is required to create your profile.',
        );
      }

      operation = 'create-self-profile';
      await docRef.set({
        'username': username,
        'email': user.email ?? '',
        'photoUrl': photoUrl,
        // Display metadata only; workspace membership is authoritative.
        'role': 'owner',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      _diagnose(operation, error);
      rethrow;
    }
  }

  /// No creation, repair, cached fallback or presentation defaults. This is
  /// profile eligibility only; users.role never authorizes workspace access.
  /// AuthService fences the authenticated session around this read.
  Future<UserProfile> readExistingServerProfile(User user) async {
    _requireCapability(AndroidPilotCapability.existingAccountAuthentication);
    final policy = _pilotPolicy;
    if (policy?.isRestricted == true &&
        (!user.emailVerified ||
            !policy!.bindings.any((binding) => binding.uid == user.uid))) {
      throw const ProfileValidationException('Pilot account is not eligible.');
    }
    final doc = await _usersRef
        .doc(user.uid)
        .get(const GetOptions(source: Source.server));
    final data = doc.data();
    if (!doc.exists ||
        doc.id != user.uid ||
        doc.metadata.isFromCache ||
        doc.metadata.hasPendingWrites ||
        data == null ||
        data['username'] is! String ||
        data['email'] is! String ||
        data['email'] != user.email ||
        (data['email'] as String).isEmpty ||
        data['photoUrl'] is! String ||
        (data['role'] != 'owner' && data['role'] != 'staff') ||
        data['createdAt'] is! Timestamp ||
        data['updatedAt'] is! Timestamp) {
      throw const ProfileValidationException(
        'An existing server-confirmed profile is required.',
      );
    }
    _validate(data['username'] as String, data['photoUrl'] as String);
    return UserProfile.fromMap(doc.id, data);
  }

  void _diagnose(String operation, FirebaseException error) {
    if (!kDebugMode) return;
    String safe(String value) {
      final normalized = value.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9._-]'),
        '-',
      );
      return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
    }

    (_debugLog ?? debugPrint)(
      '[UserProfileService] operation=$operation '
      'plugin=${safe(error.plugin)} code=${safe(error.code)}',
    );
  }

  Stream<UserProfile?> getUserProfileStream(String uid) {
    // The legacy stream can deliver cached data and has no auth-session fence.
    // Pilot consumers must use the server-only eligibility path instead.
    if (_pilotPolicy != null &&
        _pilotPolicy.state != AndroidPilotState.normal) {
      throw const ProfileValidationException(
        'Profile streams are unavailable under the pilot policy.',
      );
    }
    return _usersRef.doc(uid).snapshots().map((doc) {
      if (!doc.exists || doc.data() == null) return null;

      return UserProfile.fromMap(doc.id, doc.data()!);
    });
  }

  Future<void> updateUserProfile({
    required String uid,
    required String username,
    required String photoUrl,
  }) async {
    _requireCapability(AndroidPilotCapability.profileWrites);
    _validate(username, photoUrl);
    await _usersRef.doc(uid).update({
      'username': username,
      'photoUrl': photoUrl,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static void _validate(String username, String photoUrl) {
    if (username.trim().isEmpty) {
      throw const ProfileValidationException('Please enter a name.');
    }
    if (username.length > 80) {
      throw const ProfileValidationException(
        'Name must be 80 characters or fewer.',
      );
    }
    if (photoUrl.length > 2048) {
      throw const ProfileValidationException(
        'Photo URL must be 2048 characters or fewer.',
      );
    }
  }
}
