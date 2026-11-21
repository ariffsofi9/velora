import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_provisioning_service.dart';

import '../tool/firestore_real_runtime_qualification_runner.dart';

const uid = 'synthetic-owner';
const cafe = 'synthetic-cafe';
const ruleset = 'projects/velora-73222/rulesets/synthetic-candidate';
final now = DateTime.utc(2026, 11, 20);
const paths = {
  'cafes/$cafe': false,
  'cafes/$cafe/members/$uid': false,
  'user_cafe_memberships/$uid': false,
};

class FakeStore
    implements WorkspaceBootstrapStore, WorkspaceBootstrapTransaction {
  int attempts = 0, reads = 0, writes = 0;
  bool replay = false;

  @override
  String newCafeId() => throw StateError('Unexpected allocation');

  @override
  Object serverTimestamp() => Object();

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(WorkspaceBootstrapTransaction) action,
  ) async {
    attempts++;
    final result = await action(this);
    if (replay) await action(this);
    return result;
  }

  @override
  Future<Map<String, dynamic>?> readDocument(String path) async {
    reads++;
    return null;
  }

  @override
  void set(String path, Map<String, dynamic> data) => writes++;
}

Future<bool> bootstrap(RealCase scenario, WorkspaceBootstrapStore store) =>
    store.runTransaction((tx) async {
      await tx.readDocument('user_cafe_memberships/$uid');
      for (final path in paths.keys) {
        tx.set(path, {});
      }
      return true;
    });

void main() {
  late FakeStore store;
  setUp(() => store = FakeStore());

  RealQualificationRunner runner({
    String project = RealQualificationRunner.project,
    String database = RealQualificationRunner.database,
    String approved = ruleset,
    String hash = RealQualificationRunner.sha256,
    Set<String> uids = const {uid},
    Set<String> cafes = const {cafe},
    Map<String, bool> preflight = paths,
    DateTime? expires,
    bool targetMatches = true,
    RealCase scenario = RealCase.bootstrap,
    Duration timeout = RealQualificationRunner.caseTimeout,
    Future<bool> Function(RealCase, WorkspaceBootstrapStore) execute =
        bootstrap,
  }) => RealQualificationRunner.synthetic(
    manifest: RealManifest(
      project: project,
      database: database,
      approvedRuleset: approved,
      evidence: RealRulesEvidence(
        RealQualificationRunner.release,
        ruleset,
        hash,
        now,
      ),
      authorizedUntil: expires ?? now.add(const Duration(minutes: 1)),
      uids: uids,
      cafes: cafes,
      cases: {
        scenario: RealFixture(
          uid: uid,
          ownerUid: uid,
          cafe: cafe,
          preflight: preflight,
          checkedAt: now,
        ),
      },
    ),
    session: () => (uid, scenario != RealCase.unverifiedBootstrap),
    store: store,
    now: () => now,
    targetMatches: targetMatches,
    timeout: timeout,
    execute: execute,
  );

  test('valid bootstrap is bounded and cannot repeat', () async {
    final r = runner();
    expect(await r.run(RealCase.bootstrap), RealObservation.expectedDecision);
    expect(await r.run(RealCase.bootstrap), RealObservation.rejected);
    expect((store.attempts, store.reads, store.writes), (1, 1, 3));
  });

  final rejects = <String, RealQualificationRunner Function()>{
    'wrong project': () => runner(project: 'other'),
    'TEST project': () => runner(project: 'velora-spark-test'),
    'wrong database': () => runner(database: 'other'),
    'SDK binding mismatch': () => runner(targetMatches: false),
    'missing ruleset evidence': () => runner(hash: ''),
    'mismatched ruleset': () => runner(approved: '$ruleset-other'),
    'invalid UID allowlist': () => runner(uids: {uid, 'bad/uid'}),
    'missing cafe allowlist': () => runner(cafes: {}),
    'missing preflight': () => runner(preflight: {}),
    'occupied target': () => runner(preflight: {...paths, 'cafes/$cafe': true}),
    'expired authorization': () => runner(expires: now),
  };
  for (final item in rejects.entries) {
    test(item.key, () async {
      expect(
        await item.value().run(RealCase.bootstrap),
        RealObservation.rejected,
      );
      expect(store.attempts, 0);
    });
  }

  test('unauthorized path stops before document dispatch', () async {
    final r = runner(
      execute: (_, s) => s.runTransaction((tx) async {
        await tx.readDocument('cafes/other');
        return true;
      }),
    );
    expect(await r.run(RealCase.bootstrap), RealObservation.uncertain);
    expect(store.reads, 0);
  });

  test(
    'operation budget rejects repeat reads and SDK callback replay',
    () async {
      final r = runner(
        execute: (_, s) => s.runTransaction((tx) async {
          await tx.readDocument('user_cafe_memberships/$uid');
          await tx.readDocument('user_cafe_memberships/$uid');
          return true;
        }),
      );
      expect(await r.run(RealCase.bootstrap), RealObservation.uncertain);
      expect(store.reads, 1);
      store.replay = true;
      final replay = runner();
      expect(await replay.run(RealCase.bootstrap), RealObservation.uncertain);
      expect((store.attempts, store.reads, store.writes), (2, 2, 3));
    },
  );

  test('timeout fences delayed work and latches uncertain outcome', () async {
    final gate = Completer<void>();
    final finished = Completer<void>();
    final r = runner(
      timeout: const Duration(milliseconds: 10),
      execute: (scenario, s) async {
        await gate.future;
        try {
          return await bootstrap(scenario, s);
        } finally {
          finished.complete();
        }
      },
    );
    expect(await r.run(RealCase.bootstrap), RealObservation.uncertain);
    gate.complete();
    await finished.future;
    expect(await r.run(RealCase.bootstrap), RealObservation.rejected);
    expect(store.attempts, 0);
  });

  test('permission denied before bootstrap commit is inconclusive', () async {
    final r = runner(
      scenario: RealCase.unverifiedBootstrap,
      execute: (_, s) => s.runTransaction((_) async {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
        );
      }),
    );
    expect(
      await r.run(RealCase.unverifiedBootstrap),
      RealObservation.uncertain,
    );
  });

  testWidgets('transaction deadline precedes case deadline', (tester) async {
    final gate = Completer<void>();
    final r = runner(
      execute: (_, s) => s.runTransaction((tx) async {
        await tx.readDocument('user_cafe_memberships/$uid');
        await gate.future;
        tx.set('cafes/$cafe', {});
        return true;
      }),
    );
    final result = r.run(RealCase.bootstrap);
    await tester.pump();
    await tester.pump(RealQualificationRunner.transactionTimeout);
    expect(await result, RealObservation.uncertain);
    gate.complete();
    await tester.pump();
    expect(await r.run(RealCase.bootstrap), RealObservation.rejected);
    expect((store.attempts, store.reads, store.writes), (1, 1, 0));
  });
}
