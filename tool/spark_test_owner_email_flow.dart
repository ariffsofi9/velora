import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:velora/firebase_spark_test_options.dart';
import 'package:velora/services/firebase_startup_config.dart';

import 'spark_test_owner_email_verification.dart';

/// Single-use flow. The Web entry supplies the browser preflight and owns the
/// isolated Firebase app. No clients are created until an explicit submit.
final class SparkTestOwnerEmailFlow {
  final FirebaseStartupConfig startup;
  final bool isWeb;
  final Future<bool> Function() cleanBrowser;
  final Future<FirebaseApp> Function(FirebaseOptions) initializeNamedApp;
  final FirebaseAuth Function(FirebaseApp) authForApp;
  final Future<SparkTestOwnerEmailResult> Function(FirebaseAuth, String)
  _verify;
  bool _used = false;

  SparkTestOwnerEmailFlow({
    required this.startup,
    required this.isWeb,
    required this.cleanBrowser,
    required this.initializeNamedApp,
    required this.authForApp,
    Future<SparkTestOwnerEmailResult> Function(FirebaseAuth, String)?
    verifyForTesting,
  }) : _verify = verifyForTesting ?? _checkEmail;

  static Future<SparkTestOwnerEmailResult> _checkEmail(
    FirebaseAuth auth,
    String uid,
  ) => SparkTestOwnerEmailVerification().check(
    existingAuth: auth,
    approvedOwnerUid: uid,
  );

  bool _matches(FirebaseApp app) =>
      app.name == SparkTestOwnerEmailVerification.appName &&
      app.options == SparkTestFirebaseOptions.web;

  static SparkTestOwnerEmailFailure _classifySignInError(String code) =>
      switch (code) {
        'wrong-password' ||
        'user-not-found' ||
        'user-disabled' ||
        'invalid-credential' ||
        'invalid-login-credentials' ||
        'invalid-email' ||
        'account-exists-with-different-credential' ||
        'multi-factor-auth-required' ||
        'login-blocked' => SparkTestOwnerEmailFailure.credentialsRejected,
        'operation-not-allowed' ||
        'invalid-api-key' ||
        'app-not-authorized' ||
        'unauthorized-domain' ||
        'auth-domain-config-required' ||
        'invalid-app-id' => SparkTestOwnerEmailFailure.authConfiguration,
        'network-request-failed' =>
          SparkTestOwnerEmailFailure.networkUnavailable,
        'too-many-requests' => SparkTestOwnerEmailFailure.rateLimited,
        _ => SparkTestOwnerEmailFailure.signInFailed,
      };

  Future<SparkTestOwnerEmailResult> submit({
    required String email,
    required String password,
    required String approvedOwnerUid,
  }) async {
    const configRejected = SparkTestOwnerEmailResult.unknown(
      SparkTestOwnerEmailFailure.configRejected,
    );
    if (_used) return configRejected;
    _used = true;
    if (!isWeb ||
        startup.cloudProject != SparkTestFirebaseOptions.projectId ||
        approvedOwnerUid.isEmpty ||
        approvedOwnerUid.trim() != approvedOwnerUid ||
        email.trim().isEmpty ||
        password.isEmpty) {
      return configRejected;
    }

    FirebaseApp? app;
    FirebaseAuth? auth;
    var signInAttempted = false;
    var stage = SparkTestOwnerEmailFailure.configRejected;

    Future<SparkTestOwnerEmailResult> attempt() async {
      final options = startup.resolve(
        isWeb: isWeb,
        platform: defaultTargetPlatform,
      );
      if (options != SparkTestFirebaseOptions.web) return configRejected;

      stage = SparkTestOwnerEmailFailure.browserPreflightFailed;
      if (!await cleanBrowser().timeout(const Duration(seconds: 5))) {
        return SparkTestOwnerEmailResult.unknown(stage);
      }

      stage = SparkTestOwnerEmailFailure.authSetupFailed;
      final initialized = await initializeNamedApp(options);
      if (!_matches(initialized)) return configRejected;
      app = initialized;
      final client = authForApp(initialized);
      auth = client;
      if (!identical(client.app, initialized) || client.currentUser != null) {
        return SparkTestOwnerEmailResult.unknown(stage);
      }
      await client.setPersistence(Persistence.NONE);
      if (client.currentUser != null) {
        return SparkTestOwnerEmailResult.unknown(stage);
      }

      stage = SparkTestOwnerEmailFailure.signInFailed;
      signInAttempted = true;
      final UserCredential credential;
      try {
        credential = await client.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
      } on FirebaseAuthException catch (error) {
        return SparkTestOwnerEmailResult.unknown(
          _classifySignInError(error.code),
        );
      }
      stage = SparkTestOwnerEmailFailure.ownerMismatch;
      if (credential.user?.uid != approvedOwnerUid ||
          client.currentUser?.uid != approvedOwnerUid) {
        return SparkTestOwnerEmailResult.unknown(stage);
      }

      stage = SparkTestOwnerEmailFailure.reloadFailed;
      return _verify(client, approvedOwnerUid);
    }

    SparkTestOwnerEmailResult result;
    const cleanupFailed = SparkTestOwnerEmailResult.unknown(
      SparkTestOwnerEmailFailure.cleanupFailed,
    );
    try {
      result = await attempt();
    } catch (_) {
      result = SparkTestOwnerEmailResult.unknown(stage);
    } finally {
      try {
        if (signInAttempted) await auth?.signOut();
      } catch (_) {
        result = cleanupFailed;
      }
      try {
        await app?.delete();
      } catch (_) {
        result = cleanupFailed;
      }
    }
    return result;
  }
}

class SparkTestOwnerEmailEntry extends StatefulWidget {
  const SparkTestOwnerEmailEntry({
    super.key,
    required this.flow,
    required this.readApprovedOwnerFile,
  });

  final SparkTestOwnerEmailFlow flow;
  final Future<String?> Function() readApprovedOwnerFile;

  @override
  State<SparkTestOwnerEmailEntry> createState() => _EntryState();
}

class _EntryState extends State<SparkTestOwnerEmailEntry> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _approvedOwnerUid;
  String? _approvalMessage;
  String? _status;
  bool _readingApproval = false;
  bool _submitted = false;

  Future<void> _chooseApproval() async {
    if (_submitted || _readingApproval) return;
    setState(() {
      _approvedOwnerUid = null;
      _approvalMessage = null;
      _readingApproval = true;
    });

    String? uid;
    try {
      final contents = await widget.readApprovedOwnerFile();
      final candidate = contents?.replaceFirst(RegExp(r'\r?\n$'), '');
      if (candidate != null &&
          candidate.isNotEmpty &&
          candidate.length <= 128 &&
          candidate.trim() == candidate &&
          !candidate.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        uid = candidate;
      }
    } catch (_) {
      // The file and browser errors can contain private information.
    }
    if (!mounted) return;
    setState(() {
      _approvedOwnerUid = uid;
      _approvalMessage = uid == null
          ? 'No valid Owner identity loaded.'
          : 'Owner identity loaded.';
      _readingApproval = false;
    });
  }

  Future<void> _submit() async {
    final approvedOwnerUid = _approvedOwnerUid;
    if (_submitted || _readingApproval || approvedOwnerUid == null) return;
    setState(() {
      _submitted = true;
      _approvedOwnerUid = null;
    });
    final pending = widget.flow.submit(
      email: _email.text,
      password: _password.text,
      approvedOwnerUid: approvedOwnerUid,
    );
    _email.clear();
    _password.clear();
    final status = await pending;
    if (mounted) setState(() => _status = status.displayText);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Spark Test Owner email check')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _submitted
              ? _status == null
                    ? const CircularProgressIndicator(
                        semanticsLabel: 'Checking',
                      )
                    : Text(_status!)
              : ListView(
                  shrinkWrap: true,
                  children: [
                    OutlinedButton(
                      onPressed: _readingApproval ? null : _chooseApproval,
                      child: const Text('Choose approved Owner file'),
                    ),
                    const Text(
                      'Use a private text file outside this repository '
                      'containing only the approved TEST Owner UID.',
                    ),
                    if (_approvalMessage case final message?) Text(message),
                    _input(_email, 'TEST Owner email'),
                    _input(_password, 'Password'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _approvedOwnerUid == null ? null : _submit,
                      child: const Text('Sign in and check once'),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );

  Widget _input(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    enableInteractiveSelection: false,
  );
}
