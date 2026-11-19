import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform, immutable;

enum AndroidPilotState { normal, restricted, invalid }

/// Pilot permissions are restrictions on application behavior, never Firebase
/// authority. Normal mode uses the existing application flow, not this set.
enum AndroidPilotCapability {
  existingAccountAuthentication,
  workspaceResolution,
  inventoryList,
  inventoryDetails,
  movementHistory,
  dashboard,
  activity,
  lowStockViews,
  expiryViews,
  localInventoryInsights,
  logout,
  registration,
  businessSetup,
  profileWrites,
  inventoryMutations,
  menuCallables,
  teamCallables,
  passwordResetEmail,
  verificationEmail,
  liveAi,
  savedRecipesReads,
  savedRecipesWrites,
  reconciliation,
  cookNowDeduction,
  preferenceWrites,
}

@immutable
final class AndroidPilotBinding {
  final String uid;
  final String cafeId;
  const AndroidPilotBinding._(this.uid, this.cafeId);
}

/// Pure immutable foundation; no Auth, Firestore, native startup or network I/O.
///
/// Build contract:
/// * No recognized pilot keys: normal mode (unrelated settings are untouched).
/// * VELORA_ANDROID_READ_ONLY_PILOT must be exactly "true" when present.
/// * VELORA_FIREBASE_PROJECT must explicitly equal [approvedProject].
/// * VELORA_ANDROID_PILOT_BINDINGS is JSON [[uid,cafeId], ...], 1..20 pairs.
///   Identifiers deliberately use the narrower pilot subset [A-Za-z0-9_-],
///   1..128 characters. One cafe per UID; duplicate UIDs are invalid.
/// * Any presence of a conflicting profile key is invalid, including "false".
///
/// Build definitions are not enumerable in Dart. [fromBuildConfiguration] reads
/// the declared keys below; build tooling must validate unknown/typoed defines.
/// [parse] rejects unknown pilot-prefixed keys when supplied explicitly.
/// This class is intentionally unwired. Device execution remains unapproved.
@immutable
final class AndroidPilotPolicy {
  static const modeKey = 'VELORA_ANDROID_READ_ONLY_PILOT';
  static const bindingsKey = 'VELORA_ANDROID_PILOT_BINDINGS';
  static const projectKey = 'VELORA_FIREBASE_PROJECT';
  static const approvedProject = 'velora-73222';
  static const conflictingKeys = <String>{
    'VELORA_STAGING',
    'USE_FIREBASE_EMULATORS',
    'FIREBASE_EMULATOR_HOST',
    'STAFF_DEMO',
    'AI1_MOCK_RECIPES',
    'RECIPE_CONNECTIVITY_DEMO',
    'AI1_LIVE_RECIPES',
  };
  static const readCapabilities = <AndroidPilotCapability>{
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

  final AndroidPilotState state;
  final String? projectId;
  final String? invalidReason;
  final List<AndroidPilotBinding> bindings;
  const AndroidPilotPolicy._(
    this.state, {
    this.projectId,
    this.invalidReason,
    this.bindings = const [],
  });

  bool get isRestricted => state == AndroidPilotState.restricted;
  bool get isValid => state != AndroidPilotState.invalid;

  /// Empty in normal/invalid mode. This never authorizes an application action.
  Set<AndroidPilotCapability> get capabilities =>
      isRestricted ? readCapabilities : const {};

  bool permits(AndroidPilotCapability capability) =>
      isRestricted && readCapabilities.contains(capability);

  /// Additional restriction only: callers still require current verified Auth,
  /// exact session identity and server-enforced canonical active membership.
  bool matchesBinding({required String uid, required String cafeId}) =>
      isRestricted && bindings.any((b) => b.uid == uid && b.cafeId == cafeId);

  bool permitsForBinding(
    AndroidPilotCapability capability, {
    required String uid,
    required String cafeId,
  }) => permits(capability) && matchesBinding(uid: uid, cafeId: cafeId);

  void requireValidConfiguration() {
    if (!isValid) {
      throw StateError('Invalid Android pilot configuration.');
    }
  }

  factory AndroidPilotPolicy.parse(
    Map<String, String> configuration, {
    required bool isWeb,
    required TargetPlatform platform,
    String? androidFlavor,
  }) {
    AndroidPilotPolicy invalid(String reason) =>
        AndroidPilotPolicy._(AndroidPilotState.invalid, invalidReason: reason);
    final pilotKeys = configuration.keys.where(
      (key) =>
          key.startsWith(modeKey) || key.startsWith('VELORA_ANDROID_PILOT'),
    );
    if (pilotKeys.isEmpty) {
      return const AndroidPilotPolicy._(AndroidPilotState.normal);
    }
    if (pilotKeys.any((key) => key != modeKey && key != bindingsKey)) {
      return invalid('Unknown pilot configuration key.');
    }
    if (configuration[modeKey] != 'true') {
      return invalid('Pilot opt-in must be exactly true.');
    }
    if (isWeb || platform != TargetPlatform.android || androidFlavor != null) {
      return invalid('Pilot requires unflavored native Android.');
    }
    if (configuration[projectKey] != approvedProject) {
      return invalid('Pilot project binding is missing or unsupported.');
    }
    if (conflictingKeys.any(configuration.containsKey)) {
      return invalid(
        'Pilot conflicts with staging, emulator or demo settings.',
      );
    }
    final raw = configuration[bindingsKey];
    if (raw == null || raw.isEmpty || raw.length > 8192) {
      return invalid('Pilot bindings are missing or too large.');
    }
    final idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty || decoded.length > 20) {
        return invalid('Pilot requires 1 to 20 account/workspace pairs.');
      }
      final pairs = <AndroidPilotBinding>[];
      final seen = <String>{};
      for (final pair in decoded) {
        if (pair is! List ||
            pair.length != 2 ||
            pair[0] is! String ||
            pair[1] is! String ||
            !idPattern.hasMatch(pair[0] as String) ||
            !idPattern.hasMatch(pair[1] as String) ||
            !seen.add(pair[0] as String)) {
          return invalid('Malformed or duplicate pilot binding.');
        }
        pairs.add(AndroidPilotBinding._(pair[0] as String, pair[1] as String));
      }
      return AndroidPilotPolicy._(
        AndroidPilotState.restricted,
        projectId: approvedProject,
        bindings: List.unmodifiable(pairs),
      );
    } on FormatException {
      return invalid('Pilot bindings must be valid JSON.');
    }
  }

  /// Captures explicit known build definitions without a mutable global flag.
  /// The caller supplies platform facts and appFlavor at a future startup gate.
  factory AndroidPilotPolicy.fromBuildConfiguration({
    required bool isWeb,
    required TargetPlatform platform,
    String? androidFlavor,
  }) => AndroidPilotPolicy.parse(
    {
      if (const bool.hasEnvironment(modeKey))
        modeKey: const String.fromEnvironment(modeKey),
      if (const bool.hasEnvironment(bindingsKey))
        bindingsKey: const String.fromEnvironment(bindingsKey),
      if (const bool.hasEnvironment(projectKey))
        projectKey: const String.fromEnvironment(projectKey),
      if (const bool.hasEnvironment('VELORA_STAGING'))
        'VELORA_STAGING': const String.fromEnvironment('VELORA_STAGING'),
      if (const bool.hasEnvironment('USE_FIREBASE_EMULATORS'))
        'USE_FIREBASE_EMULATORS': const String.fromEnvironment(
          'USE_FIREBASE_EMULATORS',
        ),
      if (const bool.hasEnvironment('FIREBASE_EMULATOR_HOST'))
        'FIREBASE_EMULATOR_HOST': const String.fromEnvironment(
          'FIREBASE_EMULATOR_HOST',
        ),
      if (const bool.hasEnvironment('STAFF_DEMO'))
        'STAFF_DEMO': const String.fromEnvironment('STAFF_DEMO'),
      if (const bool.hasEnvironment('AI1_MOCK_RECIPES'))
        'AI1_MOCK_RECIPES': const String.fromEnvironment('AI1_MOCK_RECIPES'),
      if (const bool.hasEnvironment('RECIPE_CONNECTIVITY_DEMO'))
        'RECIPE_CONNECTIVITY_DEMO': const String.fromEnvironment(
          'RECIPE_CONNECTIVITY_DEMO',
        ),
      if (const bool.hasEnvironment('AI1_LIVE_RECIPES'))
        'AI1_LIVE_RECIPES': const String.fromEnvironment('AI1_LIVE_RECIPES'),
    },
    isWeb: isWeb,
    platform: platform,
    androidFlavor: androidFlavor,
  );
}
