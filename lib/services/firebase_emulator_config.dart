import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

class FirebaseEmulatorConfig {
  static const staffDemo = bool.fromEnvironment('STAFF_DEMO');
  static FirebaseOptions optionsFor(FirebaseOptions normal) {
    if (!staffDemo) return normal;
    if (!enabled || host != '127.0.0.1') {
      throw StateError('Explicit loopback staff emulators required.');
    }
    return const FirebaseOptions(
      apiKey: 'demo-only',
      appId: '1:1234567890:web:demo',
      messagingSenderId: '1234567890',
      projectId: 'demo-velora-staff',
      authDomain: 'demo-velora-staff.firebaseapp.com',
    );
  }

  static const enabled = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
  static const host = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
    defaultValue: 'localhost',
  );

  static Future<void> connectIfEnabled() async {
    if (staffDemo &&
        (!enabled ||
            host != '127.0.0.1' ||
            Firebase.app().options.projectId != 'demo-velora-staff')) {
      throw StateError('Wrong staff demo target.');
    }
    if (!enabled) return;
    await FirebaseAuth.instance.useAuthEmulator(host, staffDemo ? 29099 : 9099);
    FirebaseFirestore.instance.useFirestoreEmulator(
      host,
      staffDemo ? 28080 : 8080,
    );
    FirebaseFunctions.instanceFor(
      region: 'asia-southeast1',
    ).useFunctionsEmulator(host, staffDemo ? 25001 : 5001);
  }
}
