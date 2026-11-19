import 'package:velora/services/android_pilot_policy.dart';
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
  group('validation-only Android pilot workflow', () {
    const mode = '--dart-define=VELORA_ANDROID_READ_ONLY_PILOT=true';
    const project = '--dart-define=VELORA_FIREBASE_PROJECT=velora-73222';
    String binding(String raw) =>
        '--dart-define=VELORA_ANDROID_PILOT_BINDINGS=$raw';
    final valid = [
      mode,
      project,
      binding('[["synthetic-user","synthetic-cafe"]]'),
    ];
    Future<ProcessResult> validate(List<String> arguments) {
      final encoded = base64Encode(utf8.encode(jsonEncode(arguments)));
      // Only synthetic fixtures cross this subprocess boundary. The validator
      // itself launches no processes and never starts Flutter or Gradle.
      return Process.run('powershell.exe', [
        '-ExecutionPolicy',
        'Bypass',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '\$a = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString('
            '[Convert]::FromBase64String(\'$encoded\'))); '
            '& ./tool/validate_android_pilot_arguments.ps1 -PilotArguments \$a',
      ]).timeout(const Duration(seconds: 15));
    }

    final cases = <String, List<String>>{
      'valid': valid,
      'missing flag': valid.skip(1).toList(),
      'misspelled flag': [
        mode.replaceFirst('PILOT', 'PILTO'),
        ...valid.skip(1),
      ],
      'missing project': [mode, valid.last],
      'wrong project': [mode, '$project-wrong', valid.last],
      'missing bindings': [mode, project],
      'duplicate identical': [...valid, mode],
      'duplicate conflicting': [
        mode,
        mode.replaceFirst('true', 'false'),
        valid.last,
      ],
      'unknown pilot key': [
        mode,
        project,
        '--dart-define=VELORA_ANDROID_PILOT_EXTRA=x',
      ],
      'unexpected argument': [...valid, '--release'],
      'normal separation': [],
      'explicit false': [mode.replaceFirst('true', 'false'), ...valid.skip(1)],
      'split define syntax': ['--dart-define', ...valid],
      'lowercase key': [mode.toLowerCase(), ...valid.skip(1)],
      for (final key in AndroidPilotPolicy.conflictingKeys)
        'conflicting $key': [...valid, '--dart-define=$key=false'],
    };
    final bindings = <String, String>{
      'valid escaped': r'[["synthetic\u002duser","synthetic-cafe"]]',
      'valid multiple': '[["u","c"],["U","d"]]',
      'confirmed wrapper escape':
          '[["synthetic-user","synthetic-cafe"]],"extra":[]',
      'appended property': '[["u","c"]],"other":true',
      'duplicate wrapper property': '[],"bindings":[["u","c"]]',
      'closed wrapper': '[["u","c"]]}',
      'trailing text': '[["u","c"]] trailing',
      'trailing JSON number': '[["u","c"]] 1',
      'concatenated arrays': '[["u","c"]][["v","d"]]',
      'concatenated null': '[["u","c"]] null',
      'concatenated object': '[["u","c"]] {}',
      'root string': '"u"',
      'root null': 'null',
      'empty entry': '[[]]',
      'extra entry field': '[["u","c","extra"]]',
      'single quoted strings': "[['u','c']]",
      'raw control in string': '[["u\nc","c"]]',
      'valid pretty JSON': '[\n ["u", "c"]\n ]\n',
      'empty': '[]',
      'malformed': '[',
      'object': '{}',
      'flat': '["u","c"]',
      'numeric': '[[1,"c"]]',
      'missing id': '[["","c"]]',
      'invalid id': '[["u/x","c"]]',
      'duplicate uid': '[["u","c"],["u","d"]]',
      'trailing comma': '[["u","c"],]',
      'comment': '[["u","c"] /*comment*/]',
      'too many': jsonEncode(List.generate(21, (i) => ['u$i', 'c'])),
      'maximum': jsonEncode(List.generate(20, (i) => ['u$i', 'c'])),
      'long id': jsonEncode([
        ['u' * 129, 'c'],
      ]),
    };
    final invalidIdentifiers = <String, String>{
      'terminal LF': 'a\n',
      'terminal CR': 'a\r',
      'terminal CRLF': 'a\r\n',
      'embedded LF': 'a\nb',
      'leading LF': '\na',
      'embedded CR': 'a\rb',
      'terminal tab': 'a\t',
      'terminal NUL': 'a\u0000',
      'terminal line separator': 'a\u2028',
      'terminal paragraph separator': 'a\u2029',
      'leading space': ' a',
      'terminal space': 'a ',
    };
    for (final entry in invalidIdentifiers.entries) {
      for (final position in [0, 1]) {
        final pair = ['synthetic-owner', 'synthetic-cafe-a']
          ..[position] = entry.value;
        // jsonEncode exercises decoded characters, including the exact two
        // reported terminal-LF fixtures; every case must be canonically invalid.
        bindings['identifier ${entry.key} at $position'] = jsonEncode([pair]);
      }
    }
    bindings['valid identifier boundaries'] = jsonEncode([
      ['A_0-z', 'c' * 128],
      ['Z' * 128, '_'],
    ]);
    for (final entry in bindings.entries) {
      final policy = AndroidPilotPolicy.parse(
        {
          AndroidPilotPolicy.modeKey: 'true',
          AndroidPilotPolicy.projectKey: AndroidPilotPolicy.approvedProject,
          AndroidPilotPolicy.bindingsKey: entry.value,
        },
        isWeb: false,
        platform: TargetPlatform.android,
      );
      test('canonical bindings ${entry.key}', () {
        expect(
          policy.isRestricted,
          entry.key.startsWith('valid') || entry.key == 'maximum',
        );
      });
      cases['bindings ${entry.key}'] = [mode, project, binding(entry.value)];
    }
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final definitions = <String, String>{};
        var structurallyValid = entry.value.length == 3;
        for (final argument in entry.value) {
          final match = RegExp(
            r'^--dart-define=([A-Z_]+)=(.*)$',
            dotAll: true,
          ).firstMatch(argument);
          if (match == null ||
              !{
                AndroidPilotPolicy.modeKey,
                AndroidPilotPolicy.projectKey,
                AndroidPilotPolicy.bindingsKey,
              }.contains(match[1]) ||
              definitions.containsKey(match[1])) {
            structurallyValid = false;
          } else {
            definitions[match[1]!] = match[2]!;
          }
        }
        final canonical = AndroidPilotPolicy.parse(
          definitions,
          isWeb: false,
          platform: TargetPlatform.android,
        );
        final accepted = structurallyValid && canonical.isRestricted;
        final result = await validate(entry.value);
        expect(result.exitCode, accepted ? 0 : 1, reason: entry.key);
        expect(result.stderr, isEmpty);
        expect(
          result.stdout,
          accepted ? contains('PASS:') : contains('REJECTED:'),
        );
        expect(result.stdout, isNot(contains('synthetic-user')));
        expect(result.stdout, isNot(contains('synthetic-cafe')));
      }, skip: !Platform.isWindows);
    }
    test(
      'validator command surface contains no process or network dispatch',
      () {
        final source = File(
          'tool/validate_android_pilot_arguments.ps1',
        ).readAsStringSync();
        // Inspect actual PowerShell commands, not comments or string literals.
        const command =
            r"$tokens=$null; $errors=$null; $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pwd 'tool/validate_android_pilot_arguments.ps1'),[ref]$tokens,[ref]$errors); if($errors.Count){exit 1}; $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true) | ForEach-Object { $_.GetCommandName() }";
        return Process.run('powershell.exe', [
          '-ExecutionPolicy',
          'Bypass',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          command,
        ]).then((result) {
          expect(result.exitCode, 0);
          final commands = (result.stdout as String)
              .split(RegExp(r'\s+'))
              .where((x) => x.isNotEmpty)
              .toSet();
          expect(
            commands.difference({
              'Set-StrictMode',
              'ConvertFrom-Json',
              'Write-Output',
            }),
            isEmpty,
          );
          expect(source, contains('bypass this validator'));
        });
      },
      skip: !Platform.isWindows,
    );
  });

  const sparkOptions = FirebaseOptions(
    apiKey: 'offline-test-key',
    appId: '1:123456789:web:offline',
    messagingSenderId: '123456789',
    projectId: 'velora-spark-test',
    authDomain: 'velora-spark-test.firebaseapp.com',
  );
  test(
    'separate Spark Web profile requires verified local config and never falls back',
    () {
      const config = FirebaseStartupConfig(cloudProject: 'velora-spark-test');
      expect(
        config.resolve(isWeb: true, platform: TargetPlatform.windows).projectId,
        'velora-spark-test',
      );
      expect(
        () => config.resolve(
          isWeb: true,
          platform: TargetPlatform.windows,
          sparkTestWebOptions: null,
        ),
        throwsA(isA<FirebaseConfigurationException>()),
      );
      expect(
        config
            .resolve(
              isWeb: true,
              platform: TargetPlatform.windows,
              sparkTestWebOptions: sparkOptions,
            )
            .projectId,
        'velora-spark-test',
      );
      expect(
        () => config.resolve(
          isWeb: true,
          platform: TargetPlatform.windows,
          sparkTestWebOptions: DefaultFirebaseOptions.web,
        ),
        throwsA(isA<FirebaseConfigurationException>()),
      );
      expect(
        () => config.resolve(
          isWeb: false,
          platform: TargetPlatform.android,
          sparkTestWebOptions: sparkOptions,
        ),
        throwsA(isA<FirebaseConfigurationException>()),
      );
    },
  );
  for (final config in [
    const FirebaseStartupConfig(
      cloudProject: 'velora-spark-test',
      stagingFlagPresent: true,
    ),
    const FirebaseStartupConfig(
      cloudProject: 'velora-spark-test',
      emulatorFlagPresent: true,
    ),
    const FirebaseStartupConfig(
      cloudProject: 'velora-spark-test',
      staffDemo: true,
    ),
    const FirebaseStartupConfig(
      cloudProject: 'velora-spark-test',
      host: '127.0.0.1',
    ),
  ]) {
    test(
      'Spark test profile rejects conflicting selection ${config.hashCode}',
      () {
        expect(
          () => config.resolve(
            isWeb: true,
            platform: TargetPlatform.windows,
            sparkTestWebOptions: sparkOptions,
          ),
          throwsA(isA<FirebaseConfigurationException>()),
        );
      },
    );
  }

  const cloud = FirebaseStartupConfig(cloudProject: 'velora-73222');
  test(
    'explicit Web profile selects checked-in options without initialization',
    () {
      expect(
        cloud.resolve(isWeb: true, platform: TargetPlatform.windows),
        same(DefaultFirebaseOptions.web),
      );
    },
  );
  test('Web profile rejects missing and mismatched configuration fields', () {
    const approved = DefaultFirebaseOptions.web;
    for (final field in [
      'missing',
      'project',
      'app',
      'sender',
      'domain',
      'bucket',
      'key',
    ]) {
      final value = field == 'missing'
          ? null
          : FirebaseOptions(
              apiKey: field == 'key' ? '' : approved.apiKey,
              appId: field == 'app'
                  ? DefaultFirebaseOptions.windows.appId
                  : approved.appId,
              messagingSenderId: field == 'sender'
                  ? '123'
                  : approved.messagingSenderId,
              projectId: field == 'project' ? 'other' : approved.projectId,
              authDomain: field == 'domain'
                  ? 'other.firebaseapp.com'
                  : approved.authDomain,
              storageBucket: field == 'bucket'
                  ? 'other'
                  : approved.storageBucket,
            );
      expect(
        () => cloud.resolve(
          isWeb: true,
          platform: TargetPlatform.windows,
          webOptions: value,
        ),
        throwsStateError,
      );
    }
  });
  test(
    'Web rejects wrong project and conflicting flags without initialization',
    () {
      for (final config in [
        const FirebaseStartupConfig(cloudProject: 'other'),
        const FirebaseStartupConfig(cloudProject: ' velora-73222'),
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
          ai1Live: true,
        ),
        const FirebaseStartupConfig(stagingFlagPresent: true),
      ]) {
        expect(
          () => config.resolve(isWeb: true, platform: TargetPlatform.windows),
          throwsStateError,
        );
      }
    },
  );
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
            contains('Staging is retired'),
          ),
        ),
      );
    },
  );
  test('retired staging rejects even structurally matching Web options', () {
    final fixture = options();
    expect(() => resolve(staging, web: fixture), throwsStateError);
  });
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
            contains('Staging is retired'),
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
