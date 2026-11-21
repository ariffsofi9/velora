import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_profile_service.dart';
import 'android_pilot_policy.dart';
import 'owner_email_verification.dart';

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
  final AndroidPilotPolicy? _pilotPolicy;

  AuthService({
    FirebaseAuth? auth,
    UserProfileService? profiles,
    AndroidPilotPolicy? pilotPolicy,
  }) : _firebaseAuth = auth,
       _profileService = profiles,
       _pilotPolicy = pilotPolicy;

  FirebaseAuth get _auth => _firebaseAuth ?? FirebaseAuth.instance;
  FirebaseAuth get firebaseAuth => _auth;
  UserProfileService get _profiles =>
      _profileService ?? UserProfileService(pilotPolicy: _pilotPolicy);

  void _requireCapability(AndroidPilotCapability capability) {
    final policy = _pilotPolicy;
    if (policy == null || policy.state == AndroidPilotState.normal) return;
    if (!policy.isValid || !policy.permits(capability)) {
      throw const AuthFlowException(
        'This authentication operation is unavailable under the pilot policy.',
      );
    }
  }

  static bool isValidResetEmail(String email) =>
      email.trim().length <= 254 &&
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.trim());

  Future<void> sendPasswordResetEmail({required String email}) async {
    _requireCapability(AndroidPilotCapability.passwordResetEmail);
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
    _requireCapability(AndroidPilotCapability.registration);
    final prefs = await SharedPreferences.getInstance();
    final previousRegistrationGuard = prefs.getBool(_manualLoginKey) ?? false;
    // Persist before Firebase creates/signs in the account, including reloads.
    if (!await prefs.setBool(_manualLoginKey, true)) {
      throw const AuthFlowException(
        'Unable to start registration. Please try again.',
      );
    }
    var created = false;
    var profileSaved = false;
    EmailVerificationSession? session;
    try {
      final auth = _auth;
      final credential = await auth.createUserWithEmailAndPassword(
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
      session = EmailVerificationSession(auth, user.uid);
      await session.ready(FirebaseOwnerEmailVerification.defaultTimeout);
      await user.updateDisplayName(name);
      session.requireCurrent();
      await _profiles.createUserProfileIfNeeded(
        user,
        initialUsername: name.trim(),
      );
      profileSaved = true;
      session.requireCurrent();
      try {
        await FirebaseOwnerEmailVerification(
          pilotPolicy: _pilotPolicy,
          session: session,
        ).sendVerification();
      } catch (_) {
        // Firebase may have accepted the email request. Keep the account and
        // let the user check their inbox or resend after manual sign-in.
      }
      session.requireCurrent();
      await auth.signOut();
      if (auth.currentUser != null) {
        throw const AuthFlowException(
          'Registration sign-out did not complete.',
        );
      }
      // Only explicit sign-in clears the guard; successful registration does not.
    } catch (_) {
      // Never delete the account or retry account creation behind the user's back.
      if (!created || session?.isCurrent == true) {
        try {
          await _auth.signOut();
        } catch (_) {
          /* Startup still requires login. */
        }
      }
      if (!created) {
        // A rejected create (for example, an existing email) must not turn a
        // normal account into an unfinished-registration session.
        await prefs.setBool(_manualLoginKey, previousRegistrationGuard);
        rethrow;
      }
      throw AuthFlowException(
        profileSaved
            ? 'Your account and profile were created, but sign-out could not be completed. Please return to Login and sign in manually.'
            : 'Your account was created, but profile setup did not finish. Please return to Login and sign in to retry setup.',
      );
    } finally {
      await session?.close();
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    _requireCapability(AndroidPilotCapability.existingAccountAuthentication);
    if (_pilotPolicy?.isRestricted == true) {
      return _signInPilot(email: email, password: password);
    }
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
      // Idempotently recover missing legacy/interrupted profiles. Existing
      // profiles are read only and never overwritten.
      await _profiles.createUserProfileIfNeeded(user);
      if (pendingRegistration) {
        if (!await prefs.setBool(_manualLoginKey, false)) {
          throw const AuthFlowException(
            'Unable to finish login. Please try again.',
          );
        }
      }
      // Login establishes the session. WorkspaceGate checks verification before
      // resolving any café membership.
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

  Future<void> _signInPilot({
    required String email,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final pendingRegistration = prefs.getBool(_manualLoginKey) ?? false;
    final result = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    final user = result.user;
    if (user == null) {
      throw const AuthFlowException('Login could not be confirmed.');
    }
    await _requirePilotProfileEligibility(
      expectedUid: user.uid,
      signOutOnFailure: true,
      onEligible: () async {
        // Retain the existing manual-login guard, after secure eligibility only.
        if (pendingRegistration &&
            !await prefs.setBool(_manualLoginKey, false)) {
          throw const AuthFlowException('Unable to finish login.');
        }
      },
    );
  }

  /// Reusable startup/restored-session gate. Normal mode is unchanged (no-op).
  /// With no cafeId, only the configured account is checked. The canonical
  /// resolver must verify membership and its resolved cafeId must match the
  /// policy before workspace entry. This method grants no workspace authority.
  /// WorkspaceGate/startup integration is deliberately NOT included here.
  Future<void> requirePilotProfileEligibility({String? cafeId}) =>
      _requirePilotProfileEligibility(cafeId: cafeId);

  Future<void> _requirePilotProfileEligibility({
    String? expectedUid,
    String? cafeId,
    bool signOutOnFailure = false,
    Future<void> Function()? onEligible,
  }) async {
    _requireCapability(AndroidPilotCapability.existingAccountAuthentication);
    final policy = _pilotPolicy;
    if (policy?.isRestricted != true) return;
    final auth = _auth;
    final user = auth.currentUser;
    if (user == null || (expectedUid != null && user.uid != expectedUid)) {
      throw const AuthFlowException('Pilot session could not be verified.');
    }
    final uid = user.uid;
    final email = user.email;
    var changed = false;
    final initial = Completer<void>();
    // authStateChanges starts with the current state. Any subsequent event
    // fences this operation, including sign-out/relogin with the SAME UID.
    final subscription = auth.authStateChanges().listen(
      (current) {
        if (initial.isCompleted || current?.uid != uid) changed = true;
        if (!initial.isCompleted) initial.complete();
      },
      onError: (Object error, StackTrace stack) {
        changed = true;
        if (!initial.isCompleted) initial.complete();
      },
      onDone: () {
        changed = true;
        if (!initial.isCompleted) initial.complete();
      },
    );
    bool sameSession() =>
        !changed &&
        auth.currentUser?.uid == uid &&
        auth.currentUser?.email == email;
    void requireCurrent() {
      if (!sameSession() || auth.currentUser?.emailVerified != true) {
        throw const AuthFlowException('Pilot session could not be verified.');
      }
    }

    try {
      await initial.future.timeout(const Duration(seconds: 15));
      requireCurrent();
      if (!policy!.bindings.any(
        (binding) =>
            policy.matchesBinding(uid: uid, cafeId: cafeId ?? binding.cafeId),
      )) {
        throw const AuthFlowException(
          'Pilot account/workspace is not approved.',
        );
      }
      await _profiles
          .readExistingServerProfile(user)
          .timeout(const Duration(seconds: 15));
      requireCurrent();
      await onEligible?.call();
      requireCurrent();
    } catch (_) {
      // Never sign out a replacement session in response to an obsolete read.
      if (signOutOnFailure && sameSession()) {
        try {
          await auth.signOut().timeout(const Duration(seconds: 15));
        } catch (_) {
          /* Failure remains closed even if sign-out is unavailable. */
        }
      }
      throw const AuthFlowException(
        'Pilot profile eligibility could not be verified.',
      );
    } finally {
      await subscription.cancel();
    }
    requireCurrent();
  }

  /// Logout remains available for restricted and invalid configurations.
  Future<void> signOut() => _auth.signOut();

  Future<bool> canRestoreSession() async {
    _requireCapability(AndroidPilotCapability.existingAccountAuthentication);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_manualLoginKey) ?? false) {
      try {
        await _auth.signOut();
      } catch (_) {
        /* Never route this session home. */
      }
      return false;
    }
    if (_pilotPolicy?.isRestricted == true) {
      try {
        await requirePilotProfileEligibility();
        return true;
      } on AuthFlowException {
        return false;
      }
    }
    return _auth.currentUser != null;
  }
}
