// Standalone composition entry. No Firebase initialization or default clients.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:velora/firebase_options.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/owner_email_verification.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_store.dart';

enum RealCase {
  bootstrap,
  unverifiedBootstrap,
  existingMapping,
  conflictingTarget,
  malformedBootstrap,
  incompleteBootstrap,
  staff,
  owner,
  unverifiedRead,
  revoked,
  crossCafe,
  generationMismatch,
  brokenOwnerChain;

  bool get isBootstrap => index <= incompleteBootstrap.index;
  bool get expectsDenial =>
      this != bootstrap &&
      this != existingMapping &&
      this != staff &&
      this != owner;
}

enum RealObservation {
  rejected,
  expectedDecision,
  unexpectedDecision,
  uncertain,
}

final class RealRulesEvidence {
  final String release, ruleset, sha256;
  final DateTime observedAt;
  const RealRulesEvidence(
    this.release,
    this.ruleset,
    this.sha256,
    this.observedAt,
  );
}

final class RealFixture {
  final String uid, cafe, ownerUid;
  final String? homeCafe;
  final int generation;
  // Exact paths checked by the operator, with true meaning present.
  final Map<String, bool> preflight;
  final DateTime? checkedAt;

  RealFixture({
    required this.uid,
    required this.cafe,
    required this.ownerUid,
    this.homeCafe,
    this.generation = 0,
    Map<String, bool> preflight = const {},
    this.checkedAt,
  }) : preflight = Map.unmodifiable(preflight);

  String get cafePath => 'cafes/$cafe';
  String get mapping => 'user_cafe_memberships/$uid';
  String get member => '$cafePath/members/$uid';
  List<String> get bootstrapPaths => [cafePath, member, mapping];
  List<String> get resolverPaths => [
    mapping,
    cafePath,
    member,
    if (uid != ownerUid) ...[
      '$cafePath/members/$ownerUid',
      'user_cafe_memberships/$ownerUid',
    ],
  ];
}

final class RealManifest {
  final String project, database, approvedRuleset;
  final DateTime authorizedUntil;
  final RealRulesEvidence evidence;
  final Set<String> uids, cafes;
  final Map<RealCase, RealFixture> cases;

  RealManifest({
    required this.project,
    required this.database,
    required this.approvedRuleset,
    required this.authorizedUntil,
    required this.evidence,
    required Set<String> uids,
    required Set<String> cafes,
    required Map<RealCase, RealFixture> cases,
  }) : uids = Set.unmodifiable(uids),
       cafes = Set.unmodifiable(cafes),
       cases = Map.unmodifiable(cases);
}

final class RealQualificationRunner {
  static const project = 'velora-73222';
  static const database = '(default)';
  static const release = 'projects/$project/releases/cloud.firestore';
  static const sha256 =
      '73844e2174c028696bf5b36f22fbc2a6e2a3f6849ad9848913135e393d173611';
  static const transactionTimeout = Duration(seconds: 10);
  static const caseTimeout = Duration(seconds: 25);
  static const runWindow = Duration(minutes: 6);

  final RealManifest manifest;
  final bool Function() _target;
  final (String?, bool) Function() _session;
  final Future<bool> Function(RealCase, RealFixture, _Fence) _execute;
  final DateTime Function() _now;
  final Duration _limit;
  final _clock = Stopwatch()..start();
  final _attempted = <RealCase>{};
  bool _busy = false, _halted = false;

  RealQualificationRunner._(
    this.manifest,
    this._target,
    this._session,
    this._execute,
    this._now,
    this._limit,
  );

  factory RealQualificationRunner.withClients({
    required RealManifest manifest,
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
  }) {
    final bootstrap = FirestoreWorkspaceBootstrapStore(
      firestore: firestore,
      maxAttempts: 1,
      timeout: transactionTimeout,
    );
    final reads = FirestoreWorkspaceStore(
      firestore: firestore,
      maxAttempts: 1,
      timeout: transactionTimeout,
    );
    return RealQualificationRunner._(
      manifest,
      () {
        final settings = firestore.settings;
        return auth.app.name != '[DEFAULT]' &&
            auth.app.name == firestore.app.name &&
            auth.app.options == DefaultFirebaseOptions.android &&
            firestore.app.options == auth.app.options &&
            firestore.databaseId == database &&
            (settings.host == null ||
                settings.host == 'firestore.googleapis.com') &&
            settings.sslEnabled != false;
      },
      () {
        final user = auth.currentUser;
        return (user?.uid, user?.emailVerified == true);
      },
      (scenario, fixture, fence) async {
        final user = auth.currentUser;
        if (user == null || user.uid != fixture.uid) throw const _Guard();
        final claims = (await user.getIdTokenResult()).claims;
        fence.check();
        if (claims?['sub'] != fixture.uid ||
            claims?['email_verified'] != user.emailVerified) {
          throw const _Guard();
        }
        final store = _BootstrapStore(bootstrap, fixture, fence);
        if (scenario == RealCase.bootstrap ||
            scenario == RealCase.existingMapping) {
          final result = await FirebaseWorkspaceProvisioner(
            store: store,
            resolveProfile: () => DefaultFirebaseOptions.android,
            activeOptions: () => firestore.app.options,
            currentUid: () {
              fence.check();
              return auth.currentUser?.uid;
            },
            verification: FirebaseOwnerEmailVerification(
              auth: auth,
              operationTimeout: const Duration(seconds: 5),
            ),
          ).createWorkspace(_request);
          return result.created == (scenario == RealCase.bootstrap);
        }
        if (scenario == RealCase.staff || scenario == RealCase.owner) {
          final result = await WorkspaceResolver(
            auth: auth,
            debugLog: (_) {},
            store: _ReadStore(reads, fence),
          ).resolve();
          return result.uid == fixture.uid &&
              result.cafeId == fixture.cafe &&
              result.ownerUid == fixture.ownerUid &&
              result.role ==
                  (scenario == RealCase.staff
                      ? CafeRole.staff
                      : CafeRole.owner) &&
              result.membershipGeneration == fixture.generation;
        }
        if (scenario.isBootstrap) {
          await _probeBootstrap(scenario, fixture, store);
        } else {
          await _ReadStore(
            reads,
            fence,
          ).readTransaction((reader) => reader.readDocument(fixture.cafePath));
        }
        return false;
      },
      DateTime.now,
      caseTimeout,
    );
  }

  @visibleForTesting
  factory RealQualificationRunner.synthetic({
    required RealManifest manifest,
    required (String?, bool) Function() session,
    required Future<bool> Function(RealCase, WorkspaceBootstrapStore) execute,
    required WorkspaceBootstrapStore store,
    DateTime Function()? now,
    Duration timeout = caseTimeout,
    bool targetMatches = true,
  }) => RealQualificationRunner._(
    manifest,
    () => targetMatches,
    session,
    (scenario, fixture, fence) =>
        execute(scenario, _BootstrapStore(store, fixture, fence)),
    now ?? DateTime.now,
    timeout < caseTimeout ? timeout : caseTimeout,
  );

  Future<RealObservation> run(RealCase scenario) async {
    if (_busy || _halted) return RealObservation.rejected;
    final fixture = manifest.cases[scenario];
    if (fixture == null ||
        !_valid(scenario, fixture) ||
        !_attempted.add(scenario)) {
      _halted = true;
      return RealObservation.rejected;
    }
    _busy = true;
    final fence = _Fence(
      _readPaths(scenario, fixture),
      _writePaths(scenario, fixture),
      () {
        if (!_valid(scenario, fixture)) throw const _Guard();
      },
    );
    try {
      final remaining = [
        _limit,
        runWindow - _clock.elapsed,
        manifest.authorizedUntil.difference(_now()),
      ].reduce((a, b) => a < b ? a : b);
      if (remaining <= Duration.zero) throw const _Guard();
      final expected = await _execute(
        scenario,
        fixture,
        fence,
      ).timeout(remaining);
      fence.check();
      if (!fence.completed) throw const _Guard();
      if (expected && !scenario.expectsDenial) {
        return RealObservation.expectedDecision;
      }
      _halted = true;
      return RealObservation.unexpectedDecision;
    } on FirebaseException catch (error) {
      if (scenario.expectsDenial &&
          (scenario.isBootstrap ? fence.completed : fence._reads == 1) &&
          error.plugin == 'cloud_firestore' &&
          error.code == 'permission-denied' &&
          _valid(scenario, fixture)) {
        return RealObservation.expectedDecision;
      }
      _halted = true;
      return RealObservation.uncertain;
    } catch (_) {
      _halted = true;
      return RealObservation.uncertain;
    } finally {
      fence.active = false;
      _busy = false;
    }
  }

  bool _valid(RealCase scenario, RealFixture fixture) {
    try {
      final now = _now();
      final evidence = manifest.evidence;
      if (_clock.elapsed >= runWindow ||
          !now.isBefore(manifest.authorizedUntil) ||
          manifest.project != project ||
          manifest.database != database ||
          evidence.release != release ||
          evidence.sha256 != sha256 ||
          evidence.ruleset != manifest.approvedRuleset ||
          !_ruleset.hasMatch(evidence.ruleset) ||
          !_fresh(evidence.observedAt, now) ||
          !_target()) {
        return false;
      }
      if (manifest.uids.isEmpty ||
          manifest.cafes.isEmpty ||
          !manifest.uids.every(_id) ||
          !manifest.cafes.every(_id) ||
          !manifest.uids.containsAll([fixture.uid, fixture.ownerUid]) ||
          !manifest.cafes.contains(fixture.cafe) ||
          fixture.generation < 0 ||
          fixture.generation > 9007199254740991) {
        return false;
      }
      if ((scenario.isBootstrap || scenario == RealCase.owner) &&
          fixture.uid != fixture.ownerUid) {
        return false;
      }
      if (scenario == RealCase.staff && fixture.uid == fixture.ownerUid) {
        return false;
      }
      if (scenario == RealCase.crossCafe &&
          (fixture.homeCafe == fixture.cafe ||
              !manifest.cafes.contains(fixture.homeCafe))) {
        return false;
      }
      if (scenario.isBootstrap) {
        final checked = fixture.checkedAt;
        if (checked == null ||
            !_fresh(checked, now) ||
            !fixture.preflight.keys.toSet().containsAll(
              fixture.bootstrapPaths,
            ) ||
            fixture.preflight.length != 3) {
          return false;
        }
        for (final path in fixture.bootstrapPaths) {
          final present =
              scenario == RealCase.existingMapping ||
              (scenario == RealCase.conflictingTarget &&
                  path == fixture.cafePath);
          if (fixture.preflight[path] != present) return false;
        }
      }
      final verified =
          scenario != RealCase.unverifiedRead &&
          scenario != RealCase.unverifiedBootstrap;
      return _session() == (fixture.uid, verified);
    } catch (_) {
      return false;
    }
  }
}

final _ruleset = RegExp(r'^projects/velora-73222/rulesets/[a-zA-Z0-9_-]+$');
bool _id(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    value != '.' &&
    value != '..' &&
    value.trim() == value &&
    !RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(value);
bool _fresh(DateTime at, DateTime now) =>
    !at.isAfter(now) && now.difference(at) < RealQualificationRunner.runWindow;

List<String> _readPaths(RealCase scenario, RealFixture f) {
  if (scenario == RealCase.existingMapping) return f.resolverPaths;
  if (scenario.isBootstrap) return [f.mapping];
  if (scenario.expectsDenial) return [f.cafePath];
  return f.resolverPaths;
}

List<String> _writePaths(RealCase scenario, RealFixture f) {
  if (!scenario.isBootstrap || scenario == RealCase.existingMapping) return [];
  if (scenario == RealCase.incompleteBootstrap) return [f.cafePath];
  return f.bootstrapPaths;
}

const _request = WorkspaceCreationRequest(
  businessName: 'Synthetic Rules Qualification',
  businessType: 'Bakery',
  address: '',
  inventoryUnit: 'kg',
  lowStockAlerts: false,
  expiryReminders: false,
  reminderDays: 1,
);

// Fixed synthetic payloads for Rules denials that production validation blocks.
Future<void> _probeBootstrap(
  RealCase scenario,
  RealFixture f,
  _BootstrapStore store,
) async {
  final now = store.serverTimestamp();
  final base = {
    'status': 'active',
    'schemaVersion': 1,
    'createdAt': now,
    'updatedAt': now,
  };
  await store.runTransaction((tx) async {
    if (await tx.readDocument(f.mapping) != null) throw const _Guard();
    tx.set(f.cafePath, {
      ...base,
      if (scenario == RealCase.malformedBootstrap) 'schemaVersion': 2,
      'ownerUid': f.uid,
      'name': _request.businessName,
      'businessType': _request.businessType,
      'address': _request.address,
      'inventoryPreferences': {
        'unit': _request.inventoryUnit,
        'lowStockAlerts': _request.lowStockAlerts,
        'expiryReminders': _request.expiryReminders,
        'reminderDays': _request.reminderDays,
      },
    });
    if (scenario != RealCase.incompleteBootstrap) {
      tx.set(f.member, {
        ...base,
        'uid': f.uid,
        'cafeId': f.cafe,
        'role': 'owner',
      });
      tx.set(f.mapping, {...base, 'uid': f.uid, 'cafeId': f.cafe});
    }
  });
}

final class _Guard implements Exception {
  const _Guard();
}

final class _Fence {
  final List<String> reads, writes;
  final void Function() validate;
  final _clock = Stopwatch();
  bool active = true, dispatched = false, _entered = false, completed = false;
  int _reads = 0, _writes = 0;
  _Fence(this.reads, this.writes, this.validate);

  void check() {
    if (!active ||
        _clock.elapsed >= RealQualificationRunner.transactionTimeout) {
      throw const _Guard();
    }
    validate();
  }

  Future<T> transaction<T>(Future<T> Function() action) async {
    check();
    if (dispatched) throw const _Guard();
    dispatched = true;
    _clock.start();
    try {
      return await action().timeout(RealQualificationRunner.transactionTimeout);
    } finally {
      _clock.stop();
    }
  }

  Future<T> callback<T>(Future<T> Function() action) async {
    check();
    if (_entered) throw const _Guard();
    _entered = true;
    final result = await action();
    check();
    if (_reads != reads.length || _writes != writes.length) {
      throw const _Guard();
    }
    completed = true;
    return result;
  }

  void read(String path) {
    check();
    if (_reads >= reads.length || reads[_reads] != path) throw const _Guard();
    _reads++;
  }

  void write(String path) {
    check();
    if (_writes >= writes.length || writes[_writes] != path) {
      throw const _Guard();
    }
    _writes++;
  }
}

class _Reader implements WorkspaceReader {
  final WorkspaceReader reader;
  final _Fence fence;
  _Reader(this.reader, this.fence);

  @override
  Future<Map<String, dynamic>?> readDocument(String path) async {
    fence.read(path);
    final result = await reader.readDocument(path);
    fence.check();
    return result;
  }
}

final class _ReadStore implements WorkspaceStore {
  final WorkspaceStore store;
  final _Fence fence;
  _ReadStore(this.store, this.fence);

  @override
  Future<T> readTransaction<T>(Future<T> Function(WorkspaceReader) read) =>
      fence.transaction(
        () => store.readTransaction(
          (reader) => fence.callback(() => read(_Reader(reader, fence))),
        ),
      );
}

final class _BootstrapStore implements WorkspaceBootstrapStore {
  final WorkspaceBootstrapStore store;
  final RealFixture fixture;
  final _Fence fence;
  _BootstrapStore(this.store, this.fixture, this.fence);

  @override
  String newCafeId() => fixture.cafe;
  @override
  Object serverTimestamp() => store.serverTimestamp();
  @override
  Future<T> runTransaction<T>(
    Future<T> Function(WorkspaceBootstrapTransaction) action,
  ) => fence.transaction(
    () => store.runTransaction(
      (tx) => fence.callback(() => action(_Writer(tx, fence))),
    ),
  );
}

final class _Writer extends _Reader implements WorkspaceBootstrapTransaction {
  final WorkspaceBootstrapTransaction tx;
  _Writer(this.tx, _Fence fence) : super(tx, fence);

  @override
  void set(String path, Map<String, dynamic> data) {
    fence.write(path);
    tx.set(path, data);
  }
}
