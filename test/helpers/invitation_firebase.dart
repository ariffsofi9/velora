// Offline platform double using an already-installed Firebase test interface.
// ignore_for_file: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:velora/services/firebase_emulator_config.dart';

class InvitationFirebase extends FirebasePlatform {
  String projectId;
  InvitationFirebase(this.projectId);
  @override
  FirebaseAppPlatform app([String name = '[DEFAULT]']) => FirebaseAppPlatform(
    name,
    FirebaseOptions(
      apiKey: 'placeholder',
      appId: 'placeholder',
      messagingSenderId: 'placeholder',
      projectId: projectId,
    ),
  );
}

InvitationFirebase installInvitationFirebase() {
  final core = InvitationFirebase(
    FirebaseEmulatorConfig.ai1Mock ? 'demo-velora-ai1' : 'demo-velora-staff',
  );
  FirebasePlatform.instance = core;
  Firebase.delegatePackingProperty = core;
  return core;
}
