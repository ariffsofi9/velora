// These tests deliberately exercise the SDK's JavaScript browser APIs.
// ignore_for_file: depend_on_referenced_packages
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import 'package:flutter_test/flutter_test.dart';
import 'package:velora/journal_qualification/indexed_db_journal_engine.dart';
import 'package:velora/journal_qualification/web_main.dart';
import 'package:velora/services/platform_journal_store.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';

var _sequence = 0;
String _database() =>
    '${IndexedDbJournalEngine.databaseName}-test-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';

Future<web.IDBDatabase> _openNative(String name, {int? version}) {
  final request = version == null
      ? web.window.indexedDB.open(name)
      : web.window.indexedDB.open(name, version);
  final result = Completer<web.IDBDatabase>();
  request.onsuccess = ((web.Event _) {
    result.complete(request.result as web.IDBDatabase);
  }).toJS;
  request.onerror = ((web.Event _) {
    result.completeError(StateError('Native open failed'));
  }).toJS;
  return result.future;
}

Future<String?> _nativeSnapshot(
  String name,
  String store, {
  String? value,
}) async {
  final db = await _openNative(name);
  try {
    final tx = db.transaction(
      store.toJS,
      value == null ? 'readonly' : 'readwrite',
    );
    final complete = Completer<void>();
    tx.oncomplete = ((web.Event _) => complete.complete()).toJS;
    tx.onabort = ((web.Event _) {
      complete.completeError(StateError('Native transaction aborted'));
    }).toJS;
    final table = tx.objectStore(store);
    final key = IndexedDbJournalEngine.snapshotKey.toJS;
    final request = value == null ? table.get(key) : table.put(value.toJS, key);
    await complete.future;
    return (request.result as JSString?)?.toDart;
  } finally {
    db.close();
  }
}

Matcher _failedStorage() => throwsA(isA<PlatformJournalFailure>());

void main() {
  test(
    'REAL inventory database acknowledges a strict write and reopens',
    () async {
      const name = IndexedDbJournalEngine.inventoryDatabase;
      final first = await IndexedDbJournalEngine.open(name: name);
      try {
        await first.transaction(
          (tx) => tx.put('synthetic/head', '{"state":"dispatched"}'),
        );
      } finally {
        first.close();
      }
      final reopened = await IndexedDbJournalEngine.open(name: name);
      addTearDown(reopened.close);
      expect(
        await reopened.transaction((tx) => tx.read('synthetic/head')),
        '{"state":"dispatched"}',
      );
      await expectLater(
        IndexedDbJournalEngine.open(
          name: name,
          store: IndexedDbJournalEngine.receiptStore,
        ),
        _failedStorage(),
      );
    },
  );

  test(
    'creates schema, commits, reopens and retrieves persisted revision',
    () async {
      final name = _database();
      final first = await IndexedDbJournalEngine.open(name: name);
      try {
        await first.transaction((tx) async {
          expect(await tx.read('head'), isNull);
          await tx.put('history/1', '{"version":1}');
          await tx.put('head', '{"version":1}');
        });
      } finally {
        first.close();
      }
      final reopened = await IndexedDbJournalEngine.open(name: name);
      addTearDown(reopened.close);
      await reopened.transaction((tx) async {
        expect(await tx.read('head'), '{"version":1}');
        expect(await tx.scan('history/', limit: 2), ['history/1']);
      });
      final raw = await _nativeSnapshot(
        name,
        IndexedDbJournalEngine.journalStore,
      );
      expect(jsonDecode(raw!), {
        'revision': 1,
        'rows': {'head': '{"version":1}', 'history/1': '{"version":1}'},
      });
    },
  );

  test(
    'competing connections reject stale snapshots without overwriting',
    () async {
      final name = _database();
      final first = await IndexedDbJournalEngine.open(name: name);
      final second = await IndexedDbJournalEngine.open(name: name);
      addTearDown(first.close);
      addTearDown(second.close);
      final captured = Completer<void>();
      final release = Completer<void>();
      final stale = first.transaction((tx) async {
        expect(await tx.read('head'), isNull);
        captured.complete();
        await release.future;
        await tx.put('head', '{"writer":1}');
        await tx.put('history/1', '{"writer":1}');
      });
      final rejected = expectLater(stale, _failedStorage());
      await captured.future;
      try {
        await second.transaction((tx) => tx.put('head', '{"writer":2}'));
      } finally {
        release.complete();
      }
      await rejected;
      await first.transaction((tx) async {
        expect(await tx.read('head'), '{"writer":2}');
        expect(await tx.read('history/1'), isNull);
      });
    },
  );

  test('failed callback publishes none of its staged writes', () async {
    final engine = await IndexedDbJournalEngine.open(name: _database());
    addTearDown(engine.close);
    await expectLater(
      engine.transaction((tx) async {
        await tx.put('head', '{"revision":1}');
        throw StateError('abort the callback');
      }),
      _failedStorage(),
    );
    expect(await engine.transaction((tx) => tx.read('head')), isNull);
  });

  test('unavailable storage fails closed', () async {
    await expectLater(
      IndexedDbJournalEngine.open(name: _database(), factory: () => null),
      _failedStorage(),
    );
  });

  test('storage failure at dispatch sends no mutation', () async {
    final name = _database();
    final fixture = await ChromeRecoveryQualification.open(database: name);
    addTearDown(fixture.close);
    await fixture.prepare();
    await _nativeSnapshot(
      name,
      IndexedDbJournalEngine.journalStore,
      value: '{"revision":1,"rows":{}}',
    );
    await expectLater(fixture.dispatch(), throwsA(isA<Exception>()));
    expect(fixture.mutationRequests, 0);
    expect(await fixture.dispatchCount(), 0);
  });

  test('foreign schema version is rejected and preserved', () async {
    final name = _database();
    final db = await _openNative(name, version: 2);
    db.close();
    await expectLater(
      IndexedDbJournalEngine.open(name: name),
      _failedStorage(),
    );
    final preserved = await _openNative(name);
    expect(preserved.version, 2);
    preserved.close();
  });

  test('malformed stored snapshot is rejected and preserved', () async {
    final name = _database();
    final engine = await IndexedDbJournalEngine.open(name: name);
    addTearDown(engine.close);
    await _nativeSnapshot(
      name,
      IndexedDbJournalEngine.journalStore,
      value: '{"revision":3,"rows":{}}',
    );
    await expectLater(
      engine.transaction((tx) => tx.read('head')),
      _failedStorage(),
    );
    expect(
      await _nativeSnapshot(name, IndexedDbJournalEngine.journalStore),
      '{"revision":3,"rows":{}}',
    );
  });

  test(
    'reopen preserves original identity, digest and request without auto-observation',
    () async {
      final name = _database();
      final first = await ChromeRecoveryQualification.open(database: name);
      await first.prepare();
      await first.dispatch();
      final original = (await first.load())!;
      expect(original.state, 'unknown');
      expect(first.mutationRequests, 1);
      final raw = (await _nativeSnapshot(
        name,
        IndexedDbJournalEngine.journalStore,
      ))!;
      final rows = (jsonDecode(raw) as Map)['rows'] as Map;
      final states = rows.values.map((encoded) {
        final record = jsonDecode(encoded as String) as Map;
        return (record['payload'] as Map)['state'];
      });
      expect(states, containsAll(['prepared', 'dispatched', 'unknown']));
      await first.close();

      final recovered = await ChromeRecoveryQualification.open(database: name);
      addTearDown(recovered.close);
      final pending = (await recovered.load())!;
      expect(pending.toJson(), original.toJson());
      expect(recovered.workspace, isNot(same(first.workspace)));
      expect(recovered.observationRequests, 0);
      expect(recovered.mutationRequests, 0);
      await expectLater(recovered.prepare(), _failedStorage());
      expect((await recovered.observe(pending)).committed, true);
      final settled = (await recovered.load())!;
      expect(settled.state, 'acknowledged');
      expect(settled.stableKey, original.stableKey);
      expect(settled.payloadDigest, original.payloadDigest);
      expect(settled.request, original.request);
      expect((await recovered.observe(settled)).committed, true);
      expect(recovered.observationRequests, 2);
      expect(recovered.mutationRequests, 0);
      expect(await recovered.dispatchCount(), 1);
    },
  );

  for (final kind in ['missing', 'conflicting', 'not committed']) {
    test('$kind receipt never settles the original unknown outcome', () async {
      final name = _database();
      final fixture = await ChromeRecoveryQualification.open(database: name);
      addTearDown(fixture.close);
      await fixture.prepare();
      await fixture.dispatch(simulateCommit: kind != 'not committed');
      final pending = (await fixture.load())!;
      const store = IndexedDbJournalEngine.receiptStore;
      if (kind == 'missing') {
        await _nativeSnapshot(name, store, value: '{"revision":0,"rows":{}}');
      }
      if (kind == 'conflicting') {
        final raw = (await _nativeSnapshot(name, store))!;
        final snapshot = jsonDecode(raw) as Map<String, dynamic>;
        final rows = snapshot['rows'] as Map<String, dynamic>;
        const key = ChromeRecoveryQualification.receiptKey;
        final receipt = jsonDecode(rows[key] as String) as Map<String, dynamic>;
        (receipt['request'] as Map)['quantity'] = 3;
        rows[key] = jsonEncode(receipt);
        await _nativeSnapshot(name, store, value: jsonEncode(snapshot));
        await expectLater(
          fixture.observe(pending),
          throwsA(isA<InventoryHttpsFailure>()),
        );
      } else {
        expect((await fixture.observe(pending)).committed, false);
      }
      expect((await fixture.load())!.toJson(), pending.toJson());
      expect(fixture.mutationRequests, 1);
    });
  }

  for (final fault in [
    'UID',
    'project',
    'cafe',
    'generation',
    'stale',
    'credentials',
  ]) {
    test('$fault prevents observation and replay', () async {
      final name = _database();
      final first = await ChromeRecoveryQualification.open(database: name);
      await first.prepare();
      await first.dispatch();
      final pending = (await first.load())!;
      await first.close();
      final session = switch (fault) {
        'UID' => ChromeRecoveryQualification.syntheticSession(
          user: 'other-user',
        ),
        'project' => ChromeRecoveryQualification.syntheticSession(
          projectId: 'other-project',
        ),
        'cafe' => ChromeRecoveryQualification.syntheticSession(
          cafeId: 'other-cafe',
        ),
        'generation' => ChromeRecoveryQualification.syntheticSession(
          membershipGeneration: 8,
        ),
        _ => ChromeRecoveryQualification.syntheticSession(),
      };
      final recovered = await ChromeRecoveryQualification.open(
        database: name,
        session: session,
        token: fault == 'credentials' ? (_) async => null : null,
      );
      addTearDown(recovered.close);
      if (fault == 'stale') session.workspace.invalidate();
      await expectLater(
        recovered.observe(pending),
        throwsA(isA<InventoryHttpsFailure>()),
      );
      expect(recovered.observationRequests, 0);
      expect(recovered.mutationRequests, 0);
      expect(await recovered.dispatchCount(), 1);
    });
  }
}
