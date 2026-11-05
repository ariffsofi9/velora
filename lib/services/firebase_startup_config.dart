import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import '../firebase_options.dart';

class FirebaseConfigurationException extends StateError {
  FirebaseConfigurationException(super.message);
  @override
  String toString() => 'Local Firebase configuration error: $message';
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
  final String cloudProject;
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
    this.cloudProject = '',
    this.stagingFlagPresent = false,
  });
  static const current = FirebaseStartupConfig(
    cloudProject: String.fromEnvironment('VELORA_FIREBASE_PROJECT'),
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
    required bool isWeb,
    required TargetPlatform platform,
    FirebaseOptions? webOptions = DefaultFirebaseOptions.web,
    FirebaseOptions? androidOptions,
    String? androidFlavor = appFlavor,
    FirebaseOptions cloudOptions = DefaultFirebaseOptions.android,
  }) {
    if (cloudProject.isNotEmpty) {
      if (cloudProject != 'velora-73222' ||
          (!isWeb && platform != TargetPlatform.android) ||
          (!isWeb && androidFlavor != null) ||
          stagingFlagPresent ||
          staging ||
          emulatorFlagPresent ||
          emulators ||
          staffDemo ||
          ai1Mock ||
          recipeConnectivity ||
          ai1Live ||
          host != 'localhost') {
        _fail(
          'Explicit cloud profile requires Web or unflavored Android, velora-73222, and no staging/emulator/demo/AI defines.',
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
        'Staging is retired. Select VELORA_FIREBASE_PROJECT=velora-73222 explicitly.',
      );
    }
    if (!isWeb && platform == TargetPlatform.android && androidFlavor != null) {
      _fail('Only unflavored Android is supported.');
    }
    if (ai1Live) _fail('Live AI is not approved or configured.');
    if (!emulators) {
      _fail(
        'Select VELORA_FIREBASE_PROJECT=velora-73222 explicitly or an explicit emulator profile. No default cloud project is allowed.',
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
    final project = ai1Mock
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
      projectId: project,
      authDomain: '$project.firebaseapp.com',
    );
  }
}
