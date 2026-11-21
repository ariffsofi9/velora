import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/android_sqlite_journal_engine.dart';
import 'package:velora/services/mutation_recovery_service.dart';
import 'package:velora/services/platform_journal_store.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';
import 'package:velora/services/workspace_session.dart';

import 'mutation_recovery_service_test.dart' show syntheticSha256;
import 'workspace_inventory_https_transport_test.dart'
    show FakeClient, Fixture, acknowledgement, response, stock;

const _channel = MethodChannel(AndroidSqliteJournalEngine.channelName);
const _project = AndroidSqliteJournalEngine.projectId;
final _failed = throwsA(isA<PlatformJournalFailure>());

WorkspaceSession _workspace({String uid = 'owner', String cafe = 'cafe'}) =>
    WorkspaceSession.fromVerified(
      CafeWorkspace(
        cafeId: cafe,
        uid: uid,
        ownerUid: uid,
        role: CafeRole.owner,
      ),
    );

String _segment(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

final _prefix = 'journal/1/${_segment(_project)}/${_segment('owner')}/';

// Models the channel contract only. A new engine over this fixture is not an
// Android process restart and does not exercise SQLite or filesystem durability.
final class _ChannelFixture {
  final partitions = <String, (int, Map<String, String>)>{};
  final calls = <String>[];
  int attempts = 0;
  int? failCommit;
  bool malformedSnapshot = false;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final args = call.arguments as Map<Object?, Object?>;
    expect(args['projectId'], _project);
    final scope = '${args['uid']}/${args['cafeId']}';
    final (revision, rows) = partitions[scope] ?? (0, <String, String>{});
    switch (call.method) {
      case 'snapshot':
        return {
          'revision': malformedSnapshot ? -1 : revision,
          'rows': Map<String, String>.of(rows),
        };
      case 'commit':
        attempts++;
        if (attempts == failCommit || args['revision'] != revision) {
          throw PlatformException(code: 'unavailable');
        }
        final writes = Map<String, String>.from(args['writes'] as Map);
        partitions[scope] = (revision + 1, {...rows, ...writes});
        return revision + 1;
      default:
        fail('Unexpected journal method');
    }
  }
}

AndroidSqliteJournalEngine _engine(WorkspaceSession workspace) =>
    AndroidSqliteJournalEngine(workspace: workspace);

MutationRecoveryJournal _journal(WorkspaceSession workspace) =>
    MutationRecoveryJournal(
      PlatformJournalStore(
        engine: _engine(workspace),
        sha256: syntheticSha256,
      ).mutations,
      sha256: syntheticSha256,
    );

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late _ChannelFixture fixture;
  setUp(() {
    fixture = _ChannelFixture();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      fixture.handle,
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  test(
    'stages and commits a batch once, with ordered read-your-writes',
    () async {
      final engine = _engine(_workspace());
      late JournalStorageTransaction escaped;
      await engine.transaction((tx) async {
        escaped = tx;
        await tx.put('${_prefix}b', 'B');
        await tx.put('${_prefix}a', 'A');
        expect(await tx.read('${_prefix}a'), 'A');
        expect(await tx.scan(_prefix, limit: 1), ['${_prefix}a']);
        expect(await tx.scan(_prefix, after: '${_prefix}a', limit: 3), [
          '${_prefix}b',
        ]);
        expect(fixture.calls, ['snapshot']);
      });
      expect(fixture.calls, ['snapshot', 'commit']);
      expect(fixture.partitions['owner/cafe']?.$2, {
        '${_prefix}a': 'A',
        '${_prefix}b': 'B',
      });
      await expectLater(escaped.read('${_prefix}a'), _failed);
    },
  );

  test(
    'callback failure, malformed snapshots and invalidation prevent commit',
    () async {
      final workspace = _workspace();
      final engine = _engine(workspace);
      await expectLater(
        engine.transaction((tx) async {
          await tx.put('${_prefix}key', 'value');
          throw StateError('abort');
        }),
        _failed,
      );
      fixture.malformedSnapshot = true;
      await expectLater(
        engine.transaction((_) async => fail('Unexpected callback')),
        _failed,
      );
      fixture.malformedSnapshot = false;
      await expectLater(
        engine.transaction((tx) async {
          await tx.put('${_prefix}key', 'value');
          workspace.invalidate();
        }),
        _failed,
      );
      expect(fixture.calls, ['snapshot', 'snapshot', 'snapshot']);
      expect(fixture.partitions, isEmpty);
    },
  );

  test(
    'overlapping snapshots cannot overwrite a winning commit or retry',
    () async {
      final workspace = _workspace();
      final staged = Completer<void>();
      final finish = Completer<void>();
      var callbacks = 0;
      final stale = _engine(workspace).transaction((tx) async {
        callbacks++;
        await tx.put('${_prefix}key', 'stale');
        staged.complete();
        await finish.future;
      });
      await staged.future;
      await _engine(
        workspace,
      ).transaction((tx) => tx.put('${_prefix}key', 'winner'));
      final failure = expectLater(stale, _failed);
      finish.complete();
      await failure;
      expect(callbacks, 1);
      expect(fixture.partitions['owner/cafe']?.$2['${_prefix}key'], 'winner');
    },
  );

  for (final phase in [1, 2]) {
    test(
      'failure at journal commit $phase prevents inventory dispatch',
      () async {
        fixture.failCommit = phase;
        final transport = Fixture();
        addTearDown(transport.close);
        final journal = _journal(transport.current!.workspace);
        final adapter = transport.adapter(journal: journal);
        final request = stock();
        await expectLater(
          adapter.adjustStock(request),
          throwsA(isA<InventoryHttpsStockException>()),
        );
        expect(transport.client.requests, isEmpty);
        // The existing transport conservatively retains unknown evidence when
        // persistence fails after prepare, even though it sent no request.
        expect(fixture.attempts, phase == 1 ? 1 : 3);
        final record = await journal.load(
          _project,
          'owner',
          'adjust-stock',
          request.idempotencyKey,
        );
        expect(record?.state, phase == 1 ? null : 'unknown');
      },
    );
  }

  test(
    'serialized bridge evidence supports explicit reconciliation without replay',
    () async {
      final transport = Fixture();
      addTearDown(transport.close);
      final workspace = transport.current!.workspace;
      final journal = _journal(workspace);
      final request = stock();
      transport.client = FakeClient((_) async {
        final pending = await journal.load(
          _project,
          workspace.uid,
          'adjust-stock',
          request.idempotencyKey,
        );
        expect(pending?.state, 'dispatched');
        expect(fixture.partitions['owner/cafe']?.$1, 2);
        return response({
          'error': 'unavailable',
          'outcomeUnknown': true,
        }, status: 503);
      });
      final originalClient = transport.client;
      await expectLater(
        transport.adapter(journal: journal).adjustStock(request),
        throwsA(
          isA<InventoryHttpsStockException>().having(
            (error) => error.transport.outcomeUnknown,
            'unknown',
            true,
          ),
        ),
      );
      expect(originalClient.requests, hasLength(1));
      expect(
        jsonEncode(
          fixture.partitions.values.map((partition) => partition.$2).toList(),
        ),
        isNot(contains('fake.id.token')),
      );

      final restored = Fixture();
      addTearDown(restored.close);
      final restoredJournal = _journal(restored.current!.workspace);
      final pending = (await restoredJournal.load(
        _project,
        'owner',
        'adjust-stock',
        request.idempotencyKey,
      ))!;
      expect(pending.unresolved, isTrue);
      expect(
        await _journal(
          _workspace(cafe: 'different'),
        ).load(_project, 'owner', 'adjust-stock', request.idempotencyKey),
        isNull,
      );
      expect(
        await _journal(
          _workspace(uid: 'other'),
        ).load(_project, 'other', 'adjust-stock', request.idempotencyKey),
        isNull,
      );
      final adapter = restored.adapter(journal: restoredJournal);
      restored.body = {'state': 'unknown'};
      expect((await adapter.reconcile(pending)).committed, isFalse);
      expect(
        (await restoredJournal.load(
          _project,
          'owner',
          'adjust-stock',
          request.idempotencyKey,
        ))?.unresolved,
        isTrue,
      );
      restored.body = {
        'state': 'committed',
        'result': acknowledgement('adjust-stock'),
      };
      expect((await adapter.reconcile(pending)).committed, isTrue);
      expect(
        (await restoredJournal.load(
          _project,
          'owner',
          'adjust-stock',
          request.idempotencyKey,
        ))?.state,
        'acknowledged',
      );
      expect(restored.client.requests.map((request) => request.url.path), [
        '/inventory/reconcile',
        '/inventory/reconcile',
      ]);
    },
  );
}
