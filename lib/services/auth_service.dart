import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_profile_service.dart';

class AuthFlowException implements Exception {
  final String message;
  const AuthFlowException(this.message);
  @override
  String toString() => message;
}

/// Registration's temporary Firebase session is never a completed login.
class AuthService {
  static const _manualLoginKey = 'velora_registration_requires_login';
  final FirebaseAuth? _firebaseAuth;
  final UserProfileService? _profileService;

  AuthService({FirebaseAuth? auth, UserProfileService? profiles})
    : _firebaseAuth = auth,
      _profileService = profiles;

  FirebaseAuth get _auth => _firebaseAuth ?? FirebaseAuth.instance;
  UserProfileService get _profiles => _profileService ?? UserProfileService();

  static bool isValidResetEmail(String email) =>
      email.trim().length <= 254 &&
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.trim());

  Future<void> sendPasswordResetEmail({required String email}) async {
    final address = email.trim();
    if (!isValidResetEmail(address)) {
      throw FirebaseAuthException(code: 'invalid-email');
    }
    try {
      // No custom action URL: keep Firebase's configured hosted reset flow.
      await _auth.sendPasswordResetEmail(email: address);
    } on FirebaseAuthException catch (error) {
      // Do not disclose account existence on projects with legacy error behavior.
      if (error.code != 'user-not-found' && error.code != 'user-disabled') {
        rethrow;
      }
    }
  }

  Future<void> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // Persist before Firebase creates/signs in the account, including reloads.
    if (!await prefs.setBool(_manualLoginKey, true)) {
      throw const AuthFlowException(
        'Unable to start registration. Please try again.',
      );
    }
    var created = false;
    var profileSaved = false;
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const AuthFlowException(
          'Account creation could not be confirmed. Please try logging in.',
        );
      }
      created = true;
      await user.updateDisplayName(name);
      await _profiles.createUserProfileIfNeeded(user);
      profileSaved = true;
      await _auth.signOut();
      if (_auth.currentUser != null) {
        throw const AuthFlowException(
          'Registration sign-out did not complete.',
        );
      }
      // Only explicit sign-in clears the guard; successful registration does not.
    } catch (_) {
      // Never delete the account or retry account creation behind the user's back.
      try {
        await _auth.signOut();
      } catch (_) {
        /* Startup still requires login. */
      }
      if (!created) rethrow;
      throw AuthFlowException(
        profileSaved
            ? 'Your account and profile were created, but sign-out could not be completed. Please return to Login and sign in manually.'
            : 'Your account was created, but profile setup did not finish. Please return to Login and sign in to retry setup.',
      );
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    final prefs = await SharedPreferences.getInstance();
    final pendingRegistration = prefs.getBool(_manualLoginKey) ?? false;
    var signedIn = false;
    try {
      final result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      signedIn = true;
      final user = result.user;
      if (user == null) {
        throw const AuthFlowException(
          'Login could not be confirmed. Please try again.',
        );
      }
      // Recover an interrupted registration without overwriting an existing profile.
      if (pendingRegistration) {
        await _profiles.createUserProfileIfNeeded(user);
        if (!await prefs.setBool(_manualLoginKey, false)) {
          throw const AuthFlowException(
            'Unable to finish login. Please try again.',
          );
        }
      }
      // No emailVerified gate. Firebase's normal session persistence is retained.
    } catch (error) {
      if (signedIn) {
        try {
          await _auth.signOut();
        } catch (_) {
          /* Registration guard stays set. */
        }
        if (error is! FirebaseAuthException && error is! AuthFlowException) {
          throw const AuthFlowException(
            'Unable to finish profile setup. Please try logging in again.',
          );
        }
      }
      rethrow;
    }
  }

  Future<bool> canRestoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_manualLoginKey) ?? false) {
      try {
        await _auth.signOut();
      } catch (_) {
        /* Never route this session home. */
      }
      return false;
    }
    return _auth.currentUser != null;
  }
}
