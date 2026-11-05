import 'dart:io';
import 'dart:convert';
import 'package:velora/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/firebase_staging_options.dart';
import 'package:velora/services/firebase_startup_config.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:velora/main.dart' as app;

// Synthetic parser fixtures only; never registered app values or used for I/O.
FirebaseOptions options({
  String project = 'velora-fyp-staging',
  String apiKey = 'offline-test-client-key',
  String appId = '1:123:web:fixture',
  String sender = '123',
  String? domain = 'velora-fyp-staging.firebaseapp.com',
  String? bucket,
}) => FirebaseOptions(
  apiKey: apiKey,
  appId: appId,
  messagingSenderId: sender,
  projectId: project,
  authDomain: domain,
  storageBucket: bucket,
);
FirebaseOptions resolve(
  FirebaseStartupConfig config, {
  FirebaseOptions? web,
  bool isWeb = true,
  TargetPlatform platform = TargetPlatform.android,
}) => config.resolve(isWeb: isWeb, platform: platform, webOptions: web);
void main() {
  const cloud = FirebaseStartupConfig(cloudProject: 'velora-73222');
  FirebaseOptions androidCloud(
    FirebaseStartupConfig config, {
    FirebaseOptions value = DefaultFirebaseOptions.android,
    String? flavor,
  }) => config.resolve(
    isWeb: false,
    platform: TargetPlatform.android,
    androidFlavor: flavor,
    cloudOptions: value,
  );
  test(
    'explicit Android cloud selection is pure and matches native configuration',
    () {
      expect(androidCloud(cloud), same(DefaultFirebaseOptions.android));
      final native =
          jsonDecode(
                File('android/app/google-services.json').readAsStringSync(),
              )
              as Map;
      final client = (native['client'] as List).single as Map;
      final info = client['client_info'] as Map;
      expect(
        native['project_info']['project_id'],
        androidCloud(cloud).projectId,
      );
      expect(
        native['project_info']['project_number'],
        androidCloud(cloud).messagingSenderId,
      );
      expect(info['mobilesdk_app_id'], androidCloud(cloud).appId);
      expect(info['android_client_info']['package_name'], 'com.example.velora');
      expect(
        (client['api_key'] as List).single['current_key'] ==
            androidCloud(cloud).apiKey,
        true,
      );
      expect(
        native['project_info']['storage_bucket'],
        androidCloud(cloud).storageBucket,
      );
    },
  );
  test('cloud rejects mismatched project app sender bucket and key', () {
    final approved = DefaultFirebaseOptions.android;
    for (final field in ['project', 'app', 'sender', 'bucket', 'key']) {
      final bad = FirebaseOptions(
        apiKey: field == 'key' ? 'invalid' : approved.apiKey,
        appId: field == 'app' ? '1:384873169563:android:other' : approved.appId,
        messagingSenderId: field == 'sender'
            ? '123'
            : approved.messagingSenderId,
        projectId: field == 'project' ? 'other' : approved.projectId,
        storageBucket: field == 'bucket' ? 'other' : approved.storageBucket,
      );
      expect(() => androidCloud(cloud, value: bad), throwsStateError);
    }
  });
  test(
    'cloud rejects every conflicting profile including false define presence',
    () {
      for (final config in [
        const FirebaseStartupConfig(cloudProject: 'wrong'),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          staging: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          stagingFlagPresent: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          emulatorFlagPresent: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          emulators: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          staffDemo: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          ai1Mock: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          recipeConnectivity: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          ai1Live: true,
        ),
        const FirebaseStartupConfig(
          cloudProject: 'velora-73222',
          host: '127.0.0.1',
        ),
      ]) {
        expect(() => androidCloud(config), throwsStateError);
      }
      for (final flavor in ['staging', 'other']) {
        expect(() => androidCloud(cloud, flavor: flavor), throwsStateError);
      }
      expect(() => resolve(cloud), throwsStateError);
      for (final platform in TargetPlatform.values.where(
        (p) => p != TargetPlatform.android,
      )) {
        expect(
          () => cloud.resolve(isWeb: false, platform: platform),
          throwsStateError,
        );
      }
    },
  );
  test(
    'release source manifest grants Internet without native Firebase auto-init',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('<uses-permission android:name="android.permission.INTERNET"'),
      );
      expect(
        RegExp(
          r'<provider[^>]*FirebaseInitProvider[^>]*tools:node="remove"',
          dotAll: true,
        ).hasMatch(manifest),
        true,
      );
    },
  );
  const staging = FirebaseStartupConfig(staging: true);
  test(
    'default launch is rejected instead of selecting protected Firebase options',
    () {
      expect(() => resolve(const FirebaseStartupConfig()), throwsStateError);
      expect(StagingFirebaseOptions.web, isNull);
      expect(StagingFirebaseOptions.android, isNull);
    },
  );
  test(
    'staging requires real registered configuration; current scaffold is empty',
    () {
      expect(
        () => staging.resolve(isWeb: true, platform: TargetPlatform.windows),
        throwsA(
          isA<FirebaseConfigurationException>().having(
            (e) => e.message,
            'message',
            contains('missing'),
          ),
        ),
      );
    },
  );
  test(
    'explicit staging accepts only structurally matching Web options without I/O',
    () {
      final fixture = options();
      expect(resolve(staging, web: fixture), same(fixture));
    },
  );
  for (final project in ['velora-73222', 'demo-velora-ai1', 'other-staging']) {
    test(
      'staging rejects project $project',
      () => expect(
        () => resolve(staging, web: options(project: project)),
        throwsStateError,
      ),
    );
  }
  final incomplete = <String, FirebaseOptions>{
    'missing API key': options(apiKey: ''),
    'placeholder key': options(apiKey: 'placeholder'),
    'missing app ID': options(appId: ''),
    'Android app in Web': options(appId: '1:123:android:fixture'),
    'sender mismatch': options(sender: '456'),
    'non-numeric sender': options(sender: 'invalid'),
    'wrong auth domain': options(domain: 'velora-73222.firebaseapp.com'),
    'missing auth domain': options(domain: null),
    'protected bucket': options(bucket: 'velora-73222.firebasestorage.app'),
  };
  for (final entry in incomplete.entries) {
    test(
      'reject ${entry.key}',
      () => expect(() => resolve(staging, web: entry.value), throwsStateError),
    );
  }
  for (final config in [
    const FirebaseStartupConfig(staging: true, emulators: true),
    const FirebaseStartupConfig(staging: true, staffDemo: true),
    const FirebaseStartupConfig(staging: true, ai1Mock: true),
    const FirebaseStartupConfig(staging: true, recipeConnectivity: true),
    const FirebaseStartupConfig(staging: true, ai1Live: true),
    const FirebaseStartupConfig(staging: true, emulatorFlagPresent: true),
  ]) {
    test(
      'staging conflicts rejected ${config.hashCode}',
      () => expect(() => resolve(config, web: options()), throwsStateError),
    );
  }
  test(
    'Android staging remains blocked even with complete synthetic options',
    () {
      expect(
        () => staging.resolve(
          isWeb: false,
          platform: TargetPlatform.android,
          androidFlavor: 'staging',
          androidOptions: options(),
        ),
        throwsA(
          isA<FirebaseConfigurationException>().having(
            (e) => e.message,
            'message',
            contains('Android staging is BLOCKED'),
          ),
        ),
      );
    },
  );
  test('Android rejects staging profile on default or wrong variant', () {
    for (final flavor in <String?>[null, 'development', 'production']) {
      expect(
        () => staging.resolve(
          isWeb: false,
          platform: TargetPlatform.android,
          androidFlavor: flavor,
          androidOptions: options(),
        ),
        throwsStateError,
      );
    }
  });
  test('Android staging variant rejects default and emulator profiles', () {
    for (final config in [
      const FirebaseStartupConfig(),
      const FirebaseStartupConfig(emulators: true),
      const FirebaseStartupConfig(
        emulators: true,
        ai1Mock: true,
        host: '127.0.0.1',
      ),
    ]) {
      expect(
        () => config.resolve(
          isWeb: false,
          platform: TargetPlatform.android,
          androidFlavor: 'staging',
        ),
        throwsStateError,
      );
    }
  });
  test(
    'Android staging rejects missing and protected native-equivalent options',
    () {
      for (final native in <FirebaseOptions?>[
        null,
        options(project: 'velora-73222'),
      ]) {
        expect(
          () => staging.resolve(
            isWeb: false,
            platform: TargetPlatform.android,
            androidFlavor: 'staging',
            androidOptions: native,
          ),
          throwsStateError,
        );
      }
      expect(
        () => staging.resolve(
          isWeb: false,
          platform: TargetPlatform.android,
          androidFlavor: 'staging',
          androidOptions: options(appId: '1:123:android:fixture'),
        ),
        throwsStateError,
      ); // Registration does not lift the native verification gate.
    },
  );
  test(
    'Android variant has exact package and cannot use legacy Google Services fallback',
    () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('applicationId = "com.example.velora.staging"'));
      expect(gradle, contains('create("staging")'));
      expect(gradle, contains('applicationId = "com.example.velora"'));
      expect(
        gradle.indexOf('if (!stagingJson.isFile)'),
        lessThan(gradle.indexOf('android {')),
      );
      expect(gradle, contains('src/staging/google-services.json'));
      expect(gradle, contains('legacy fallback forbidden'));
      expect(
        gradle,
        contains(
          'registration/configuration review and native verification require separate approval',
        ),
      );
      expect(
        File('android/app/src/staging/google-services.json').existsSync(),
        false,
      );
      final activity = File(
        'android/app/src/main/kotlin/com/example/velora/MainActivity.kt',
      ).readAsStringSync();
      expect(activity, contains('package com.example.velora'));
    },
  );
  test(
    'unsupported staging platform and unapproved live profile are blocked',
    () {
      expect(
        () => resolve(
          staging,
          isWeb: false,
          platform: TargetPlatform.iOS,
          web: options(),
        ),
        throwsStateError,
      );
      expect(
        () => resolve(
          const FirebaseStartupConfig(ai1Live: true, emulators: true),
        ),
        throwsStateError,
      );
    },
  );
  final profiles = <String, FirebaseStartupConfig>{
    'demo-velora-workspaces': const FirebaseStartupConfig(emulators: true),
    'demo-velora-staff': const FirebaseStartupConfig(
      emulators: true,
      staffDemo: true,
      host: '127.0.0.1',
    ),
    'demo-velora-ai1': const FirebaseStartupConfig(
      emulators: true,
      ai1Mock: true,
      host: '127.0.0.1',
    ),
    'demo-velora-ai-connectivity': const FirebaseStartupConfig(
      emulators: true,
      recipeConnectivity: true,
      host: '127.0.0.1',
    ),
  };
  for (final entry in profiles.entries) {
    test('explicit emulator stays isolated: ${entry.key}', () {
      final result = resolve(entry.value);
      expect(result.projectId, entry.key);
      expect(result.projectId, isNot('velora-73222'));
    });
  }
  test('mixed profiles and non-loopback emulator targets fail closed', () {
    for (final config in [
      const FirebaseStartupConfig(
        emulators: true,
        staffDemo: true,
        ai1Mock: true,
        host: '127.0.0.1',
      ),
      const FirebaseStartupConfig(
        emulators: true,
        ai1Mock: true,
        host: 'localhost',
      ),
      const FirebaseStartupConfig(emulators: true, host: 'remote.example.test'),
      const FirebaseStartupConfig(staffDemo: true, host: '127.0.0.1'),
    ]) {
      expect(() => resolve(config), throwsStateError);
    }
  });
  test('legacy protected input cannot become a startup fallback', () {
    final protected = options(project: 'velora-73222');
    final current = FirebaseStartupConfig.current;
    if (current.cloudProject.isNotEmpty) {
      // Cloud profiles are tested through the pure resolver above, never main.
      return;
    }
    if (current.staging ||
        !current.emulators ||
        current.ai1Live ||
        FirebaseEmulatorConfig.conflictingProfiles ||
        ([
              current.staffDemo,
              current.ai1Mock,
              current.recipeConnectivity,
            ].any((v) => v) &&
            current.host != '127.0.0.1')) {
      expect(
        () => FirebaseEmulatorConfig.optionsFor(protected),
        throwsStateError,
      );
    } else {
      expect(
        FirebaseEmulatorConfig.optionsFor(protected).projectId,
        startsWith('demo-'),
      );
    }
  });
  test(
    'native auto-initialization is removed and Android staging has a build gate',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('xmlns:tools="http://schemas.android.com/tools"'),
      );
      expect(
        RegExp(
          r'<provider[^>]*FirebaseInitProvider[^>]*tools:node="remove"',
          dotAll: true,
        ).hasMatch(manifest),
        true,
      );
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('VELORA_STAGING=true'));
      expect(gradle, contains('Android staging BLOCKED'));
      expect(
        File('lib/main.dart').readAsStringSync(),
        isNot(contains('DefaultFirebaseOptions')),
      );
    },
  );
  testWidgets(
    'unconfigured main renders a local error without initializing Firebase/plugins',
    (tester) async {
      await app.main();
      await tester.pump();
      expect(
        find.textContaining('Local Firebase configuration error:'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    skip:
        FirebaseStartupConfig.current.cloudProject.isNotEmpty ||
        FirebaseStartupConfig.current.emulators ||
        FirebaseStartupConfig.current.staging ||
        FirebaseStartupConfig.current.ai1Live,
  );
}
