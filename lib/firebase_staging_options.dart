import 'package:firebase_core/firebase_core.dart';

/// S2.1 scaffold only. Apps are not registered; no configuration is fabricated.
/// Populate only from the separately registered velora-fyp-staging apps in S2.2.
class StagingFirebaseOptions {
  static const projectId = 'velora-fyp-staging';
  static const FirebaseOptions? web = null;
  static const FirebaseOptions? android = null;
}
