import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/android_pilot_policy.dart';

// Pure synthetic configuration; no Firebase initialization or service calls.
Map<String, String> pilotConfiguration() => {
  AndroidPilotPolicy.modeKey: 'true',
  AndroidPilotPolicy.projectKey: AndroidPilotPolicy.approvedProject,
  AndroidPilotPolicy.bindingsKey: jsonEncode([
    ['synthetic-owner', 'synthetic-cafe-a'],
    ['synthetic-staff', 'synthetic-cafe-b'],
  ]),
};

AndroidPilotPolicy parse(Map<String, String> configuration) =>
    AndroidPilotPolicy.parse(
      configuration,
      isWeb: false,
      platform: TargetPlatform.android,
    );

void expectInvalid(AndroidPilotPolicy policy) {
  expect(policy.state, AndroidPilotState.invalid);
  expect(policy.isValid, isFalse);
  expect(policy.isRestricted, isFalse);
  expect(policy.invalidReason, isNotEmpty);
  expect(policy.projectId, isNull);
  expect(policy.bindings, isEmpty);
  expect(policy.capabilities, isEmpty);
  expect(policy.requireValidConfiguration, throwsStateError);
  for (final capability in AndroidPilotCapability.values) {
    expect(policy.permits(capability), isFalse);
    expect(
      policy.permitsForBinding(
        capability,
        uid: 'synthetic-owner',
        cafeId: 'synthetic-cafe-a',
      ),
      isFalse,
    );
  }
}

void main() {
  test('absent pilot configuration is normal without pilot permissions', () {
    final policy = parse({});
    expect(policy.state, AndroidPilotState.normal);
    expect(policy.isValid, isTrue);
    expect(policy.isRestricted, isFalse);
    expect(policy.invalidReason, isNull);
    expect(policy.projectId, isNull);
    expect(policy.bindings, isEmpty);
    expect(policy.capabilities, isEmpty);
    expect(policy.requireValidConfiguration, returnsNormally);
    for (final capability in AndroidPilotCapability.values) {
      expect(policy.permits(capability), isFalse);
    }
    expect(
      policy.matchesBinding(uid: 'synthetic-owner', cafeId: 'synthetic-cafe-a'),
      isFalse,
    );
  });

  test('unrelated settings do not alter the existing normal flow', () {
    expect(
      parse({
        AndroidPilotPolicy.projectKey: 'synthetic-other-project',
        'VELORA_STAGING': 'true',
        'USE_FIREBASE_EMULATORS': 'true',
        'STAFF_DEMO': 'true',
      }).state,
      AndroidPilotState.normal,
    );
  });

  test('absent build definitions produce normal mode', () {
    final policy = AndroidPilotPolicy.fromBuildConfiguration(
      isWeb: false,
      platform: TargetPlatform.android,
    );
    expect(policy.state, AndroidPilotState.normal);
    expect(policy.capabilities, isEmpty);
  });

  test('explicit native Android configuration produces restricted mode', () {
    final policy = parse(pilotConfiguration());
    expect(policy.state, AndroidPilotState.restricted);
    expect(policy.isRestricted, isTrue);
    expect(policy.isValid, isTrue);
    expect(policy.invalidReason, isNull);
    expect(policy.projectId, AndroidPilotPolicy.approvedProject);
    expect(policy.bindings, hasLength(2));
    expect(policy.requireValidConfiguration, returnsNormally);
  });

  for (final mode in ['', 'false', 'TRUE', 'True', '1', ' true', 'true ']) {
    test('malformed or contradictory explicit mode ${jsonEncode(mode)}', () {
      expectInvalid(
        parse(pilotConfiguration()..[AndroidPilotPolicy.modeKey] = mode),
      );
    });
  }

  for (final key in [
    AndroidPilotPolicy.modeKey,
    AndroidPilotPolicy.bindingsKey,
    AndroidPilotPolicy.projectKey,
  ]) {
    test('missing required configuration $key is invalid', () {
      expectInvalid(parse(pilotConfiguration()..remove(key)));
    });
  }

  for (final key in [
    'VELORA_ANDROID_PILOT_BINDING',
    'VELORA_ANDROID_PILOT',
    'VELORA_ANDROID_READ_ONLY_PILOT_TYPO',
  ]) {
    test('unknown pilot key $key cannot silently become normal', () {
      expectInvalid(parse({key: 'true'}));
      expectInvalid(parse(pilotConfiguration()..[key] = 'true'));
    });
  }

  for (final project in [
    '',
    'velora-spark-test',
    'synthetic-other-project',
    'velora-73222 ',
  ]) {
    test('unsupported or malformed project ${jsonEncode(project)}', () {
      expectInvalid(
        parse(pilotConfiguration()..[AndroidPilotPolicy.projectKey] = project),
      );
    });
  }

  for (final platform in TargetPlatform.values.where(
    (p) => p != TargetPlatform.android,
  )) {
    test('pilot rejects native $platform', () {
      expectInvalid(
        AndroidPilotPolicy.parse(
          pilotConfiguration(),
          isWeb: false,
          platform: platform,
        ),
      );
    });
  }
  test('Android user agent on Web cannot enable the pilot', () {
    expectInvalid(
      AndroidPilotPolicy.parse(
        pilotConfiguration(),
        isWeb: true,
        platform: TargetPlatform.android,
      ),
    );
  });
  for (final flavor in ['', 'staging', 'synthetic-production']) {
    test('any explicit Android flavor ${jsonEncode(flavor)} is rejected', () {
      expectInvalid(
        AndroidPilotPolicy.parse(
          pilotConfiguration(),
          isWeb: false,
          platform: TargetPlatform.android,
          androidFlavor: flavor,
        ),
      );
    });
  }

  // Independent list: adding a conflicting profile must not silently omit a test.
  for (final key in [
    'VELORA_STAGING',
    'USE_FIREBASE_EMULATORS',
    'FIREBASE_EMULATOR_HOST',
    'STAFF_DEMO',
    'AI1_MOCK_RECIPES',
    'RECIPE_CONNECTIVITY_DEMO',
    'AI1_LIVE_RECIPES',
  ]) {
    for (final value in ['true', 'false', '', 'malformed']) {
      test('conflict $key=${jsonEncode(value)} fails closed by presence', () {
        expectInvalid(parse(pilotConfiguration()..[key] = value));
      });
    }
  }

  for (final raw in [
    '',
    'not-json',
    'null',
    '{}',
    '[]',
    'true',
    '[null]',
    '["synthetic-owner"]',
    '[["synthetic-owner"]]',
    '[["synthetic-owner","synthetic-cafe-a","extra"]]',
    '[[1,"synthetic-cafe-a"]]',
    '[["synthetic-owner",false]]',
    '[["synthetic-owner",null]]',
    '[["synthetic-owner","synthetic-cafe-a"],null]',
    '[["synthetic-owner","synthetic-cafe-a"],',
    jsonEncode(List.generate(21, (i) => ['synthetic-$i', 'synthetic-cafe'])),
    ' ' * 8193,
  ]) {
    test('malformed bindings fixture ${raw.length}:${raw.hashCode}', () {
      expectInvalid(
        parse(pilotConfiguration()..[AndroidPilotPolicy.bindingsKey] = raw),
      );
    });
  }

  for (final id in [
    '',
    ' ',
    'synthetic cafe',
    'a/b',
    '.',
    '..',
    'a%b',
    'a\nb',
    'a\n',
    'é',
    'a' * 129,
  ]) {
    for (final position in [0, 1]) {
      test('invalid binding identifier ${jsonEncode(id)} at $position', () {
        final pair = ['synthetic-owner', 'synthetic-cafe-a']..[position] = id;
        expectInvalid(
          parse(
            pilotConfiguration()
              ..[AndroidPilotPolicy.bindingsKey] = jsonEncode([pair]),
          ),
        );
      });
    }
  }
  for (final cafe in ['synthetic-cafe-a', 'synthetic-cafe-b']) {
    test('duplicate account cannot broaden workspace scope: $cafe', () {
      expectInvalid(
        parse(
          pilotConfiguration()
            ..[AndroidPilotPolicy.bindingsKey] = jsonEncode([
              ['synthetic-owner', 'synthetic-cafe-a'],
              ['synthetic-owner', cafe],
            ]),
        ),
      );
    });
  }
  test('bounded pair count and identifier boundary lengths are accepted', () {
    final policy = parse(
      pilotConfiguration()
        ..[AndroidPilotPolicy.bindingsKey] = jsonEncode([
          ['a', 'b' * 128],
          ...List.generate(19, (i) => ['synthetic-$i', 'synthetic-cafe']),
        ]),
    );
    expect(policy.state, AndroidPilotState.restricted);
    expect(policy.bindings, hasLength(20));
  });

  test('Owner and Staff bindings match exact pairs with no cross-product', () {
    final policy = parse(pilotConfiguration());
    for (final pair in [
      ['synthetic-owner', 'synthetic-cafe-a'],
      ['synthetic-staff', 'synthetic-cafe-b'],
    ]) {
      expect(policy.matchesBinding(uid: pair[0], cafeId: pair[1]), isTrue);
      expect(
        policy.permitsForBinding(
          AndroidPilotCapability.inventoryList,
          uid: pair[0],
          cafeId: pair[1],
        ),
        isTrue,
      );
      expect(
        policy.permitsForBinding(
          AndroidPilotCapability.inventoryMutations,
          uid: pair[0],
          cafeId: pair[1],
        ),
        isFalse,
      );
    }
    for (final pair in [
      ['synthetic-owner', 'synthetic-cafe-b'],
      ['synthetic-staff', 'synthetic-cafe-a'],
      ['SYNTHETIC-OWNER', 'synthetic-cafe-a'],
      ['synthetic-owner', 'synthetic-cafe-A'],
      ['synthetic-other', 'synthetic-cafe-a'],
      ['synthetic-owner', ''],
    ]) {
      expect(policy.matchesBinding(uid: pair[0], cafeId: pair[1]), isFalse);
      expect(
        policy.permitsForBinding(
          AndroidPilotCapability.inventoryList,
          uid: pair[0],
          cafeId: pair[1],
        ),
        isFalse,
      );
    }
  });

  const approved = <AndroidPilotCapability>{
    AndroidPilotCapability.existingAccountAuthentication,
    AndroidPilotCapability.workspaceResolution,
    AndroidPilotCapability.inventoryList,
    AndroidPilotCapability.inventoryDetails,
    AndroidPilotCapability.movementHistory,
    AndroidPilotCapability.dashboard,
    AndroidPilotCapability.activity,
    AndroidPilotCapability.lowStockViews,
    AndroidPilotCapability.expiryViews,
    AndroidPilotCapability.localInventoryInsights,
    AndroidPilotCapability.logout,
  };
  test('capability set contains exactly the reviewed read workflows', () {
    expect(parse(pilotConfiguration()).capabilities, unorderedEquals(approved));
  });
  for (final capability in AndroidPilotCapability.values) {
    test('explicit default-deny capability decision for $capability', () {
      final policy = parse(pilotConfiguration());
      expect(policy.permits(capability), approved.contains(capability));
      expect(
        policy.permitsForBinding(
          capability,
          uid: 'synthetic-owner',
          cafeId: 'synthetic-cafe-b',
        ),
        isFalse,
      );
    });
  }

  test('configuration snapshots and exposed collections are immutable', () {
    final configuration = pilotConfiguration();
    final first = parse(configuration);
    configuration.clear();
    final second = parse(configuration);
    expect(first.state, AndroidPilotState.restricted);
    expect(second.state, AndroidPilotState.normal);
    expect(first.bindings.first.uid, 'synthetic-owner');
    expect(first.bindings.first.cafeId, 'synthetic-cafe-a');
    expect(() => first.bindings.clear(), throwsUnsupportedError);
    expect(() => first.bindings[0] = first.bindings[1], throwsUnsupportedError);
    expect(
      () => first.capabilities.add(AndroidPilotCapability.inventoryMutations),
      throwsUnsupportedError,
    );
    expect(() => first.capabilities.clear(), throwsUnsupportedError);
    expect(
      () => second.capabilities.add(AndroidPilotCapability.registration),
      throwsUnsupportedError,
    );
    expect(first.capabilities, unorderedEquals(approved));
  });
}
