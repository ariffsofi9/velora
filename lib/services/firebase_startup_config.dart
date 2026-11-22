import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter/widgets.dart';
import '../firebase_options.dart';
import '../firebase_spark_test_options.dart';
import 'android_pilot_policy.dart';

class FirebaseConfigurationException extends StateError {
  FirebaseConfigurationException(super.message);
  @override
  String toString() => 'Local Firebase configuration error: $message';
}

/// The options admitted at startup, shared by every route in this app.
class FirebaseStartupProfile extends InheritedWidget {
  final FirebaseOptions options;

  const FirebaseStartupProfile({
    super.key,
    required this.options,
    required super.child,
  });

  static FirebaseOptions? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FirebaseStartupProfile>()?.options;

  static void validateActiveApp(
    FirebaseOptions expected,
    FirebaseOptions actual,
  ) {
    final mismatches = [
      if (expected.projectId != actual.projectId) 'projectId',
      if (expected.appId != actual.appId) 'appId',
      if (expected.apiKey != actual.apiKey) 'apiKey',
      if (expected.messagingSenderId != actual.messagingSenderId)
        'messagingSenderId',
      if (expected.authDomain != actual.authDomain) 'authDomain',
      if (expected.storageBucket != actual.storageBucket) 'storageBucket',
    ];
    if (mismatches.isNotEmpty) {
      throw FirebaseConfigurationException(
        'The initialized Firebase app differs from the selected profile in '
        '${mismatches.join(', ')}. Fully stop and relaunch the app.',
      );
    }
  }

  @override
  bool updateShouldNotify(FirebaseStartupProfile oldWidget) =>
      options != oldWidget.options;
}

/// Pure selection/validation. Never initializes Firebase or reads native defaults.
class FirebaseStartupConfig {
  final bool staging,
      emulators,
      staffDemo,
      ai1Mock,
      recipeConnectivity,
      ai1Live;
  final bool emulatorFlagPresent;
  final String host;
  final String? cloudProject;
  final bool stagingFlagPresent;
  const FirebaseStartupConfig({
    this.staging = false,
    this.emulators = false,
    this.staffDemo = false,
    this.ai1Mock = false,
    this.recipeConnectivity = false,
    this.ai1Live = false,
    this.emulatorFlagPresent = false,
    this.host = 'localhost',
    this.cloudProject,
    this.stagingFlagPresent = false,
  });
  static const current = FirebaseStartupConfig(
    cloudProject: bool.hasEnvironment('VELORA_FIREBASE_PROJECT')
        ? String.fromEnvironment('VELORA_FIREBASE_PROJECT')
        : null,
    stagingFlagPresent: bool.hasEnvironment('VELORA_STAGING'),
    staging: bool.fromEnvironment('VELORA_STAGING'),
    emulators: bool.fromEnvironment('USE_FIREBASE_EMULATORS'),
    staffDemo: bool.fromEnvironment('STAFF_DEMO'),
    ai1Mock: bool.fromEnvironment('AI1_MOCK_RECIPES'),
    recipeConnectivity: bool.fromEnvironment('RECIPE_CONNECTIVITY_DEMO'),
    ai1Live: bool.fromEnvironment('AI1_LIVE_RECIPES'),
    host: String.fromEnvironment(
      'FIREBASE_EMULATOR_HOST',
      defaultValue: 'localhost',
    ),
    emulatorFlagPresent:
        bool.hasEnvironment('USE_FIREBASE_EMULATORS') ||
        bool.hasEnvironment('FIREBASE_EMULATOR_HOST') ||
        bool.hasEnvironment('STAFF_DEMO') ||
        bool.hasEnvironment('AI1_MOCK_RECIPES') ||
        bool.hasEnvironment('RECIPE_CONNECTIVITY_DEMO') ||
        bool.hasEnvironment('AI1_LIVE_RECIPES'),
  );
  Never _fail(String message) => throw FirebaseConfigurationException(message);
  FirebaseOptions resolve({
    AndroidPilotPolicy? pilotPolicy,
    required bool isWeb,
    required TargetPlatform platform,
    FirebaseOptions? webOptions = DefaultFirebaseOptions.web,
    FirebaseOptions? androidOptions,
    String? androidFlavor = appFlavor,
    FirebaseOptions cloudOptions = DefaultFirebaseOptions.android,
    FirebaseOptions? sparkTestWebOptions = SparkTestFirebaseOptions.web,
  }) {
    if (pilotPolicy != null) {
      if (!pilotPolicy.isValid ||
          (pilotPolicy.isRestricted &&
              (isWeb ||
                  platform != TargetPlatform.android ||
                  androidFlavor != null ||
                  cloudProject != pilotPolicy.projectId))) {
        _fail(
          'Android pilot configuration or project/platform binding is invalid.',
        );
      }
    }
    final conflictsWithCloud =
        stagingFlagPresent ||
        staging ||
        emulatorFlagPresent ||
        emulators ||
        staffDemo ||
        ai1Mock ||
        recipeConnectivity ||
        ai1Live ||
        host != 'localhost';
    // Only the app's validated normal startup can default to REAL. Legacy
    // callers without a startup policy still need an explicit profile.
    final project =
        cloudProject ??
        (pilotPolicy?.state == AndroidPilotState.normal && !conflictsWithCloud
            ? AndroidPilotPolicy.approvedProject
            : null);
    if (project == SparkTestFirebaseOptions.projectId) {
      // Separate Web-only acceptance target. Native Android remains blocked
      // until its project registration/Google Services identity is reviewed.
      final options = sparkTestWebOptions;
      if (!isWeb ||
          conflictsWithCloud ||
          options == null ||
          options.projectId != SparkTestFirebaseOptions.projectId ||
          !RegExp(r'^[0-9]+$').hasMatch(options.messagingSenderId) ||
          options.messagingSenderId ==
              DefaultFirebaseOptions.web.messagingSenderId ||
          !options.appId.startsWith('1:${options.messagingSenderId}:web:') ||
          options.appId.split(':').length != 4 ||
          options.appId.split(':').last.isEmpty ||
          options.apiKey.isEmpty ||
          options.apiKey == DefaultFirebaseOptions.web.apiKey ||
          options.apiKey == DefaultFirebaseOptions.android.apiKey ||
          options.authDomain !=
              '${SparkTestFirebaseOptions.projectId}.firebaseapp.com' ||
          (options.storageBucket != null &&
              options.storageBucket !=
                  '${SparkTestFirebaseOptions.projectId}.firebasestorage.app' &&
              options.storageBucket !=
                  '${SparkTestFirebaseOptions.projectId}.appspot.com')) {
        _fail(
          'Spark test profile blocked: verified separate Web app configuration required; no production fallback.',
        );
      }
      return options;
    }
    if (project != null) {
      if (project != AndroidPilotPolicy.approvedProject ||
          (!isWeb && platform != TargetPlatform.android) ||
          (!isWeb && androidFlavor != null) ||
          conflictsWithCloud) {
        _fail(
          'REAL Firebase requires Web or unflavored Android, velora-73222, and no staging/emulator/demo/AI defines.',
        );
      }
      if (isWeb) {
        final options = webOptions;
        const approved = DefaultFirebaseOptions.web;
        if (options == null ||
            options.projectId != 'velora-73222' ||
            options.appId != '1:384873169563:web:80da212022315171b63c3e' ||
            options.messagingSenderId != approved.messagingSenderId ||
            options.authDomain != approved.authDomain ||
            options.storageBucket != approved.storageBucket ||
            options.apiKey.isEmpty ||
            options.apiKey != approved.apiKey) {
          _fail(
            'Web Firebase configuration does not match the approved project/app.',
          );
        }
        return options;
      }
      if (cloudOptions.projectId != 'velora-73222' ||
          cloudOptions.appId !=
              '1:384873169563:android:d83c95f3e2134983b63c3e' ||
          cloudOptions.messagingSenderId != '384873169563' ||
          cloudOptions.storageBucket != 'velora-73222.firebasestorage.app' ||
          cloudOptions.apiKey != DefaultFirebaseOptions.android.apiKey ||
          cloudOptions.apiKey.isEmpty) {
        _fail(
          'Android Firebase configuration does not match the approved project/app.',
        );
      }
      // Native package and Google Services identity are checked by Gradle.
      return cloudOptions;
    }
    // Retired profile flags are rejected rather than rerouted to cloud.
    if (staging || stagingFlagPresent) {
      _fail(
        'Staging is retired. Remove the staging profile to use REAL Firebase.',
      );
    }
    if (!isWeb && platform == TargetPlatform.android && androidFlavor != null) {
      _fail('Only unflavored Android is supported.');
    }
    if (ai1Live) _fail('Live AI is not approved or configured.');
    if (!emulators) {
      _fail(
        'Firebase selection requires a supported startup profile without conflicting settings.',
      );
    }
    final count = [
      staffDemo,
      ai1Mock,
      recipeConnectivity,
    ].where((value) => value).length;
    if (count > 1) _fail('Emulator profiles are mutually exclusive.');
    if (count > 0 && host != '127.0.0.1') {
      _fail('Named emulator profiles require exact 127.0.0.1.');
    }
    if (host != 'localhost' && host != '127.0.0.1') {
      _fail('Emulator targets must remain loopback.');
    }
    final emulatorProject = ai1Mock
        ? 'demo-velora-ai1'
        : staffDemo
        ? 'demo-velora-staff'
        : recipeConnectivity
        ? 'demo-velora-ai-connectivity'
        : 'demo-velora-workspaces';
    return FirebaseOptions(
      apiKey: 'demo-only',
      appId: '1:1234567890:web:demo',
      messagingSenderId: '1234567890',
      projectId: emulatorProject,
      authDomain: '$emulatorProject.firebaseapp.com',
    );
  }
}
