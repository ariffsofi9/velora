import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'firebase_startup_config.dart';

class FirebaseEmulatorConfig {
  static const staging = bool.fromEnvironment('VELORA_STAGING');
  static const ai1Live = bool.fromEnvironment('AI1_LIVE_RECIPES');
  static const ai1Mock = bool.fromEnvironment('AI1_MOCK_RECIPES');
  static const ai1Project = 'demo-velora-ai1';
  static const conflictingProfiles =
      (ai1Mock && staffDemo) ||
      (ai1Mock && recipeConnectivity) ||
      (staffDemo && recipeConnectivity) ||
      ai1Live ||
      (staging &&
          (emulatorRequested || staffDemo || ai1Mock || recipeConnectivity));
  static const staffDemo = bool.fromEnvironment('STAFF_DEMO');
  static const recipeConnectivity = bool.fromEnvironment(
    'RECIPE_CONNECTIVITY_DEMO',
  );
  static const recipeProject = 'demo-velora-ai-connectivity';

  /// Exactly the two approved local invitation profiles; never client authority.
  static bool invitationProfileAllows(String projectId) =>
      enabled &&
      !staging &&
      !ai1Live &&
      host == '127.0.0.1' &&
      !conflictingProfiles &&
      !recipeConnectivity &&
      ((staffDemo && projectId == 'demo-velora-staff') ||
          (ai1Mock && projectId == ai1Project));

  static bool get invitationsAvailable {
    try {
      return invitationProfileAllows(Firebase.app().options.projectId);
    } catch (_) {
      return false;
    }
  }

  static int get invitationFunctionsPort => ai1Mock ? 15001 : 25001;

  /// Compatibility entry point for emulator harnesses. The legacy argument is
  /// deliberately ignored: it must never become an implicit cloud fallback.
  static FirebaseOptions optionsFor(FirebaseOptions _) => FirebaseStartupConfig
      .current
      .resolve(isWeb: kIsWeb, platform: defaultTargetPlatform);

  static const emulatorRequested = bool.fromEnvironment(
    'USE_FIREBASE_EMULATORS',
  );
  static const enabled = emulatorRequested && !staging && !ai1Live;
  static const host = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
    defaultValue: 'localhost',
  );

  static Future<void> connectIfEnabled() async {
    if ((staffDemo || recipeConnectivity || ai1Mock) &&
        (!enabled ||
            host != '127.0.0.1' ||
            conflictingProfiles ||
            Firebase.app().options.projectId !=
                (ai1Mock
                    ? ai1Project
                    : recipeConnectivity
                    ? recipeProject
                    : 'demo-velora-staff'))) {
      throw StateError('Wrong staff demo target.');
    }
    if (!enabled) return;
    await FirebaseAuth.instance.useAuthEmulator(
      host,
      ai1Mock
          ? 19099
          : recipeConnectivity
          ? 49099
          : staffDemo
          ? 29099
          : 9099,
    );
    FirebaseFirestore.instance.useFirestoreEmulator(
      host,
      ai1Mock
          ? 19080
          : recipeConnectivity
          ? 48080
          : staffDemo
          ? 28080
          : 8080,
    );
    FirebaseFunctions.instanceFor(
      region: 'asia-southeast1',
    ).useFunctionsEmulator(
      host,
      ai1Mock
          ? 15001
          : recipeConnectivity
          ? 45001
          : staffDemo
          ? 25001
          : 5001,
    );
  }
}
