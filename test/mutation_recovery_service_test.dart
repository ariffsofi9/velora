import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/mutation_recovery_service.dart';

/// Test-only deterministic integrity stand-in, explicitly NOT SHA-256. The
/// production provider is an injected dependency; no crypto readiness is claimed.
String syntheticSha256(String value) {
  var hash = 2166136261;
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ byte) * 16777619) & 0xffffffff;
  }
  return List.filled(8, hash.toRadixString(16).padLeft(8, '0')).join();
}

class FakeMutationPersistence implements MutationJournalPersistence {
  final values = <String, Object?>{};
  bool failRead = false, failWrite = false, lostAck = false;
  Future<void> Function(int)? beforeWrite;
  int writes = 0;
  @override
  Future<Object?> read(String key) async {
    if (failRead) throw StateError('SECRET');
    return values[key] == null ? null : jsonDecode(jsonEncode(values[key]));
  }

  @override
  Future<bool> compareAndSet(
    String key,
    int? revision,
    Map<String, Object> value,
  ) async {
    writes++;
    await beforeWrite?.call(writes);
    if (failWrite) throw StateError('SECRET');
    final current = values[key];
    if (revision == null
        ? current != null
        : current is! Map || current['revision'] != revision) {
      return false;
    }
    values[key] = jsonDecode(jsonEncode(value));
    if (lostAck) throw StateError('SECRET lost write acknowledgement');
    return true;
  }
}

Map<String, Object> journalRequest({
  String cafe = 'cafe',
  int generation = 0,
}) => {
  'idempotencyKey': 'stock-request-0001',
  'itemId': 'item',
  'expectedVersion': 1,
  'direction': 'in',
  'quantity': 2,
  'expectedCafeId': cafe,
  'expectedMembershipGeneration': generation,
};
Map<String, Object> journalAck() => {
  'cafeId': 'cafe',
  'itemId': 'item',
  'direction': 'in',
  'quantity': 2,
  'resultingQuantity': 7,
  'version': 2,
  'adjusted': true,
};
MutationRecoveryJournal journal(
  FakeMutationPersistence store, {
  Duration timeout = const Duration(milliseconds: 100),
}) => MutationRecoveryJournal(store, sha256: syntheticSha256, timeout: timeout);
Future<MutationDispatchPermit> prepare(
  MutationRecoveryJournal j, {
  Map<String, Object>? request,
}) => j.prepare(
  projectId: 'velora-spark-test',
  uid: 'owner',
  operation: 'adjust-stock',
  request: request ?? journalRequest(),
);
Future<PendingMutationOperation?> load(MutationRecoveryJournal j) =>
    j.load('velora-spark-test', 'owner', 'adjust-stock', 'stock-request-0001');

void main() {
  test(
    'late originating failure cannot overwrite an observed committed acknowledgement',
    () async {
      final storage = FakeMutationPersistence(), j = journal(storage);
      final permit = await prepare(j);
      await j.markDispatched(permit);
      final pending = (await load(j))!;
      await j.recordObservation(
        pending,
        MutationReceiptObservation.parse(pending, {
          'state': 'committed',
          'result': journalAck(),
        }),
      );
      await expectLater(
        j.finish(permit, uncertain: true),
        throwsA(isA<MutationRecoveryFailure>()),
      );
      expect((await load(j))!.state, 'acknowledged');
      expect((await load(j))!.result, journalAck());
    },
  );
  test(
    'Node-generated UTF-8 SHA-256 reference fixes the client canonical JSON contract',
    () async {
      const canonical =
          '{"operation":"adjust-stock","request":{"direction":"in","expectedCafeId":"cafe","expectedMembershipGeneration":0,"expectedVersion":1,"idempotencyKey":"stock-request-0001","itemId":"item","quantity":2}}';
      const digest =
          'f11d848bbb8e2e1461538507049f43b7a63f1a4e3a82058af0c843fe460ac4ce';
      final storage = FakeMutationPersistence();
      final j = MutationRecoveryJournal(
        storage,
        sha256: (input) {
          expect(input, canonical);
          return digest;
        },
      );
      await prepare(j);
      expect((await load(j))!.payloadDigest, digest);
      expect(
        mutationJournalCanonicalJson('adjust-stock', journalRequest()),
        canonical,
      );
    },
  );

  test(
    'a rejected record after restart is never a reconstructed permission to dispatch',
    () async {
      final storage = FakeMutationPersistence(), j = journal(storage);
      final permit = await prepare(j);
      await j.markDispatched(permit);
      await j.finish(permit);
      expect((await load(j))!.state, 'rejected');
      await expectLater(
        prepare(journal(storage)),
        throwsA(isA<MutationRecoveryFailure>()),
      );
    },
  );
  test(
    'atomic prepare, one dispatch permit and durable acknowledgement',
    () async {
      final storage = FakeMutationPersistence(), j = journal(storage);
      final permit = await prepare(j);
      expect((await load(j))!.state, 'prepared');
      await j.markDispatched(permit);
      expect((await load(j))!.state, 'dispatched');
      await expectLater(
        j.markDispatched(permit),
        throwsA(isA<MutationRecoveryFailure>()),
      );
      await j.finish(permit, result: journalAck());
      final saved = (await load(j))!;
      expect(saved.state, 'acknowledged');
      expect(saved.result, journalAck());
      await expectLater(
        j.finish(permit, uncertain: true),
        throwsA(isA<MutationRecoveryFailure>()),
      );
      expect((await load(j))!.state, 'acknowledged');
      expect(() => saved.request['quantity'] = 10, throwsUnsupportedError);
    },
  );

  for (final phase in ['prepared', 'dispatched', 'unknown']) {
    test('restart at $phase never reconstructs a dispatch permit', () async {
      final storage = FakeMutationPersistence(), first = journal(storage);
      final permit = await prepare(first);
      if (phase != 'prepared') await first.markDispatched(permit);
      if (phase == 'unknown') await first.finish(permit, uncertain: true);
      final restarted = journal(storage), pending = (await load(restarted))!;
      expect(pending.unresolved, true);
      await expectLater(
        prepare(restarted),
        throwsA(
          isA<MutationRecoveryFailure>().having(
            (e) => e.outcomeUnknown,
            'unresolved',
            true,
          ),
        ),
      );
      final before = jsonEncode(storage.values);
      await restarted.recordObservation(
        pending,
        MutationReceiptObservation.parse(pending, {'state': 'unknown'}),
      );
      expect(jsonEncode(storage.values), before);
    });
  }

  test(
    'two reconstructed tabs CAS once, with no process-local mutex assumption',
    () async {
      final storage = FakeMutationPersistence(),
          first = journal(storage),
          second = journal(storage);
      final outcomes = await Future.wait([
        prepare(first).then((_) => true, onError: (_) => false),
        prepare(second).then((_) => true, onError: (_) => false),
      ]);
      expect(outcomes.where((ok) => ok).length, 1);
      expect(storage.values.length, 1);
    },
  );

  test(
    'payload conflict and different cafe/generation cannot replace an unresolved key',
    () async {
      final storage = FakeMutationPersistence(), j = journal(storage);
      await prepare(j);
      for (final request in [
        journalRequest(cafe: 'other'),
        journalRequest(generation: 7),
        {...journalRequest(), 'quantity': 3},
      ]) {
        await expectLater(
          prepare(j, request: request),
          throwsA(isA<MutationRecoveryFailure>()),
        );
      }
      expect((await load(j))!.request, journalRequest());
    },
  );

  test(
    'originating definite rejection alone permits explicit unchanged retry',
    () async {
      final storage = FakeMutationPersistence(),
          j = journal(storage),
          permit = await prepare(j);
      await j.markDispatched(permit);
      await j.finish(permit);
      expect((await load(j))!.state, 'rejected');
      final retried = await prepare(j);
      await j.markDispatched(retried);
      await j.finish(retried, uncertain: true);
      expect((await load(j))!.everUncertain, true);
      await expectLater(prepare(j), throwsA(isA<MutationRecoveryFailure>()));
    },
  );

  test(
    'explicit committed observation resolves uncertainty and retains historical metadata',
    () async {
      final storage = FakeMutationPersistence(),
          j = journal(storage),
          permit = await prepare(j);
      await j.markDispatched(permit);
      await j.finish(permit, uncertain: true);
      final restarted = journal(storage), pending = (await load(restarted))!;
      final observation = MutationReceiptObservation.parse(pending, {
        'state': 'committed',
        'result': journalAck(),
      });
      await restarted.recordObservation(pending, observation);
      final saved = (await load(restarted))!;
      expect(saved.state, 'acknowledged');
      expect(saved.everUncertain, true);
      expect(saved.result, journalAck());
      await expectLater(
        restarted.recordObservation(pending, observation),
        throwsA(isA<MutationRecoveryFailure>()),
      );
    },
  );

  for (final phase in ['read', 'write', 'lost-ack', 'timeout']) {
    test(
      'storage $phase failure is sanitized; late storage completion grants no permit',
      () async {
        final storage = FakeMutationPersistence();
        final j = journal(storage, timeout: const Duration(milliseconds: 15));
        final release = Completer<void>();
        storage.failRead = phase == 'read';
        storage.failWrite = phase == 'write';
        storage.lostAck = phase == 'lost-ack';
        if (phase == 'timeout') storage.beforeWrite = (_) => release.future;
        await expectLater(prepare(j), throwsA(isA<MutationRecoveryFailure>()));
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (['lost-ack', 'timeout'].contains(phase)) {
          expect((await load(journal(storage)))!.unresolved, true);
          await expectLater(
            prepare(journal(storage)),
            throwsA(isA<MutationRecoveryFailure>()),
          );
        }
      },
    );
  }

  for (final entry in <String, Object>{
    'schemaVersion': 2,
    'revision': 0,
    'projectId': 'velora-73222',
    'uid': 'staff',
    'operation': 'lifecycle',
    'payloadDigest': '0' * 64,
    'state': 'deleted',
    'everUncertain': 'true',
    'request': {'authorization': 'SECRET'},
    'extra': 'SECRET',
  }.entries) {
    test('corrupt journal ${entry.key} fails closed', () async {
      final storage = FakeMutationPersistence(), j = journal(storage);
      await prepare(j);
      final key = storage.values.keys.single;
      storage.values[key] = {
        ...(storage.values[key] as Map),
        entry.key: entry.value,
      };
      await expectLater(load(j), throwsA(isA<MutationRecoveryFailure>()));
      await expectLater(prepare(j), throwsA(isA<MutationRecoveryFailure>()));
    });
  }

  for (final raw in [
    null,
    {},
    {'state': 'missing'},
    {'state': 'unknown', 'result': {}},
    {
      'state': 'committed',
      'result': {...journalAck(), 'itemId': 'other'},
    },
    {
      'state': 'committed',
      'result': {...journalAck(), 'resultingQuantity': 0},
    },
    {
      'state': 'committed',
      'result': {...journalAck(), 'adjusted': false},
    },
    {
      'state': 'committed',
      'result': {...journalAck(), 'secret': 'SECRET'},
    },
  ]) {
    test(
      'malformed observation ${jsonEncode(raw)} cannot acknowledge journal',
      () async {
        final storage = FakeMutationPersistence(), j = journal(storage);
        await prepare(j);
        final pending = (await load(j))!;
        expect(
          () => MutationReceiptObservation.parse(pending, raw),
          throwsA(isA<MutationRecoveryFailure>()),
        );
        expect((await load(j))!.state, 'prepared');
      },
    );
  }

  test('namespace isolation and forbidden credential fields', () async {
    final storage = FakeMutationPersistence(), j = journal(storage);
    await prepare(j);
    expect(
      await j.load(
        'velora-73222',
        'owner',
        'adjust-stock',
        'stock-request-0001',
      ),
      null,
    );
    expect(
      await j.load(
        'velora-spark-test',
        'staff',
        'adjust-stock',
        'stock-request-0001',
      ),
      null,
    );
    await expectLater(
      prepare(j, request: {...journalRequest(), 'idToken': 'SECRET'}),
      throwsA(isA<MutationRecoveryFailure>()),
    );
    expect(jsonEncode(storage.values).contains('SECRET'), false);
  });
}
