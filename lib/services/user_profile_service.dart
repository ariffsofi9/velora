import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';

class ProfileValidationException implements Exception {
  final String message;
  const ProfileValidationException(this.message);
  @override
  String toString() => message;
}

class UserProfileService {
  final FirebaseFirestore? _instance;
  final void Function(String message)? _debugLog;

  UserProfileService({
    FirebaseFirestore? firestore,
    void Function(String message)? debugLog,
  }) : _instance = firestore,
       _debugLog = debugLog;

  FirebaseFirestore get _firestore => _instance ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _usersRef {
    return _firestore.collection('users');
  }

  Future<void> createUserProfileIfNeeded(
    User user, {
    String? initialUsername,
  }) async {
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
