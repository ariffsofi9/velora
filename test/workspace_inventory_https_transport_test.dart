import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';
import 'package:velora/services/workspace_inventory_create_service.dart';
import 'package:velora/services/workspace_inventory_update_service.dart';
import 'package:velora/services/workspace_inventory_stock_service.dart';
import 'package:velora/services/workspace_inventory_lifecycle_service.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:velora/services/mutation_recovery_service.dart';
import 'mutation_recovery_service_test.dart'
    show FakeMutationPersistence, syntheticSha256;

class FakeClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  final requests = <http.BaseRequest>[];
  bool closed = false;
  FakeClient(this.handle);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handle(request);
  }

  @override
  void close() {
    closed = true;
  }
}

// An explicit cancellation seam: the source finishes normally; the subscription
// cancellation itself can fail or stall independently of source completion.
class CancelStream<T> extends Stream<T> {
  final Stream<T> source;
  final Future<void> Function() cancel;
  CancelStream(this.source, this.cancel);
  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => CancelSubscription(
    source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    cancel,
  );
}

class CancelSubscription<T> implements StreamSubscription<T> {
  final StreamSubscription<T> source;
  final Future<void> Function() cleanup;
  CancelSubscription(this.source, this.cleanup);
  @override
  Future<void> cancel() async {
    await source.cancel();
    await cleanup();
  }

  @override
  void onData(void Function(T)? handler) => source.onData(handler);
  @override
  void onError(Function? handler) => source.onError(handler);
  @override
  void onDone(void Function()? handler) => source.onDone(handler);
  @override
  void pause([Future<void>? resumeSignal]) => source.pause(resumeSignal);
  @override
  void resume() => source.resume();
  @override
  bool get isPaused => source.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => source.asFuture<E>(futureValue);
}

WorkspaceSession workspace({String cafe = 'cafe', int generation = 0}) =>
    WorkspaceSession.fromVerified(
      CafeWorkspace(
        cafeId: cafe,
        uid: 'owner',
        ownerUid: 'owner',
        role: CafeRole.owner,
        membershipGeneration: generation,
      ),
    );
InventoryHttpsSession snapshot(
  WorkspaceSession w, {
  String uid = 'owner',
  String project = 'velora-spark-test',
  int revision = 1,
  bool verified = true,
}) => InventoryHttpsSession(
  uid: uid,
  projectId: project,
  revision: revision,
  emailVerified: verified,
  workspace: w,
);

class Fixture {
  final changes = StreamController<InventoryHttpsSession?>.broadcast(
    sync: true,
  );
  late InventoryHttpsSession? current = snapshot(workspace());
  late FakeClient client;
  Object? body;
  int status = 200;
  String contentType = 'application/json';
  Future<String?> Function(InventoryHttpsSession)? token;
  Fixture() {
    client = FakeClient(
      (_) async => response(body, status: status, contentType: contentType),
    );
  }
  HttpsWorkspaceInventory adapter({
    Uri? endpoint,
    String project = 'velora-spark-test',
    String endpointProject = 'velora-spark-test',
    Duration timeout = const Duration(seconds: 1),
    Duration cleanup = const Duration(milliseconds: 20),
    int max = 65536,
    Stream<InventoryHttpsSession?>? stream,
    MutationRecoveryJournal? journal,
  }) => HttpsWorkspaceInventory(
    endpoint: endpoint ?? Uri.parse('https://offline.invalid'),
    projectId: project,
    endpointProjectId: endpointProject,
    client: client,
    currentSession: () => current,
    sessionChanges: stream ?? changes.stream,
    idToken: token ?? (_) async => 'fake.id.token',
    timeout: timeout,
    cleanupTimeout: cleanup,
    maxResponseBytes: max,
    journal: journal,
  );
  Future<void> close() async {
    await changes.close();
  }
}

http.StreamedResponse response(
  Object? body, {
  int status = 200,
  String contentType = 'application/json',
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: {'content-type': contentType},
);

WorkspaceInventoryCreateRequest create() => WorkspaceInventoryCreateRequest(
  idempotencyKey: 'create-request-0001',
  name: 'Rice',
  category: 'Dry',
  quantity: 5,
  unit: 'kg',
  expiryDate: DateTime(2030, 1, 2, 19),
);
WorkspaceInventoryUpdateRequest update() => WorkspaceInventoryUpdateRequest(
  idempotencyKey: 'update-request-0001',
  itemId: 'item',
  expectedVersion: 1,
  name: 'New Rice',
  category: 'Dry',
  unit: 'kg',
  expiryDate: DateTime(2030, 1, 2, 19),
  imageUrl: '',
);
WorkspaceInventoryStockRequest stock({
  StockDirection direction = StockDirection.stockOut,
}) => WorkspaceInventoryStockRequest(
  idempotencyKey: 'stock-request-0001',
  itemId: 'item',
  expectedVersion: 1,
  direction: direction,
  quantity: 2,
  reason: ' Sale ',
);
WorkspaceInventoryLifecycleRequest lifecycle({
  InventoryLifecycleAction action = InventoryLifecycleAction.archive,
}) => WorkspaceInventoryLifecycleRequest(
  idempotencyKey: 'lifecycle-request-0001',
  itemId: 'item',
  action: action,
  expectedVersion: 1,
);
// Node crypto SHA-256 of owner + NUL + cafe + NUL + create-request-0001,
// matching inventory-create.js requestHash and the create() fixture.
const canonicalItemId =
    'item_5d85a22f1ecedce5c2ad46b49cc698622214bc3e935f130ea92c44b77c684256';
Map<String, Object> acknowledgement(String operation) => switch (operation) {
  'create' => {'cafeId': 'cafe', 'itemId': canonicalItemId, 'created': true},
  'update' => {
    'cafeId': 'cafe',
    'itemId': 'item',
    'updated': true,
    'version': 2,
  },
  'adjust-stock' => {
    'cafeId': 'cafe',
    'itemId': 'item',
    'direction': 'out',
    'quantity': 2,
    'resultingQuantity': 3,
    'version': 2,
    'adjusted': true,
  },
  _ => {
    'cafeId': 'cafe',
    'itemId': 'item',
    'lifecycleState': 'archived',
    'version': 2,
    'changed': true,
  },
};
Object requestFor(String operation) => switch (operation) {
  'create' => create(),
  'update' => update(),
  'adjust-stock' => stock(),
  _ => lifecycle(),
};
Map<String, Object> payloadFor(Object request) => switch (request) {
  WorkspaceInventoryCreateRequest r => r.toCallableData(),
  WorkspaceInventoryUpdateRequest r => r.toCallableData(),
  WorkspaceInventoryStockRequest r => r.toCallableData(),
  WorkspaceInventoryLifecycleRequest r => r.toCallableData(),
  _ => throw StateError('fixture'),
};
Future<Object> invoke(HttpsWorkspaceInventory adapter, Object request) =>
    switch (request) {
      WorkspaceInventoryCreateRequest r => adapter.createItem(r),
      WorkspaceInventoryUpdateRequest r => adapter.updateItem(r),
      WorkspaceInventoryStockRequest r => adapter.adjustStock(r),
      WorkspaceInventoryLifecycleRequest r => adapter.setLifecycle(r),
      _ => throw StateError('fixture'),
    };
InventoryHttpsFailure transport(Object error) => switch (error) {
  InventoryHttpsCreateException e => e.transport,
  InventoryHttpsUpdateException e => e.transport,
  InventoryHttpsStockException e => e.transport,
  InventoryHttpsLifecycleException e => e.transport,
  _ => throw StateError('Unexpected exception type'),
};
Matcher failure({bool unknown = true, String? code}) => predicate<Object>((e) {
  final t = transport(e);
  return t.outcomeUnknown == unknown && (code == null || t.code == code);
}, 'sanitized typed transport failure');

void main() {
  test(
    'reconciliation owns one session listener and cancels a single-subscription source',
    () async {
      final f = Fixture()
        ..status = 503
        ..body = {'error': 'unavailable'};
      addTearDown(f.close);
      final storage = FakeMutationPersistence(),
          journal = MutationRecoveryJournal(storage, sha256: syntheticSha256);
      await expectLater(
        f.adapter(journal: journal).createItem(create()),
        throwsA(failure()),
      );
      final pending = (await journal.load(
        'velora-spark-test',
        'owner',
        'create',
        'create-request-0001',
      ))!;
      final events = StreamController<InventoryHttpsSession?>();
      addTearDown(events.close);
      f.status = 200;
      f.body = {'state': 'unknown'};
      expect(
        (await f
                .adapter(journal: journal, stream: events.stream)
                .reconcile(pending))
            .committed,
        false,
      );
      expect(events.hasListener, false);
      expect(f.client.requests.length, 2);
    },
  );
  for (final operation in ['create', 'update', 'adjust-stock', 'lifecycle']) {
    test(
      'explicit $operation reconciliation accepts only a validated historical result',
      () async {
        final f = Fixture()
          ..status = 503
          ..body = {'error': 'unavailable'};
        addTearDown(f.close);
        final storage = FakeMutationPersistence(),
            journal = MutationRecoveryJournal(storage, sha256: syntheticSha256);
        final adapter = f.adapter(journal: journal), r = requestFor(operation);
        await expectLater(invoke(adapter, r), throwsA(failure()));
        final pending = (await journal.load(
          'velora-spark-test',
          'owner',
          operation,
          payloadFor(r)['idempotencyKey'] as String,
        ))!;
        f.status = 200;
        f.body = {
          'state': 'committed',
          'result': {...acknowledgement(operation), 'cafeId': 'other'},
        };
        await expectLater(
          adapter.reconcile(pending),
          throwsA(isA<InventoryHttpsFailure>()),
        );
        expect(
          (await journal.load(
            'velora-spark-test',
            'owner',
            operation,
            pending.stableKey,
          ))!.unresolved,
          true,
        );
        f.body = {'state': 'committed', 'result': acknowledgement(operation)};
        expect((await adapter.reconcile(pending)).committed, true);
        expect(
          f.client.requests
              .where((r) => r.url.path != '/inventory/reconcile')
              .length,
          1,
        );
      },
    );
  }
  for (final operation in ['create', 'update', 'adjust-stock', 'lifecycle']) {
    test(
      'journal $operation persists original envelope and acknowledgement before publishing',
      () async {
        final f = Fixture()..body = acknowledgement(operation);
        addTearDown(f.close);
        final storage = FakeMutationPersistence();
        final journal = MutationRecoveryJournal(
          storage,
          sha256: syntheticSha256,
        );
        final r = requestFor(operation), payload = payloadFor(r);
        f.client = FakeClient((request) async {
          final record = storage.values.values.single as Map;
          expect(record['state'], 'dispatched');
          expect(record['request'], jsonDecode((request as http.Request).body));
          return response(acknowledgement(operation));
        });
        await invoke(f.adapter(journal: journal), r);
        final saved = await journal.load(
          'velora-spark-test',
          'owner',
          operation,
          payload['idempotencyKey'] as String,
        );
        expect(saved!.state, 'acknowledged');
        expect(saved.result, acknowledgement(operation));
        expect(f.client.requests.length, 1);
        expect(jsonEncode(storage.values).contains('fake.id.token'), false);
      },
    );
  }

  for (final phase in [1, 2, 3]) {
    test(
      'journal write failure at $phase never falls back or publishes undurable success',
      () async {
        final f = Fixture()..body = acknowledgement('create');
        addTearDown(f.close);
        final storage = FakeMutationPersistence();
        storage.beforeWrite = (write) async {
          if (write == phase) throw StateError('SECRET');
        };
        final journal = MutationRecoveryJournal(
          storage,
          sha256: syntheticSha256,
        );
        await expectLater(
          f.adapter(journal: journal).createItem(create()),
          throwsA(failure()),
        );
        expect(f.client.requests.length, phase == 3 ? 1 : 0);
        expect(f.changes.hasListener, false);
      },
    );
  }

  test(
    'storage acknowledgement lost before dispatch cannot acquire a reconstructed permit',
    () async {
      final f = Fixture()..body = acknowledgement('create');
      addTearDown(f.close);
      final storage = FakeMutationPersistence()..lostAck = true;
      final first = MutationRecoveryJournal(storage, sha256: syntheticSha256);
      await expectLater(
        f.adapter(journal: first).createItem(create()),
        throwsA(failure()),
      );
      expect(f.client.requests, isEmpty);
      storage.lostAck = false;
      final restarted = MutationRecoveryJournal(
        storage,
        sha256: syntheticSha256,
      );
      await expectLater(
        f.adapter(journal: restarted).createItem(create()),
        throwsA(failure()),
      );
      expect(f.client.requests, isEmpty);
      expect(
        (await restarted.load(
          'velora-spark-test',
          'owner',
          'create',
          'create-request-0001',
        ))!.state,
        'prepared',
      );
    },
  );

  test(
    'unknown survives restart, missing receipt and later definite rejection; only observation resolves',
    () async {
      final f = Fixture()
        ..status = 503
        ..body = {'error': 'unavailable', 'outcomeUnknown': true};
      addTearDown(f.close);
      final storage = FakeMutationPersistence(),
          first = MutationRecoveryJournal(storage, sha256: syntheticSha256);
      await expectLater(
        f.adapter(journal: first).adjustStock(stock()),
        throwsA(failure()),
      );
      final restarted = MutationRecoveryJournal(
        storage,
        sha256: syntheticSha256,
      );
      final adapter = f.adapter(journal: restarted);
      final pending = (await restarted.load(
        'velora-spark-test',
        'owner',
        'adjust-stock',
        'stock-request-0001',
      ))!;
      expect(pending.state, 'unknown');
      expect(pending.everUncertain, true);
      await expectLater(adapter.adjustStock(stock()), throwsA(failure()));
      expect(f.client.requests.length, 1);
      f.status = 200;
      f.body = {'state': 'unknown'};
      expect((await adapter.reconcile(pending)).committed, false);
      final readRequest = f.client.requests.last as http.Request;
      expect(readRequest.url.path, '/inventory/reconcile');
      expect(jsonDecode(readRequest.body), pending.observationEnvelope);
      final before = jsonEncode(storage.values);
      f.status = 403;
      f.body = {'error': 'permission-denied'};
      await expectLater(
        adapter.reconcile(pending),
        throwsA(
          isA<InventoryHttpsFailure>().having(
            (e) => e.outcomeUnknown,
            'operation uncertainty',
            true,
          ),
        ),
      );
      expect(jsonEncode(storage.values), before);
      f.status = 200;
      f.body = {
        'state': 'committed',
        'result': acknowledgement('adjust-stock'),
      };
      expect(
        (await adapter.reconcile(pending)).result!['resultingQuantity'],
        3,
      );
      expect(
        (await restarted.load(
          'velora-spark-test',
          'owner',
          'adjust-stock',
          'stock-request-0001',
        ))!.state,
        'acknowledged',
      );
      expect(
        f.client.requests
            .where((r) => r.url.path == '/inventory/adjust-stock')
            .length,
        1,
      );
      expect(f.changes.hasListener, false);
    },
  );

  for (final phase in [1, 2, 3]) {
    test(
      'session away/back during journal write $phase never publishes a late result',
      () async {
        final f = Fixture()..body = acknowledgement('create');
        addTearDown(f.close);
        final storage = FakeMutationPersistence(),
            entered = Completer<void>(),
            gate = Completer<void>();
        storage.beforeWrite = (write) async {
          if (write == phase) {
            entered.complete();
            await gate.future;
          }
        };
        final journal = MutationRecoveryJournal(
          storage,
          sha256: syntheticSha256,
        );
        final result = expectLater(
          f.adapter(journal: journal).createItem(create()),
          throwsA(failure(unknown: phase == 3, code: 'session-changed')),
        );
        await entered.future;
        f.changes.add(null);
        f.changes.add(f.current);
        gate.complete();
        await result;
        expect(f.client.requests.length, phase == 3 ? 1 : 0);
        expect(f.changes.hasListener, false);
      },
    );
  }

  test(
    'pending journal can be explicitly observed after verified session reconstruction, never replayed',
    () async {
      final f = Fixture()
        ..status = 503
        ..body = {'error': 'unavailable'};
      addTearDown(f.close);
      final storage = FakeMutationPersistence(),
          first = MutationRecoveryJournal(storage, sha256: syntheticSha256);
      await expectLater(
        f.adapter(journal: first).createItem(create()),
        throwsA(failure()),
      );
      f.current!.workspace.invalidate();
      f.current = snapshot(workspace(), revision: 2);
      final restarted = MutationRecoveryJournal(
            storage,
            sha256: syntheticSha256,
          ),
          adapter = f.adapter(journal: restarted);
      final pending = (await restarted.load(
        'velora-spark-test',
        'owner',
        'create',
        'create-request-0001',
      ))!;
      f.status = 200;
      f.body = {'state': 'committed', 'result': acknowledgement('create')};
      expect((await adapter.reconcile(pending)).committed, true);
      expect(
        f.client.requests
            .where((r) => r.url.path == '/inventory/create')
            .length,
        1,
      );
    },
  );

  for (final mismatch in [
    'uid',
    'cafe',
    'generation',
    'project',
    'unverified',
  ]) {
    test('reconciliation rejects $mismatch session before HTTP', () async {
      final f = Fixture()
        ..status = 503
        ..body = {'error': 'unavailable'};
      addTearDown(f.close);
      final storage = FakeMutationPersistence(),
          journal = MutationRecoveryJournal(storage, sha256: syntheticSha256);
      final adapter = f.adapter(journal: journal);
      await expectLater(adapter.createItem(create()), throwsA(failure()));
      final pending = (await journal.load(
        'velora-spark-test',
        'owner',
        'create',
        'create-request-0001',
      ))!;
      f.current = switch (mismatch) {
        'uid' => snapshot(workspace(), uid: 'other'),
        'cafe' => snapshot(workspace(cafe: 'other')),
        'generation' => snapshot(workspace(generation: 7)),
        'project' => snapshot(workspace(), project: 'velora-73222'),
        _ => snapshot(workspace(), verified: false),
      };
      await expectLater(
        adapter.reconcile(pending),
        throwsA(isA<InventoryHttpsFailure>()),
      );
      expect(f.client.requests.length, 1);
    });
  }

  test(
    'observation acknowledgement during session transition is retained but never published',
    () async {
      final f = Fixture()
        ..status = 503
        ..body = {'error': 'unavailable'};
      addTearDown(f.close);
      final storage = FakeMutationPersistence(),
          journal = MutationRecoveryJournal(storage, sha256: syntheticSha256);
      final adapter = f.adapter(journal: journal);
      await expectLater(adapter.createItem(create()), throwsA(failure()));
      final pending = (await journal.load(
        'velora-spark-test',
        'owner',
        'create',
        'create-request-0001',
      ))!;
      final entered = Completer<void>(), gate = Completer<void>();
      storage.beforeWrite = (_) async {
        entered.complete();
        await gate.future;
      };
      f.status = 200;
      f.body = {'state': 'committed', 'result': acknowledgement('create')};
      final result = expectLater(
        adapter.reconcile(pending),
        throwsA(
          isA<InventoryHttpsFailure>().having(
            (e) => e.code,
            'session',
            'session-changed',
          ),
        ),
      );
      await entered.future;
      f.changes.add(null);
      f.changes.add(f.current);
      gate.complete();
      await result;
      expect(f.changes.hasListener, false);
    },
  );
  for (final created in [true, false]) {
    test('canonical creation acknowledgement created=$created', () async {
      final f = Fixture()
        ..body = {...acknowledgement('create'), 'created': created};
      addTearDown(f.close);
      final result = await f.adapter().createItem(create());
      expect(result.itemId, canonicalItemId);
      expect(result.created, created);
      expect(f.client.requests.length, 1);
    });
    final invalidIds = <Object?>[
      null,
      12,
      '',
      '   ',
      '.',
      '..',
      'item',
      ' $canonicalItemId',
      '$canonicalItemId ',
      '$canonicalItemId\n',
      canonicalItemId.replaceFirst('item_', 'other_'),
      canonicalItemId.substring(0, canonicalItemId.length - 1),
      '${canonicalItemId}a',
      canonicalItemId.toUpperCase(),
      'item_${'A' * 64}',
      'item_${'g' * 64}',
      'item_${'a' * 63}/',
      'item_${'a' * 63}\u0000',
    ];
    for (var i = 0; i < invalidIds.length; i++) {
      test('invalid create ID case $i created=$created is uncertain', () async {
        final f = Fixture()
          ..body = {
            ...acknowledgement('create'),
            'itemId': invalidIds[i],
            'created': created,
          };
        addTearDown(f.close);
        await expectLater(
          f.adapter().createItem(create()),
          throwsA(failure(code: 'invalid-response')),
        );
        expect(f.client.requests.length, 1);
        expect(f.changes.hasListener, false);
      });
    }
  }
  for (final adjusted in [true, false]) {
    for (final direction in StockDirection.values) {
      final stockIn = direction == StockDirection.stockIn;
      for (final quantity in stockIn ? [2, 3, 9007199254740991] : [0, 3]) {
        test(
          '$direction result $quantity adjusted=$adjusted accepted',
          () async {
            final f = Fixture()
              ..body = {
                ...acknowledgement('adjust-stock'),
                'direction': stockIn ? 'in' : 'out',
                'resultingQuantity': quantity,
                'adjusted': adjusted,
              };
            addTearDown(f.close);
            final result = await f.adapter().adjustStock(
              stock(direction: direction),
            );
            expect(result.resultingQuantity, quantity);
            expect(result.adjusted, adjusted);
            expect(
              result.itemId,
              'item',
            ); // Existing legacy IDs remain supported.
            expect(f.client.requests.length, 1);
          },
        );
      }
    }
    for (final quantity in <Object?>[
      0,
      1,
      -1,
      1.5,
      9007199254740992,
      '2',
      null,
      true,
    ]) {
      test(
        'stock-in result $quantity adjusted=$adjusted is uncertain',
        () async {
          final f = Fixture()
            ..body = {
              ...acknowledgement('adjust-stock'),
              'direction': 'in',
              'resultingQuantity': quantity,
              'adjusted': adjusted,
            };
          addTearDown(f.close);
          await expectLater(
            f.adapter().adjustStock(stock(direction: StockDirection.stockIn)),
            throwsA(failure(code: 'invalid-response')),
          );
          expect(f.client.requests.length, 1);
          expect(f.changes.hasListener, false);
        },
      );
    }
  }
  test(
    'nonzero generation and token identity use the captured verified episode',
    () async {
      final f = Fixture()..body = acknowledgement('create');
      addTearDown(f.close);
      f.current = snapshot(workspace(generation: 7));
      final original = f.current;
      f.token = (session) async {
        expect(identical(session, original), true);
        return 'token';
      };
      await f.adapter().createItem(create());
      expect(
        jsonDecode(
          (f.client.requests.single as http.Request).body,
        )['expectedMembershipGeneration'],
        7,
      );
    },
  );
  for (final value in [-1, 1.5, '2', 9007199254740992]) {
    test('stock rejects noncanonical numeric quantity $value', () async {
      final f = Fixture()
        ..body = {...acknowledgement('adjust-stock'), 'quantity': value};
      addTearDown(f.close);
      await expectLater(
        f.adapter().adjustStock(stock()),
        throwsA(failure(code: 'invalid-response')),
      );
    });
  }
  for (final value in ['other', 'active', 12]) {
    test('archive rejects mismatched lifecycle state $value', () async {
      final f = Fixture()
        ..body = {...acknowledgement('lifecycle'), 'lifecycleState': value};
      addTearDown(f.close);
      await expectLater(
        f.adapter().setLifecycle(lifecycle()),
        throwsA(failure(code: 'invalid-response')),
      );
    });
  }
  test(
    'response advertised byte limit rejects and cancels without body completion',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      f.client = FakeClient(
        (_) async => http.StreamedResponse(
          stream.stream,
          200,
          contentLength: 65537,
          headers: {'content-type': 'application/json'},
        ),
      );
      await expectLater(
        f.adapter().createItem(create()),
        throwsA(failure(code: 'invalid-response')),
      );
      expect(cancelled, true);
      await stream.close();
    },
  );
  test(
    'definite rejection survives cleanup failure without leaking details',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final stream = CancelStream<InventoryHttpsSession?>(
        f.changes.stream,
        () async {
          throw StateError('SECRET');
        },
      );
      f.status = 403;
      f.body = {'error': 'permission-denied'};
      await expectLater(
        f.adapter(stream: stream).createItem(create()),
        throwsA(failure(unknown: false, code: 'permission-denied')),
      );
      expect(f.client.requests.length, 1);
    },
  );
  test('session provider failure during final cleanup is sanitized', () async {
    final f = Fixture()..body = acknowledgement('create');
    addTearDown(f.close);
    var broken = false;
    final events = StreamController<InventoryHttpsSession?>(
      onCancel: () {
        broken = true;
      },
    );
    final a = HttpsWorkspaceInventory(
      endpoint: Uri.parse('https://offline.invalid'),
      projectId: 'velora-spark-test',
      endpointProjectId: 'velora-spark-test',
      client: f.client,
      sessionChanges: events.stream,
      currentSession: () {
        if (broken) throw StateError('SECRET');
        return f.current;
      },
      idToken: (_) async => 'token',
    );
    await expectLater(
      a.createItem(create()),
      throwsA(failure(code: 'session-changed')),
    );
    await events.close();
  });
  for (final operation in ['create', 'update', 'adjust-stock', 'lifecycle']) {
    test(
      '$operation uses exact canonical payload and interface; manual duplicate retains key',
      () async {
        final f = Fixture()..body = acknowledgement(operation);
        addTearDown(f.close);
        final adapter = f.adapter();
        final request = requestFor(operation);
        final original = payloadFor(request);
        final result = await invoke(adapter, request);
        expect(result, switch (operation) {
          'create' => isA<WorkspaceInventoryCreateResult>(),
          'update' => isA<WorkspaceInventoryUpdateResult>(),
          'adjust-stock' => isA<WorkspaceInventoryStockResult>(),
          _ => isA<WorkspaceInventoryLifecycleResult>(),
        });
        await invoke(adapter, request);
        expect(f.client.requests.length, 2);
        for (final sent in f.client.requests.cast<http.Request>()) {
          expect(
            sent.url.toString(),
            'https://offline.invalid/inventory/$operation',
          );
          expect(sent.method, 'POST');
          expect(sent.followRedirects, false);
          expect(sent.maxRedirects, 0);
          expect(sent.headers['authorization'], 'Bearer fake.id.token');
          expect(sent.headers['content-type'], 'application/json');
          expect(jsonDecode(sent.body), {
            ...original,
            'expectedCafeId': 'cafe',
            'expectedMembershipGeneration': 0,
          });
        }
        expect(payloadFor(request), original);
        expect(f.client.closed, false);
        expect(f.changes.hasListener, false);
      },
    );
    test(
      '$operation cross-workspace acknowledgement is uncertain, no retry',
      () async {
        final f = Fixture()
          ..body = {...acknowledgement(operation), 'cafeId': 'other'};
        addTearDown(f.close);
        await expectLater(
          invoke(f.adapter(), requestFor(operation)),
          throwsA(failure(code: 'invalid-response')),
        );
        expect(f.client.requests.length, 1);
        expect(f.changes.hasListener, false);
      },
    );
    test('$operation lost response is uncertain, no retry', () async {
      final f = Fixture();
      addTearDown(f.close);
      f.client = FakeClient((_) async => throw StateError('SECRET TOKEN'));
      await expectLater(
        invoke(f.adapter(), requestFor(operation)),
        throwsA(failure(code: 'unavailable')),
      );
      expect(f.client.requests.length, 1);
    });
  }
  test(
    'UTC serialization, fingerprints and keys remain the original models',
    () {
      expect(
        create().toCallableData()['expiryDate'],
        '2030-01-02T00:00:00.000Z',
      );
      expect(
        update().toCallableData()['expiryDate'],
        '2030-01-02T00:00:00.000Z',
      );
      expect(stock().toCallableData()['reason'], 'Sale');
      expect(stock().fingerprint, stock().fingerprint);
    },
  );
  for (final entry in <String, Object>{
    'itemId': 'other',
    'version': 0,
    'updated': 'true',
    'cafeId': 12,
  }.entries) {
    test('update rejects malformed/correlated ${entry.key}', () async {
      final f = Fixture()
        ..body = {...acknowledgement('update'), entry.key: entry.value};
      addTearDown(f.close);
      await expectLater(
        f.adapter().updateItem(update()),
        throwsA(failure(code: 'invalid-response')),
      );
    });
  }
  for (final entry in <String, Object>{
    'itemId': 'other',
    'direction': 'in',
    'quantity': 3,
    'resultingQuantity': -1,
    'version': 9007199254740992,
    'adjusted': 1,
  }.entries) {
    test('stock rejects malformed/correlated ${entry.key}', () async {
      final f = Fixture()
        ..body = {...acknowledgement('adjust-stock'), entry.key: entry.value};
      addTearDown(f.close);
      await expectLater(
        f.adapter().adjustStock(stock()),
        throwsA(failure(code: 'invalid-response')),
      );
    });
  }
  for (final operation in ['create', 'lifecycle']) {
    for (final field
        in operation == 'create'
            ? ['itemId', 'created']
            : ['itemId', 'lifecycleState', 'version', 'changed']) {
      test('$operation rejects missing $field', () async {
        final body = acknowledgement(operation)..remove(field);
        final f = Fixture()..body = body;
        addTearDown(f.close);
        await expectLater(
          invoke(f.adapter(), requestFor(operation)),
          throwsA(failure(code: 'invalid-response')),
        );
      });
    }
  }
  test(
    'no-op metadata, stock replay and lifecycle replay retain canonical versions',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final a = f.adapter();
      f.body = {...acknowledgement('update'), 'updated': false, 'version': 1};
      expect((await a.updateItem(update())).updated, false);
      f.body = {...acknowledgement('adjust-stock'), 'adjusted': false};
      expect((await a.adjustStock(stock())).version, 2);
      f.body = {...acknowledgement('lifecycle'), 'changed': false};
      expect((await a.setLifecycle(lifecycle())).version, 2);
      f.body = {...acknowledgement('lifecycle'), 'lifecycleState': 'active'};
      expect(
        (await a.setLifecycle(
          lifecycle(action: InventoryLifecycleAction.restore),
        )).lifecycleState,
        'active',
      );
    },
  );
  for (final url in [
    'http://offline.invalid',
    'https://localhost',
    'https://127.0.0.1',
    'https://[::1]',
    'https://a.localhost',
    'https://user:pass@offline.invalid',
    'https://offline.invalid/path',
    'https://offline.invalid?x=1',
    'https://offline.invalid#x',
    'https://offline.invalid:8443',
  ]) {
    test('rejects unsafe endpoint $url', () async {
      final f = Fixture();
      addTearDown(f.close);
      expect(
        () => f.adapter(endpoint: Uri.parse(url)),
        throwsA(isA<InventoryHttpsFailure>()),
      );
      expect(f.client.requests, isEmpty);
    });
  }
  test(
    'configuration rejects wrong project binding and unsafe processing budgets',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      expect(
        () => f.adapter(endpointProject: 'velora-73222'),
        throwsA(isA<InventoryHttpsFailure>()),
      );
      expect(
        () => f.adapter(project: 'unknown', endpointProject: 'unknown'),
        throwsA(isA<InventoryHttpsFailure>()),
      );
      expect(
        () => f.adapter(timeout: Duration.zero),
        throwsA(isA<InventoryHttpsFailure>()),
      );
      expect(
        () => f.adapter(cleanup: Duration.zero),
        throwsA(isA<InventoryHttpsFailure>()),
      );
      expect(
        () => f.adapter(max: 65537),
        throwsA(isA<InventoryHttpsFailure>()),
      );
    },
  );
  for (final kind in [
    'missing',
    'uid',
    'project',
    'unverified',
    'invalidated',
  ]) {
    test('rejects $kind session before token/send', () async {
      final f = Fixture();
      addTearDown(f.close);
      var tokens = 0;
      f.token = (_) async {
        tokens++;
        return 'token';
      };
      final w = workspace();
      f.current = switch (kind) {
        'missing' => null,
        'uid' => snapshot(w, uid: 'staff'),
        'project' => snapshot(w, project: 'velora-73222'),
        'unverified' => snapshot(w, verified: false),
        _ => snapshot(w),
      };
      if (kind == 'invalidated') w.invalidate();
      await expectLater(
        f.adapter().createItem(create()),
        throwsA(failure(unknown: false)),
      );
      expect(tokens, 0);
      expect(f.client.requests, isEmpty);
    });
  }
  for (final token in <String?>[null, '', 'Bearer x', 'x\r\nsecret']) {
    test(
      'rejects malformed/missing token before dispatch ${token?.length}',
      () async {
        final f = Fixture();
        addTearDown(f.close);
        f.token = (_) async => token;
        await expectLater(
          f.adapter().createItem(create()),
          throwsA(failure(unknown: false, code: 'unauthenticated')),
        );
        expect(f.client.requests, isEmpty);
      },
    );
  }
  test('bounds encoded request before dispatch', () async {
    final f = Fixture();
    addTearDown(f.close);
    final r = WorkspaceInventoryCreateRequest(
      idempotencyKey: 'create-request-0001',
      name: 'a' * 4096,
      category: 'Dry',
      quantity: 1,
      unit: 'kg',
      expiryDate: DateTime(2030),
    );
    await expectLater(
      f.adapter().createItem(r),
      throwsA(failure(unknown: false, code: 'invalid-argument')),
    );
    expect(f.client.requests, isEmpty);
  });
  for (final c in [
    ('unauthenticated', 401),
    ('permission-denied', 403),
    ('aborted', 409),
    ('already-exists', 409),
    ('out-of-range', 409),
    ('not-found', 404),
  ]) {
    test('definite ${c.$1} preserves stock UI classification', () async {
      final f = Fixture()
        ..status = c.$2
        ..body = {'error': c.$1};
      addTearDown(f.close);
      final expected = switch (c.$1) {
        'unauthenticated' => WorkspaceInventoryStockFailure.unauthenticated,
        'permission-denied' => WorkspaceInventoryStockFailure.permissionDenied,
        'aborted' => WorkspaceInventoryStockFailure.stale,
        'already-exists' => WorkspaceInventoryStockFailure.conflict,
        'not-found' => WorkspaceInventoryStockFailure.notFound,
        _ => WorkspaceInventoryStockFailure.outOfRange,
      };
      await expectLater(
        f.adapter().adjustStock(stock()),
        throwsA(
          isA<InventoryHttpsStockException>()
              .having((e) => e.failure, 'UI failure', expected)
              .having((e) => e.outcomeUnknown, 'unknown', false),
        ),
      );
      expect(f.client.requests.length, 1);
    });
  }
  test(
    'allowlisted insufficient stock maps to existing reload behavior',
    () async {
      final f = Fixture()
        ..status = 409
        ..body = {
          'error': 'failed-precondition',
          'reason': 'insufficient-stock',
        };
      addTearDown(f.close);
      await expectLater(
        f.adapter().adjustStock(stock()),
        throwsA(
          isA<InventoryHttpsStockException>()
              .having(
                (e) => e.failure,
                'failure',
                WorkspaceInventoryStockFailure.insufficientStock,
              )
              .having((e) => e.outcomeUnknown, 'unknown', false),
        ),
      );
    },
  );
  for (final entry in [
    ({'error': 'failed-precondition', 'reason': 'SECRET'}, 409),
    ({'error': 'permission-denied', 'details': 'SECRET'}, 403),
    ({'error': 'unauthenticated'}, 403),
    ({'error': 'unavailable', 'outcomeUnknown': true}, 503),
    ({'error': 'unavailable'}, 500),
    ({'error': 'failed-precondition', 'outcomeUnknown': true}, 409),
  ]) {
    test('unexpected/error response ${entry.$1} remains uncertain', () async {
      final f = Fixture()
        ..status = entry.$2
        ..body = entry.$1;
      addTearDown(f.close);
      await expectLater(f.adapter().adjustStock(stock()), throwsA(failure()));
      expect(f.client.requests.length, 1);
    });
  }
  for (final status in [301, 302, 307, 308]) {
    test('redirect $status rejected with one dispatch', () async {
      final f = Fixture()
        ..status = status
        ..body = acknowledgement('create');
      addTearDown(f.close);
      await expectLater(
        f.adapter().createItem(create()),
        throwsA(failure(code: 'redirect-rejected')),
      );
      expect(f.client.requests.length, 1);
    });
  }
  for (final kind in [
    'json',
    'utf8',
    'array',
    'content-type',
    'oversize',
    'stream-error',
    'status201',
  ]) {
    test('invalid response $kind rejected and listener cleaned', () async {
      final f = Fixture();
      addTearDown(f.close);
      f.client = FakeClient((_) async {
        if (kind == 'stream-error') {
          return http.StreamedResponse(
            Stream.error(StateError('SECRET')),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final bytes = switch (kind) {
          'json' => utf8.encode('{'),
          'utf8' => [255],
          'oversize' => List.filled(65537, 32),
          'array' => utf8.encode('[]'),
          _ => utf8.encode(jsonEncode(acknowledgement('create'))),
        };
        return http.StreamedResponse(
          Stream.value(bytes),
          kind == 'status201' ? 201 : 200,
          headers: {
            'content-type': kind == 'content-type'
                ? 'text/html'
                : 'application/json',
          },
        );
      });
      await expectLater(f.adapter().createItem(create()), throwsA(failure()));
      expect(f.changes.hasListener, false);
      expect(f.client.requests.length, 1);
    });
  }
  for (final phase in ['token', 'response']) {
    for (final transition in [
      'away-back',
      'workspace',
      'invalidate',
      'stream-error',
      'stream-done',
    ]) {
      test(
        '$phase rejects $transition, including late same-identity result',
        () async {
          final f = Fixture();
          addTearDown(f.close);
          final entered = Completer<void>();
          final gate = Completer<void>();
          final original = f.current!;
          if (phase == 'token') {
            f.token = (_) async {
              entered.complete();
              await gate.future;
              return 'token';
            };
          } else {
            f.client = FakeClient((_) async {
              entered.complete();
              await gate.future;
              return response(acknowledgement('create'));
            });
          }
          final result = f.adapter().createItem(create());
          final assertion = expectLater(
            result,
            throwsA(
              failure(unknown: phase == 'response', code: 'session-changed'),
            ),
          );
          await entered.future;
          switch (transition) {
            case 'away-back':
              f.changes.add(null);
              f.changes.add(original);
              break;
            case 'workspace':
              f.current = snapshot(workspace(cafe: 'other'), revision: 2);
              break;
            case 'invalidate':
              original.workspace.invalidate();
              break;
            case 'stream-error':
              f.changes.addError(StateError('SECRET'));
              break;
            case 'stream-done':
              await f.changes.close();
              break;
          }
          gate.complete();
          await assertion;
          expect(f.client.requests.length, phase == 'response' ? 1 : 0);
          expect(f.changes.hasListener, false);
        },
      );
    }
  }
  test('same request cannot adopt a reconstructed session revision', () async {
    final f = Fixture()..body = acknowledgement('create');
    addTearDown(f.close);
    final r = create();
    await f.adapter().createItem(r);
    f.current = snapshot(f.current!.workspace, revision: 2);
    await expectLater(
      f.adapter().createItem(r),
      throwsA(failure(unknown: false, code: 'session-changed')),
    );
    expect(f.client.requests.length, 1);
  });
  for (final phase in ['token', 'send', 'body']) {
    test(
      '$phase timeout bounds completion and ignores late continuation',
      () async {
        final f = Fixture();
        addTearDown(f.close);
        final gate = Completer<void>();
        var bodyCancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            bodyCancelled = true;
          },
        );
        if (phase == 'token') {
          f.token = (_) async {
            await gate.future;
            return 'token';
          };
        }
        if (phase == 'send') {
          f.client = FakeClient((_) async {
            await gate.future;
            return response(acknowledgement('create'));
          });
        }
        if (phase == 'body') {
          f.client = FakeClient(
            (_) async => http.StreamedResponse(
              body.stream,
              200,
              headers: {'content-type': 'application/json'},
            ),
          );
        }
        await expectLater(
          f
              .adapter(timeout: const Duration(milliseconds: 15))
              .createItem(create()),
          throwsA(
            failure(unknown: phase != 'token', code: 'deadline-exceeded'),
          ),
        );
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(f.client.requests.length, phase == 'token' ? 0 : 1);
        expect(f.changes.hasListener, false);
        if (phase == 'body') expect(bodyCancelled, true);
        if (phase == 'body') {
          await body.close();
        }
      },
    );
  }
  for (final stalled in [false, true]) {
    test(
      'cleanup ${stalled ? 'stall' : 'error'} rejects success; both cancellations start',
      () async {
        final f = Fixture();
        addTearDown(f.close);
        var authCancelled = false, bodyCancelled = false;
        final release = Completer<void>();
        final events = StreamController<InventoryHttpsSession?>(
          onCancel: () {
            authCancelled = true;
          },
        );
        final bytes = CancelStream<List<int>>(
          Stream.value(utf8.encode(jsonEncode(acknowledgement('create')))),
          () {
            bodyCancelled = true;
            return stalled
                ? release.future
                : Future<void>.error(StateError('SECRET'));
          },
        );
        f.client = FakeClient((_) async {
          return http.StreamedResponse(
            bytes,
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        await expectLater(
          f.adapter(stream: events.stream).createItem(create()),
          throwsA(failure(code: 'cleanup-failed')),
        );
        expect(authCancelled, true);
        expect(bodyCancelled, true);
        expect(f.client.requests.length, 1);
        if (stalled) release.complete();
        await events.close();
      },
    );
  }
  test(
    'session invalidation during cleanup prevents publishing success',
    () async {
      final f = Fixture()..body = acknowledgement('create');
      addTearDown(f.close);
      final events = StreamController<InventoryHttpsSession?>(
        onCancel: () {
          f.current!.workspace.invalidate();
        },
      );
      await expectLater(
        f.adapter(stream: events.stream).createItem(create()),
        throwsA(failure(code: 'session-changed')),
      );
      await events.close();
    },
  );
}
