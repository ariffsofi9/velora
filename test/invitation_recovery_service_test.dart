import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/invitation_recovery_service.dart';

class _Persistence implements InvitationJournalPersistence {
  Object? value;
  bool fail = false;
  int writes = 0;
  @override
  Future<Object?> read(String projectId, String uid) async {
    if (fail) throw StateError('sensitive persistence error');
    return value == null ? null : jsonDecode(jsonEncode(value));
  }

  @override
  Future<bool> compareAndSet(
    String projectId,
    String uid,
    Object? expected,
    Map<String, Object> next,
  ) async {
    if (fail) throw StateError('sensitive persistence error');
    final current = value;
    final same = expected == null
        ? current == null
        : current is Map &&
              expected is Map &&
              current.length == expected.length &&
              expected.keys.every((key) => current[key] == expected[key]);
    if (!same) return false;
    value = Map<String, Object>.from(next);
    writes++;
    return true;
  }
}

const _operation = PendingInvitationOperation(
  projectId: 'velora-spark-test',
  uid: 'owner',
  requestId: 'request_123456789',
  expectedCafeId: 'cafe',
  expectedMembershipGeneration: 7,
);

void main() {
  test(
    'pending metadata survives reconstructed journal with no secrets',
    () async {
      final store = _Persistence();
      await InvitationRecoveryJournal(store).prepare(_operation);
      final restored = await InvitationRecoveryJournal(
        store,
      ).load('velora-spark-test', 'owner');
      expect(restored!.toJson(), _operation.toJson());
      expect((store.value as Map).keys.toSet(), {
        'version',
        'projectId',
        'uid',
        'requestId',
        'expectedCafeId',
        'expectedMembershipGeneration',
        'state',
      });
      expect(store.writes, 1);
      await expectLater(
        InvitationRecoveryJournal(store).prepare(_operation),
        throwsA(isA<InvitationRecoveryFailure>()),
      );
      expect(store.writes, 1);
    },
  );
  test(
    'pending operation cannot be overwritten by a different request or workspace',
    () async {
      final store = _Persistence();
      final journal = InvitationRecoveryJournal(store);
      await journal.prepare(_operation);
      await expectLater(
        journal.prepare(
          const PendingInvitationOperation(
            projectId: 'velora-spark-test',
            uid: 'owner',
            requestId: 'different_123456789',
            expectedCafeId: 'other',
            expectedMembershipGeneration: 8,
          ),
        ),
        throwsA(isA<InvitationRecoveryFailure>()),
      );
      expect(store.value, _operation.toJson());
    },
  );
  test('atomic prepare permits only one contender', () async {
    final store = _Persistence();
    final journal = InvitationRecoveryJournal(store);
    final outcomes = await Future.wait(
      List.generate(2, (_) async {
        try {
          await journal.prepare(_operation);
          return true;
        } catch (_) {
          return false;
        }
      }),
    );
    expect(outcomes.where((value) => value).length, 1);
    expect(store.writes, 1);
  });
  test(
    'persistence failure is sanitized and cannot acknowledge a prepare',
    () async {
      final store = _Persistence()..fail = true;
      await expectLater(
        InvitationRecoveryJournal(store).prepare(_operation),
        throwsA(isA<InvitationRecoveryFailure>()),
      );
      expect(store.writes, 0);
      expect(
        const InvitationRecoveryFailure().toString(),
        isNot(contains('sensitive')),
      );
    },
  );
  for (final patch in [
    <String, Object?>{'version': 2},
    {'version': 1.0},
    {'uid': 'other'},
    {'projectId': 'velora-73222'},
    {'expectedMembershipGeneration': '7'},
    {'state': 'resolved'},
    {'code': 'must-not-be-stored'},
  ]) {
    test('corrupt or unsupported journal rejects $patch', () async {
      final store = _Persistence()..value = {..._operation.toJson(), ...patch};
      final journal = InvitationRecoveryJournal(store);
      await expectLater(
        journal.load('velora-spark-test', 'owner'),
        throwsA(isA<InvitationRecoveryFailure>()),
      );
      await expectLater(
        journal.prepare(_operation),
        throwsA(isA<InvitationRecoveryFailure>()),
      );
      expect(store.writes, 0);
    });
  }
  test(
    'direct response permits explicit next operation without clearing durable pending state',
    () async {
      final store = _Persistence();
      final journal = InvitationRecoveryJournal(store);
      await journal.prepare(_operation);
      journal.recordDefiniteResponse(_operation);
      expect(
        (await journal.load('velora-spark-test', 'owner'))!.state,
        'pending',
      );
      expect(store.writes, 1);
      const next = PendingInvitationOperation(
        projectId: 'velora-spark-test',
        uid: 'owner',
        requestId: 'next_request_123456789',
        expectedCafeId: 'cafe',
        expectedMembershipGeneration: 7,
      );
      final restarted = _Persistence()
        ..value = jsonDecode(jsonEncode(store.value));
      await expectLater(
        InvitationRecoveryJournal(restarted).prepare(next),
        throwsA(isA<InvitationRecoveryFailure>()),
      );
      await journal.prepare(next);
      expect(store.value, next.toJson());
    },
  );
  test(
    'unknown and committed observations do not mutate or clear pending journal',
    () async {
      final store = _Persistence();
      final journal = InvitationRecoveryJournal(store);
      await journal.prepare(_operation);
      for (final state in [null, 'pending', 'revoked', 'redeemed', 'expired']) {
        final response = state == null
            ? {'state': 'unknown'}
            : {'state': 'committed', 'invitationState': state};
        final observation = InvitationReceiptObservation.parse(response);
        expect(observation.state, state == null ? 'unknown' : 'committed');
        expect(
          (await journal.load('velora-spark-test', 'owner'))!.state,
          'pending',
        );
      }
      expect(store.writes, 1);
    },
  );
  for (final response in [
    null,
    {},
    {'state': 'unknown', 'code': 'secret'},
    {'state': 'committed'},
    {'state': 'committed', 'invitationState': 'active'},
    {
      'state': 'committed',
      'invitationState': 'pending',
      'email': 'private@example.test',
    },
  ]) {
    test('malformed or over-disclosing observation is rejected: $response', () {
      expect(
        () => InvitationReceiptObservation.parse(response),
        throwsA(isA<InvitationRecoveryFailure>()),
      );
    });
  }
}
