import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/platform_journal_store.dart';
import 'package:velora/services/mutation_recovery_service.dart';
import 'package:velora/services/invitation_recovery_service.dart';
import 'mutation_recovery_service_test.dart'
    show syntheticSha256, journalRequest, journalAck;

// SIMULATION ONLY: serialized in-memory transactions, not disk persistence,
// browser locking, process isolation, power-loss safety or provider acceptance.
class FakeTransactionalJournalEngine implements TransactionalJournalEngine {
  Map<String, String> values = {};
  Set<String> index = {};
  Future<void> _tail = Future.value();
  int commits = 0, transactions = 0, callbacks = 0;
  int? failPut, capacity;
  bool failCommit = false, lostAck = false, failRead = false, failScan = false;
  Completer<void>? commitGate, enteredCommit;
  List<String> Function(List<String>)? scanFault;
  _Transaction? _last;
  @override
  Future<T> transaction<T>(
    Future<T> Function(JournalStorageTransaction tx) action,
  ) async {
    transactions++;
    final prior = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await prior;
    final tx = _Transaction(this, Map.of(values), Set.of(index));
    _last = tx;
    try {
      callbacks++;
      final result = await action(tx);
      tx.active = false;
      if (tx.puts > 0) {
        if (enteredCommit != null && !enteredCommit!.isCompleted) {
          enteredCommit!.complete();
        }
        await commitGate?.future;
        if (failCommit) throw StateError('PRIVATE COMMIT');
        values = tx.values;
        index = tx.index;
        commits++;
        if (lostAck) throw StateError('PRIVATE LOST ACK');
      }
      return result;
    } finally {
      tx.active = false;
      release.complete();
    }
  }
}

class _Transaction implements JournalStorageTransaction {
  final FakeTransactionalJournalEngine engine;
  final Map<String, String> values;
  final Set<String> index;
  bool active = true;
  int puts = 0;
  _Transaction(this.engine, this.values, this.index);
  void check() {
    if (!active) throw StateError('PRIVATE EXPIRED TRANSACTION');
  }

  @override
  Future<Object?> read(String key) async {
    check();
    if (engine.failRead) throw StateError('PRIVATE READ');
    return values[key];
  }

  @override
  Future<void> put(String key, String value) async {
    check();
    puts++;
    if (engine.capacity != null &&
        !values.containsKey(key) &&
        values.length >= engine.capacity!) {
      throw StateError('PRIVATE CAPACITY');
    }
    values[key] = value;
    // Fail between record and index writes in the draft. Neither may commit.
    if (engine.failPut == puts) throw StateError('PRIVATE PARTIAL WRITE');
    index.add(key);
  }

  @override
  Future<List<String>> scan(
    String prefix, {
    String? after,
    required int limit,
  }) async {
    check();
    if (engine.failScan) throw StateError('PRIVATE SCAN');
    final result =
        index
            .where(
              (k) =>
                  k.startsWith(prefix) &&
                  (after == null || k.compareTo(after) > 0),
            )
            .toList()
          ..sort();
    final bounded = result.take(limit).toList();
    return engine.scanFault?.call(bounded) ?? bounded;
  }
}

const project = 'velora-spark-test', uid = 'owner', operation = 'adjust-stock';
String storageKey({
  String p = project,
  String actor = uid,
  String key = 'stock-request-0001',
}) => jsonEncode([p, actor, operation, key]);
Map<String, Object> prepared({
  String p = project,
  String actor = uid,
  String key = 'stock-request-0001',
}) {
  final request = {...journalRequest(), 'idempotencyKey': key};
  return {
    'schemaVersion': 1,
    'projectId': p,
    'uid': actor,
    'operation': operation,
    'payloadDigest': syntheticSha256(
      mutationJournalCanonicalJson(operation, request),
    ),
    'state': 'prepared',
    'revision': 1,
    'everUncertain': false,
    'request': request,
  };
}

Map<String, Object> next(
  Map<String, Object> value, {
  String state = 'dispatched',
  bool uncertain = false,
  bool ack = false,
}) => {
  ...value,
  'revision': (value['revision'] as int) + 1,
  'state': ack ? 'acknowledged' : state,
  'everUncertain': uncertain || value['everUncertain'] == true,
  if (ack) 'result': journalAck(),
};
PendingInvitationOperation invitation({
  String p = project,
  String actor = uid,
  String id = 'invitation-request1',
}) => PendingInvitationOperation(
  projectId: p,
  uid: actor,
  requestId: id,
  expectedCafeId: 'cafe',
  expectedMembershipGeneration: 7,
);
PlatformJournalStore store(
  TransactionalJournalEngine e, {
  Duration timeout = const Duration(seconds: 1),
}) =>
    PlatformJournalStore(engine: e, sha256: syntheticSha256, timeout: timeout);
MutationRecoveryJournal journal(PlatformJournalStore s) =>
    MutationRecoveryJournal(s.mutations, sha256: syntheticSha256);
Future<MutationDispatchPermit> prepare(MutationRecoveryJournal j) => j.prepare(
  projectId: project,
  uid: uid,
  operation: operation,
  request: journalRequest(),
);
Matcher storageFailure = isA<PlatformJournalFailure>();
Matcher mutationFailure = isA<MutationRecoveryFailure>();
Matcher invitationFailure = isA<InvitationRecoveryFailure>();

MutationRecoveryJournal guardedJournal(PlatformJournalStore s) =>
    MutationRecoveryJournal(s.guardedMutations, sha256: s.sha256);

Future<MutationDispatchPermit> prepareGuarded(
  MutationRecoveryJournal journal,
  String key, {
  String action = 'adjust-stock',
  String p = project,
  String actor = uid,
  String cafe = 'cafe',
  String item = 'item',
  int generation = 0,
  int version = 1,
  String direction = 'out',
}) {
  return journal.prepare(
    projectId: p,
    uid: actor,
    operation: action == 'archive' || action == 'restore'
        ? 'lifecycle'
        : action,
    request: {
      'idempotencyKey': key,
      'expectedCafeId': cafe,
      'expectedMembershipGeneration': generation,
      if (action != 'create') 'itemId': item,
      if (action != 'create') 'expectedVersion': version,
      if (action == 'adjust-stock') ...{'direction': direction, 'quantity': 2},
      if (action == 'archive' || action == 'restore') 'action': action,
      if (action == 'create' || action == 'update') ...{
        'name': key,
        'category': 'food',
        'unit': 'pcs',
        'expiryDate': '2026-12-01',
        'imageUrl': '',
        if (action == 'create') 'quantity': 0,
      },
    },
  );
}

void guardedAdmissionTests() {
  for (final (action, direction) in [
    ('adjust-stock', 'out'),
    ('adjust-stock', 'in'),
    ('update', 'out'),
    ('archive', 'out'),
    ('restore', 'out'),
  ]) {
    final label = action == 'adjust-stock' ? 'Stock $direction' : action;
    test(
      'concurrent different-key Stock Out and $label share one item hold',
      () async {
        final engine = FakeTransactionalJournalEngine();
        final first = guardedJournal(store(engine));
        final second = guardedJournal(store(engine));
        final results = await Future.wait(
          [
            prepareGuarded(first, 'stock-request-0001'),
            prepareGuarded(
              second,
              'other-request-0002',
              action: action,
              version: 2,
              direction: direction,
            ),
          ].map((attempt) async {
            try {
              return await attempt;
            } on InventoryOperationPending catch (error) {
              return error;
            }
          }),
        );
        expect(results.whereType<MutationDispatchPermit>(), hasLength(1));
        expect(results.whereType<InventoryOperationPending>(), hasLength(1));
        expect(engine.commits, 1);
        expect(engine.values, hasLength(2));
        expect(engine.index, engine.values.keys.toSet());
      },
    );
  }

  test(
    'different Add drafts compete in the same café without blocking stock',
    () async {
      final engine = FakeTransactionalJournalEngine();
      final first = guardedJournal(store(engine));
      final second = guardedJournal(store(engine));
      final results = await Future.wait(
        [
          prepareGuarded(first, 'create-request-0001', action: 'create'),
          prepareGuarded(second, 'create-request-0002', action: 'create'),
        ].map((attempt) async {
          try {
            return await attempt;
          } on InventoryOperationPending catch (error) {
            return error;
          }
        }),
      );
      expect(results.whereType<MutationDispatchPermit>(), hasLength(1));
      expect(results.whereType<InventoryOperationPending>(), hasLength(1));
      await prepareGuarded(second, 'stock-request-0001');
      await prepareGuarded(
        second,
        'create-request-0003',
        action: 'create',
        cafe: 'other-cafe',
      );
      expect(engine.commits, 3);
    },
  );

  test(
    'session discovery hides stale generations, foreign workspaces and invitation data',
    () async {
      final engine = FakeTransactionalJournalEngine();
      final s = store(engine);
      final original = guardedJournal(s);
      final permit = await prepareGuarded(original, 'stock-request-0001');
      await original.markDispatched(permit);
      await original.finish(permit, uncertain: true);
      await InvitationRecoveryJournal(s.invitations).prepare(invitation());
      final restarted = store(engine);
      final j = guardedJournal(restarted);
      await expectLater(
        prepareGuarded(j, 'stock-request-0002', generation: 1, version: 2),
        throwsA(isA<InventoryOperationPending>()),
      );
      expect(
        await j.load(project, uid, operation, 'stock-request-0002'),
        isNull,
      );
      await prepareGuarded(
        j,
        'stock-request-0003',
        item: 'another-item',
        generation: 1,
      );
      await prepareGuarded(j, 'stock-request-0004', cafe: 'other-cafe');
      await prepareGuarded(j, 'stock-request-0005', actor: 'another-owner');
      await prepareGuarded(j, 'stock-request-0006', p: 'velora-73222');

      final current = await restarted.pendingInventory(
        project,
        uid,
        cafeId: 'cafe',
        membershipGeneration: 1,
      );
      expect(current.map((record) => record.stableKey), ['stock-request-0003']);
      final historical = await restarted.pendingInventory(
        project,
        uid,
        cafeId: 'cafe',
        membershipGeneration: 0,
      );
      expect(historical.single.stableKey, 'stock-request-0001');
      expect(historical.single.state, 'unknown');
    },
  );

  for (final settle in ['observed commit', 'definite rejection']) {
    test(
      '$settle releases the item while preserving the original history',
      () async {
        final engine = FakeTransactionalJournalEngine();
        final j = guardedJournal(store(engine));
        final permit = await prepareGuarded(j, 'stock-request-0001');
        await j.markDispatched(permit);
        if (settle == 'observed commit') {
          await j.finish(permit, uncertain: true);
          final pending = (await j.load(
            project,
            uid,
            operation,
            'stock-request-0001',
          ))!;
          await j.recordObservation(
            pending,
            MutationReceiptObservation.parse(pending, {'state': 'unknown'}),
          );
          await expectLater(
            prepareGuarded(j, 'stock-request-0002', version: 2),
            throwsA(isA<InventoryOperationPending>()),
          );
          await j.recordObservation(
            pending,
            MutationReceiptObservation.parse(pending, {
              'state': 'committed',
              'result': {...journalAck(), 'direction': 'out'},
            }),
          );
        } else {
          await j.finish(permit);
        }
        final settled = (await j.load(
          project,
          uid,
          operation,
          'stock-request-0001',
        ))!;
        expect(settled.unresolved, false);
        final before = Map.of(engine.values);
        await prepareGuarded(
          j,
          'stock-request-0002',
          version: settle == 'observed commit' ? 2 : 1,
        );
        expect(
          (await j.load(
            project,
            uid,
            operation,
            'stock-request-0001',
          ))!.toJson(),
          settled.toJson(),
        );
        for (final entry in before.entries) {
          expect(engine.values[entry.key], entry.value);
        }
      },
    );
  }

  test(
    'guard reaches a later pending page before granting a preparation',
    () async {
      final engine = FakeTransactionalJournalEngine();
      final s = store(engine);
      final legacy = journal(s);
      for (var i = 0; i < 102; i++) {
        await prepareGuarded(
          legacy,
          'legacy-stock-${i.toString().padLeft(4, '0')}',
          item: 'item-$i',
        );
      }
      final first = await s.pending(project, uid, limit: 100);
      final continuation = await s.pending(
        project,
        uid,
        cursor: first.nextCursor,
      );
      final lateRecord = continuation.records.last;
      final target = (lateRecord.payload['request'] as Map)['itemId'] as String;
      final before = Map.of(engine.values);
      await expectLater(
        prepareGuarded(guardedJournal(s), 'stock-request-0001', item: target),
        throwsA(isA<InventoryOperationPending>()),
      );
      expect(engine.values, before);
    },
  );

  for (final fault in [
    'unavailable',
    'omitted heads',
    'corrupt history',
    'failed commit',
  ]) {
    test('guard fails closed without a partial record on $fault', () async {
      final engine = FakeTransactionalJournalEngine();
      final s = store(engine);
      final j = guardedJournal(s);
      await prepareGuarded(j, 'stock-request-0001');
      await prepareGuarded(j, 'stock-request-0002', item: 'different-item');
      switch (fault) {
        case 'unavailable':
          engine.failScan = true;
        case 'omitted heads':
          engine.scanFault = (keys) =>
              keys.length > 1 && keys.first.contains('/records/')
              ? keys.skip(1).toList()
              : keys;
        case 'corrupt history':
          final history = engine.values.keys.firstWhere(
            (key) => key.contains('/history/'),
          );
          engine.values[history] = '{}';
        case 'failed commit':
          engine.failCommit = true;
      }
      final before = Map.of(engine.values);
      final index = Set.of(engine.index);
      await expectLater(
        prepareGuarded(j, 'stock-request-0003', item: 'unaffected-item'),
        throwsA(
          allOf(mutationFailure, isNot(isA<InventoryOperationPending>())),
        ),
      );
      expect(engine.values, before);
      expect(engine.index, index);
      expect(engine.commits, 2);
    });
  }
}

void main() {
  guardedAdmissionTests();
  test(
    'construction is inert; both existing persistence interfaces have no platform default',
    () {
      final e = FakeTransactionalJournalEngine(), s = store(e);
      expect(s.mutations, isA<MutationJournalPersistence>());
      expect(s.invitations, isA<InvitationJournalPersistence>());
      expect(e.transactions, 0);
      expect(() => store(e, timeout: Duration.zero), throwsA(storageFailure));
    },
  );
  test(
    'inventory CAS compares absence/revision, clones values, and atomically indexes head/history',
    () async {
      final e = FakeTransactionalJournalEngine(),
          s = store(e),
          first = prepared(),
          key = storageKey();
      expect(await s.mutations.read(key), isNull);
      expect(await s.mutations.compareAndSet(key, null, first), true);
      expect(e.values, hasLength(2));
      expect(e.index, e.values.keys.toSet());
      first['uid'] = 'changed-after-write';
      final stored = Map<String, Object>.from(
        await s.mutations.read(key) as Map,
      );
      expect(stored['uid'], uid);
      expect(await s.mutations.compareAndSet(key, null, prepared()), false);
      expect(await s.mutations.compareAndSet(key, 1, next(stored)), true);
      expect(await s.mutations.compareAndSet(key, 1, next(stored)), false);
      expect(e.values, hasLength(3));
      expect(e.index, e.values.keys.toSet());
      expect(() => e._last!.read('escaped'), throwsA(anything));
    },
  );
  test(
    'invitation CAS uses complete structural value and retains old pending snapshots',
    () async {
      final e = FakeTransactionalJournalEngine(),
          s = store(e),
          original = invitation().toJson();
      expect(
        await s.invitations.compareAndSet(project, uid, null, original),
        true,
      );
      final reordered = <String, Object>{
        for (final k in original.keys.toList().reversed) k: original[k]!,
      };
      final replacement = invitation(id: 'invitation-request2').toJson();
      expect(
        await s.invitations.compareAndSet(project, uid, reordered, replacement),
        true,
      );
      expect(
        await s.invitations.compareAndSet(
          project,
          uid,
          original,
          invitation(id: 'invitation-request3').toJson(),
        ),
        false,
      );
      expect(await s.invitations.read(project, uid), replacement);
      expect(
        e.values.values.any(
          (raw) =>
              (jsonDecode(raw) as Map)['payload']['requestId'] ==
              original['requestId'],
        ),
        true,
      );
      expect(e.values, hasLength(3));
      expect(e.index, e.values.keys.toSet());
    },
  );
  for (final kind in ['mutation', 'invitation']) {
    test(
      '$kind competing writers across facades permit exactly one expected-absence commit',
      () async {
        final e = FakeTransactionalJournalEngine(), a = store(e), b = store(e);
        final results = await Future.wait(
          kind == 'mutation'
              ? [
                  a.mutations.compareAndSet(storageKey(), null, prepared()),
                  b.mutations.compareAndSet(storageKey(), null, prepared()),
                ]
              : [
                  a.invitations.compareAndSet(
                    project,
                    uid,
                    null,
                    invitation().toJson(),
                  ),
                  b.invitations.compareAndSet(
                    project,
                    uid,
                    null,
                    invitation(id: 'invitation-request2').toJson(),
                  ),
                ],
        );
        expect(results.where((v) => v), hasLength(1));
        expect(e.commits, 1);
        expect(e.values, hasLength(2));
      },
    );
  }
  for (final failureAt in ['first-put', 'second-put', 'commit', 'capacity']) {
    test(
      '$failureAt failure rolls back record and primary index without authorizing dispatch',
      () async {
        final e = FakeTransactionalJournalEngine();
        if (failureAt == 'first-put') e.failPut = 1;
        if (failureAt == 'second-put') e.failPut = 2;
        if (failureAt == 'commit') e.failCommit = true;
        if (failureAt == 'capacity') e.capacity = 1;
        final s = store(e);
        var dispatched = 0;
        await expectLater(() async {
          await prepare(journal(s));
          dispatched++;
        }(), throwsA(mutationFailure));
        expect(dispatched, 0);
        expect(e.values, isEmpty);
        expect(e.index, isEmpty);
      },
    );
  }
  test(
    'prepare cannot acknowledge until the simulated engine completes commit',
    () async {
      final e = FakeTransactionalJournalEngine()
        ..commitGate = Completer<void>()
        ..enteredCommit = Completer<void>();
      final s = store(e);
      var acknowledged = false;
      final pending = s.mutations
          .compareAndSet(storageKey(), null, prepared())
          .then((ok) {
            acknowledged = ok;
          });
      await e.enteredCommit!.future;
      expect(acknowledged, false);
      expect(e.values, isEmpty);
      e.commitGate!.complete();
      await pending;
      expect(acknowledged, true);
      expect(e.values, hasLength(2));
    },
  );
  for (final kind in ['mutation', 'invitation']) {
    test(
      '$kind lost commit acknowledgement keeps evidence but grants no dispatch',
      () async {
        final e = FakeTransactionalJournalEngine()..lostAck = true;
        final s = store(e);
        var dispatched = 0;
        final pending = () async {
          if (kind == 'mutation') {
            await prepare(journal(s));
          } else {
            await InvitationRecoveryJournal(
              s.invitations,
            ).prepare(invitation());
          }
          dispatched++;
        }();
        await expectLater(
          pending,
          throwsA(kind == 'mutation' ? mutationFailure : invitationFailure),
        );
        expect(dispatched, 0);
        expect(e.values, hasLength(2));
        expect(e.index, e.values.keys.toSet());
        e.lostAck = false;
        final recovered = await store(e).pending(project, uid);
        expect(recovered.records, hasLength(1));
      },
    );
  }
  test(
    'timed-out transaction may commit late but cannot return a prepare permission',
    () async {
      final e = FakeTransactionalJournalEngine()
        ..commitGate = Completer<void>()
        ..enteredCommit = Completer<void>();
      final s = store(e, timeout: const Duration(milliseconds: 15));
      var dispatched = 0;
      final attempt = () async {
        await prepare(journal(s));
        dispatched++;
      }();
      final checked = expectLater(attempt, throwsA(mutationFailure));
      await e.enteredCommit!.future;
      await checked;
      e.commitGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(dispatched, 0);
      expect((await store(e).pending(project, uid)).records, hasLength(1));
      await expectLater(prepare(journal(store(e))), throwsA(mutationFailure));
    },
  );
  for (final patch in [
    {'schemaVersion': 2},
    {'uid': 'other'},
    {'payloadDigest': 'bad'},
    {'revision': 0},
    {'authorization': 'DO-NOT-STORE'},
    {'everUncertain': true},
  ]) {
    test(
      'malformed inventory write is rejected before persistence: $patch',
      () async {
        final e = FakeTransactionalJournalEngine(), s = store(e);
        await expectLater(
          s.mutations.compareAndSet(storageKey(), null, {
            ...prepared(),
            ...patch,
          }),
          throwsA(mutationFailure),
        );
        expect(e.values, isEmpty);
      },
    );
  }
  for (final patch in [
    {'version': 2},
    {'uid': 'other'},
    {'state': 'acknowledged'},
    {'code': 'DO-NOT-STORE'},
  ]) {
    test(
      'malformed invitation write is rejected before persistence: $patch',
      () async {
        final e = FakeTransactionalJournalEngine(), s = store(e);
        await expectLater(
          s.invitations.compareAndSet(project, uid, null, {
            ...invitation().toJson(),
            ...patch,
          }),
          throwsA(invitationFailure),
        );
        expect(e.values, isEmpty);
      },
    );
  }
  for (final corrupt in [
    'json',
    'version',
    'head-missing',
    'history-missing',
    'history-mismatch',
    'index-missing',
    'index-dangling',
  ]) {
    test(
      'stored $corrupt corruption is never interpreted as an empty journal',
      () async {
        final e = FakeTransactionalJournalEngine(), s = store(e);
        await s.mutations.compareAndSet(storageKey(), null, prepared());
        final head = e.values.keys.singleWhere((k) => k.contains('/records/'));
        final history = e.values.keys.singleWhere(
          (k) => k.contains('/history/'),
        );
        switch (corrupt) {
          case 'json':
            e.values[head] = '{';
          case 'version':
            final raw = jsonDecode(e.values[head]!) as Map;
            raw['formatVersion'] = 2;
            e.values[head] = jsonEncode(raw);
          case 'head-missing':
            e.values.remove(head);
            e.index.remove(head);
          case 'history-missing':
            e.values.remove(history);
            e.index.remove(history);
          case 'history-mismatch':
            e.values[history] = '{}';
          case 'index-missing':
            e.index.remove(head);
          case 'index-dangling':
            e.values.remove(head);
            e.values.remove(history);
        }
        await expectLater(
          s.mutations.read(storageKey()),
          throwsA(mutationFailure),
        );
      },
    );
  }
  test(
    'valid update cannot change original payload or erase uncertainty/history',
    () async {
      final e = FakeTransactionalJournalEngine(),
          s = store(e),
          first = prepared();
      await s.mutations.compareAndSet(storageKey(), null, first);
      final changedRequest = {
        ...journalRequest(),
        'expectedMembershipGeneration': 9,
      };
      final changed = {
        ...next(first),
        'request': changedRequest,
        'payloadDigest': syntheticSha256(
          mutationJournalCanonicalJson(operation, changedRequest),
        ),
      };
      await expectLater(
        s.mutations.compareAndSet(storageKey(), 1, changed),
        throwsA(mutationFailure),
      );
      final unknown = next(first, state: 'unknown', uncertain: true);
      expect(await s.mutations.compareAndSet(storageKey(), 1, unknown), true);
      await expectLater(
        s.mutations.compareAndSet(storageKey(), 2, {
          ...next(unknown, ack: true),
          'everUncertain': false,
        }),
        throwsA(mutationFailure),
      );
      final acknowledged = next(unknown, ack: true);
      expect(
        await s.mutations.compareAndSet(storageKey(), 2, acknowledged),
        true,
      );
      final erase = next(acknowledged, state: 'unknown', uncertain: true)
        ..remove('result');
      await expectLater(
        s.mutations.compareAndSet(storageKey(), 3, erase),
        throwsA(mutationFailure),
      );
      expect(
        await s.mutations.compareAndSet(
          storageKey(),
          2,
          next(unknown, state: 'unknown', uncertain: true),
        ),
        false,
      );
      expect(
        e.values.values.where((s) => s.contains('"state":"unknown"')),
        hasLength(1),
      );
    },
  );
  test(
    'pending pages are deterministic, bounded, scoped and include invitations',
    () async {
      final e = FakeTransactionalJournalEngine(), s = store(e);
      for (var i = 0; i < 4; i++) {
        await s.mutations.compareAndSet(
          storageKey(key: 'stock-request-000$i'),
          null,
          prepared(key: 'stock-request-000$i'),
        );
      }
      await s.invitations.compareAndSet(
        project,
        uid,
        null,
        invitation().toJson(),
      );
      await s.mutations.compareAndSet(
        storageKey(actor: 'other'),
        null,
        prepared(actor: 'other'),
      );
      await s.mutations.compareAndSet(
        storageKey(p: 'velora-73222'),
        null,
        prepared(p: 'velora-73222'),
      );
      final keys = <String>[];
      String? cursor;
      do {
        final page = await s.pending(project, uid, limit: 2, cursor: cursor);
        expect(page.records.length, lessThanOrEqualTo(2));
        keys.addAll(page.records.map((r) => '${r.kind}:${r.journalKey}'));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(keys, hasLength(5));
      expect(keys.toSet(), hasLength(5));
      expect(
        keys,
        (await s.pending(
          project,
          uid,
        )).records.map((r) => '${r.kind}:${r.journalKey}').toList(),
      );
      final first = (await s.pending(project, uid)).records.first;
      first.payload['uid'] = 'changed-copy';
      expect((await s.pending(project, uid)).records.first.payload['uid'], uid);
    },
  );
  test(
    'settled first page retains a continuation rather than hiding later pending records',
    () async {
      final e = FakeTransactionalJournalEngine(), s = store(e);
      for (final key in ['stock-request-0001', 'stock-request-0002']) {
        await s.mutations.compareAndSet(
          storageKey(key: key),
          null,
          prepared(key: key),
        );
      }
      final firstKey = (await s.pending(project, uid)).records.first.journalKey;
      final first = Map<String, Object>.from(
        await s.mutations.read(firstKey) as Map,
      );
      await s.mutations.compareAndSet(firstKey, 1, next(first, ack: true));
      final page = await s.pending(project, uid, limit: 1);
      expect(page.records, isEmpty);
      expect(page.nextCursor, isNotNull);
      expect(
        (await s.pending(
          project,
          uid,
          limit: 1,
          cursor: page.nextCursor,
        )).records,
        hasLength(1),
      );
    },
  );
  test(
    'invalid/cross-account cursor, limits and noncanonical keys fail closed',
    () async {
      final e = FakeTransactionalJournalEngine(), s = store(e);
      for (final key in [
        '[]',
        '["velora-spark-test", "owner", "adjust-stock", "key"]',
        '${storageKey()} ',
        '["unknown","owner","adjust-stock","key"]',
      ]) {
        await expectLater(s.mutations.read(key), throwsA(mutationFailure));
      }
      await s.mutations.compareAndSet(storageKey(), null, prepared());
      await s.mutations.compareAndSet(
        storageKey(actor: 'other'),
        null,
        prepared(actor: 'other'),
      );
      final foreign = e.values.keys.firstWhere(
        (k) =>
            k.contains('/records/') &&
            (jsonDecode(e.values[k]!) as Map)['uid'] == 'other',
      );
      for (final cursor in [foreign, 'not-a-cursor']) {
        await expectLater(
          s.pending(project, uid, cursor: cursor),
          throwsA(storageFailure),
        );
      }
      await expectLater(
        s.pending(project, uid, limit: 0),
        throwsA(storageFailure),
      );
      await expectLater(
        s.pending(project, uid, limit: 101),
        throwsA(storageFailure),
      );
    },
  );
  for (final fault in ['duplicate', 'foreign', 'missing', 'look-ahead']) {
    test(
      'discovery validates malformed $fault index evidence including look-ahead',
      () async {
        final e = FakeTransactionalJournalEngine(), s = store(e);
        for (final key in ['stock-request-0001', 'stock-request-0002']) {
          await s.mutations.compareAndSet(
            storageKey(key: key),
            null,
            prepared(key: key),
          );
        }
        if (fault == 'look-ahead') {
          final heads =
              e.values.keys.where((k) => k.contains('/records/')).toList()
                ..sort();
          e.values[heads.last] = '{}';
        } else if (fault == 'missing') {
          final head = e.values.keys.firstWhere((k) => k.contains('/records/'));
          e.values.remove(head);
        } else {
          e.scanFault = (keys) => keys.length == 2
              ? fault == 'duplicate'
                    ? [keys.first, keys.first]
                    : ['foreign', keys.last]
              : keys;
        }
        await expectLater(
          s.pending(project, uid, limit: 1),
          throwsA(storageFailure),
        );
      },
    );
  }
  test(
    'restart reconstruction preserves evidence, never dispatch permits or invitation replacement permission',
    () async {
      final e = FakeTransactionalJournalEngine(), s = store(e), j = journal(s);
      final permit = await prepare(j);
      await j.markDispatched(permit);
      await j.finish(permit, uncertain: true);
      await InvitationRecoveryJournal(s.invitations).prepare(invitation());
      final restarted = store(e), restored = journal(restarted);
      expect((await restarted.pending(project, uid)).records, hasLength(2));
      await expectLater(prepare(restored), throwsA(mutationFailure));
      await expectLater(
        restored.markDispatched(permit),
        throwsA(mutationFailure),
      );
      await expectLater(
        InvitationRecoveryJournal(
          restarted.invitations,
        ).prepare(invitation(id: 'invitation-request2')),
        throwsA(invitationFailure),
      );
      expect(e.commits, 4);
    },
  );
  test(
    'explicit originating invitation replacement keeps prior history after restart',
    () async {
      final e = FakeTransactionalJournalEngine(),
          s = store(e),
          j = InvitationRecoveryJournal(s.invitations);
      await j.prepare(invitation());
      j.recordDefiniteResponse(invitation());
      await j.prepare(invitation(id: 'invitation-request2'));
      expect(
        e.values.values.any(
          (v) =>
              (jsonDecode(v) as Map)['payload']['requestId'] ==
              'invitation-request1',
        ),
        true,
      );
      await expectLater(
        InvitationRecoveryJournal(
          store(e).invitations,
        ).prepare(invitation(id: 'invitation-request3')),
        throwsA(invitationFailure),
      );
    },
  );
  test(
    'read/scan failures are sanitized and capacity cannot evict unresolved evidence',
    () async {
      final e = FakeTransactionalJournalEngine(), s = store(e);
      await s.mutations.compareAndSet(storageKey(), null, prepared());
      final original = Map.of(e.values);
      e.failRead = true;
      await expectLater(
        s.mutations.read(storageKey()),
        throwsA(mutationFailure),
      );
      e.failRead = false;
      e.failScan = true;
      await expectLater(s.pending(project, uid), throwsA(storageFailure));
      e.failScan = false;
      e.capacity = e.values.length;
      await expectLater(
        s.invitations.compareAndSet(project, uid, null, invitation().toJson()),
        throwsA(invitationFailure),
      );
      expect(e.values, original);
      expect(e.index, original.keys.toSet());
    },
  );
}
