import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:velora/services/workspace_session_monitor.dart';
import 'package:velora/services/workspace_inventory_stock_service.dart';
import 'package:velora/services/workspace_inventory_lifecycle_service.dart';
import 'package:velora/screens/auth/workspace_session_boundary.dart';
import 'package:velora/screens/auth/workspace_gate.dart';

CafeWorkspace workspace({int generation = 2, String cafe = 'a'}) =>
    CafeWorkspace(
      cafeId: cafe,
      uid: 'staff',
      ownerUid: 'owner',
      role: CafeRole.staff,
      membershipGeneration: generation,
    );

class Transport implements WorkspaceInventoryStockCallable {
  final payloads = <Map<String, Object>>[];
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    payloads.add(Map.of(data));
    return pending == null ? result : pending!.future;
  }

  final result = <String, dynamic>{
    'itemId': 'item',
    'direction': 'in',
    'quantity': 1,
    'resultingQuantity': 2,
    'version': 2,
    'adjusted': true,
  };
}

WorkspaceInventoryStockRequest newRequest() => WorkspaceInventoryStockRequest(
  idempotencyKey: 'stable-request-01',
  itemId: 'item',
  direction: StockDirection.stockIn,
  quantity: 1,
  expectedVersion: 1,
);

class AuthorityMetadata extends Fake implements SnapshotMetadata {
  @override
  final bool isFromCache;
  @override
  final bool hasPendingWrites;
  AuthorityMetadata(this.isFromCache, this.hasPendingWrites);
}

class AuthorityDocument extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  final Map<String, dynamic>? value;
  @override
  final SnapshotMetadata metadata;
  AuthorityDocument(this.value, {bool cache = false, bool pending = false})
    : metadata = AuthorityMetadata(cache, pending);
  @override
  Map<String, dynamic>? data() => value;
}

/// SDK-shaped snapshots enter the production aggregator, never Stream<bool>.
class AuthorityHarness {
  final CafeWorkspace scope;
  late final session = WorkspaceSession.fromVerified(scope);
  final identities = StreamController<String?>.broadcast();
  final sources =
      <String, StreamController<DocumentSnapshot<Map<String, dynamic>>>>{};
  final cancellations = <String>[];
  final requests = <String>[];
  int resolutions = 0;
  Completer<CafeWorkspace>? pendingResolution;
  bool denyResolution = false;
  AuthorityHarness({CafeWorkspace? scope}) : scope = scope ?? workspace();

  Map<String, Map<String, dynamic>> get documents => {
    'user_cafe_memberships/${scope.uid}': link(scope.uid),
    'cafes/${scope.cafeId}/members/${scope.uid}': {
      ...link(scope.uid),
      'role': scope.role.name,
    },
    'cafes/${scope.cafeId}': {
      'ownerUid': scope.ownerUid,
      'status': 'active',
      'schemaVersion': 1,
    },
    'user_cafe_memberships/${scope.ownerUid}': link(scope.ownerUid),
    'cafes/${scope.cafeId}/members/${scope.ownerUid}': {
      ...link(scope.ownerUid),
      'role': 'owner',
    },
  };

  Map<String, dynamic> link(String uid) => {
    'uid': uid,
    'cafeId': scope.cafeId,
    'status': 'active',
    'schemaVersion': 1,
    'membershipGeneration': scope.membershipGeneration,
  };

  Stream<DocumentSnapshot<Map<String, dynamic>>> subscribe(String path) {
    requests.add(path);
    return (sources[path] =
            StreamController<DocumentSnapshot<Map<String, dynamic>>>.broadcast(
              onCancel: () {
                cancellations.add(path);
              },
            ))
        .stream;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WorkspaceSessionBoundary(
          session: session,
          identities: identities.stream,
          authoritySnapshots: subscribe,
          resolve: () async {
            resolutions++;
            if (denyResolution) throw StateError('Inconsistent authority');
            return pendingResolution == null
                ? scope
                : await pendingResolution!.future;
          },
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: Text('Protected detail')),
                  ),
                ),
                child: const Text('Snapshot workspace'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void emit(
    String path, {
    bool cache = false,
    bool pending = false,
    Map<String, dynamic>? data,
    bool missing = false,
  }) {
    sources[path]!.add(
      AuthorityDocument(
        missing ? null : data ?? documents[path],
        cache: cache,
        pending: pending,
      ),
    );
  }

  void emitAll({bool cache = false, bool pending = false}) {
    for (final path in documents.keys) {
      emit(path, cache: cache, pending: pending);
    }
  }

  Future<void> close(WidgetTester tester) async {
    if (!session.isActive) {
      // Revocation must release listeners before widget disposal can mask leaks.
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(cancellations, unorderedEquals(documents.keys));
      expect(identities.hasListener, false);
    }
    await tester.pumpWidget(const SizedBox());
    // SDK stream cancellation futures can complete outside the widget clock.
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(cancellations, unorderedEquals(documents.keys));
    expect(identities.hasListener, false);
    final closed = Future.wait([
      for (final source in sources.values) source.close(),
      identities.close(),
    ]);
    await tester.pump();
    await closed;
  }
}

void main() {
  for (final owner in [false, true]) {
    testWidgets(
      'snapshot aggregation waits for every document (owner $owner)',
      (tester) async {
        final h = AuthorityHarness(
          scope: owner
              ? const CafeWorkspace(
                  cafeId: 'a',
                  uid: 'owner',
                  ownerUid: 'owner',
                  role: CafeRole.owner,
                  membershipGeneration: 2,
                )
              : null,
        );
        await h.mount(tester);
        expect(h.requests, unorderedEquals(h.documents.keys));
        expect(h.requests.length, owner ? 3 : 5);
        final paths = h.documents.keys.toList();
        for (final path in paths.take(paths.length - 1)) {
          h.emit(path);
        }
        await tester.pump();
        expect(find.text('Snapshot workspace'), findsNothing);
        expect(h.resolutions, 0);
        h.emit(paths.last);
        await tester.pumpAndSettle();
        expect(find.text('Snapshot workspace'), findsOneWidget);
        expect(h.resolutions, 1);
        h.emitAll();
        await tester.pump();
        expect(h.resolutions, 1);
        await h.close(tester);
      },
    );
  }

  for (final pending in [false, true]) {
    testWidgets(
      'initial ${pending ? 'pending-write' : 'cache'} snapshots cannot authorize',
      (tester) async {
        final h = AuthorityHarness();
        await h.mount(tester);
        h.emitAll(cache: !pending, pending: pending);
        await tester.pump();
        expect(h.resolutions, 0);
        expect(find.text('Snapshot workspace'), findsNothing);
        final paths = h.documents.keys.toList();
        for (final path in paths.take(paths.length - 1)) {
          h.emit(path);
        }
        await tester.pump();
        expect(h.resolutions, 0);
        h.emit(paths.last);
        await tester.pumpAndSettle();
        expect(find.text('Snapshot workspace'), findsOneWidget);
        await h.close(tester);
      },
    );
  }

  for (final change in [
    'cache',
    'pending',
    'caller-inactive',
    'owner-inactive',
    'caller-generation',
    'owner-generation',
    'cafe-owner',
    'missing',
    'error',
  ]) {
    testWidgets('production snapshots invalidate and clear routes: $change', (
      tester,
    ) async {
      final h = AuthorityHarness();
      await h.mount(tester);
      h.emitAll();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Snapshot workspace'));
      await tester.pumpAndSettle();
      expect(find.text('Protected detail'), findsOneWidget);
      final path = change.startsWith('owner')
          ? 'cafes/a/members/owner'
          : change == 'cafe-owner'
          ? 'cafes/a'
          : 'cafes/a/members/staff';
      if (change == 'error') {
        h.sources[path]!.addError(StateError('offline listener'));
      } else {
        final data = Map<String, dynamic>.of(h.documents[path]!);
        if (change.endsWith('inactive')) data['status'] = 'inactive';
        if (change.endsWith('generation')) data['membershipGeneration'] = 4;
        if (change == 'cafe-owner') data['ownerUid'] = 'other';
        h.emit(
          path,
          cache: change == 'cache',
          pending: change == 'pending',
          missing: change == 'missing',
          data: data,
        );
      }
      // Queue valid late snapshots before cancellation has completed.
      h.emitAll();
      await tester.pumpAndSettle();
      expect(h.session.isActive, false);
      expect(find.text('Protected detail'), findsNothing);
      expect(find.text('Snapshot workspace'), findsNothing);
      expect(find.byType(WorkspaceGate), findsOneWidget);
      expect(h.resolutions, 1);
      await h.close(tester);
    });
  }

  testWidgets('initial listener error fails closed and cancels every source', (
    tester,
  ) async {
    final h = AuthorityHarness();
    await h.mount(tester);
    h.sources.values.first.addError(StateError('listener failure'));
    h.emitAll();
    await tester.pumpAndSettle();
    expect(h.session.isActive, false);
    expect(find.text('Snapshot workspace'), findsNothing);
    expect(find.byType(WorkspaceGate), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('snapshot readiness still requires canonical resolver approval', (
    tester,
  ) async {
    final h = AuthorityHarness()..denyResolution = true;
    await h.mount(tester);
    h.emitAll();
    await tester.pumpAndSettle();
    expect(h.resolutions, 1);
    expect(h.session.isActive, false);
    expect(find.text('Snapshot workspace'), findsNothing);
    await h.close(tester);
  });

  testWidgets(
    'late resolver completion after snapshot revocation cannot restore session',
    (tester) async {
      final h = AuthorityHarness()
        ..pendingResolution = Completer<CafeWorkspace>();
      await h.mount(tester);
      h.emitAll();
      await tester.pump();
      expect(h.resolutions, 1);
      h.emit('cafes/a/members/staff', missing: true);
      await tester.pump();
      h.pendingResolution!.complete(h.scope);
      await tester.pumpAndSettle();
      expect(h.session.isActive, false);
      expect(find.text('Snapshot workspace'), findsNothing);
      await h.close(tester);
    },
  );

  testWidgets(
    'initial snapshot timeout fails closed and cleans subscriptions',
    (tester) async {
      final h = AuthorityHarness();
      await h.mount(tester);
      h.emit(h.documents.keys.first);
      await tester.pump(const Duration(seconds: 14));
      expect(h.session.isActive, true);
      expect(find.text('Snapshot workspace'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(h.session.isActive, false);
      expect(find.byType(WorkspaceGate), findsOneWidget);
      expect(h.resolutions, 0);
      await h.close(tester);
      await tester.pump(const Duration(seconds: 20));
    },
  );

  for (final ready in [false, true]) {
    testWidgets('disposal cancels all snapshot subscriptions (ready $ready)', (
      tester,
    ) async {
      final h = AuthorityHarness();
      await h.mount(tester);
      if (ready) {
        h.emitAll();
        await tester.pumpAndSettle();
      }
      await h.close(tester);
      expect(h.session.isActive, false);
      await tester.pump(const Duration(seconds: 20));
    });
  }

  test(
    'stock payload preserves original episode and key through unchanged retry',
    () async {
      final request = newRequest();
      final session = WorkspaceSession.fromVerified(workspace());
      final transport = Transport();
      final adapter = FirebaseWorkspaceInventoryStockAdjuster(
        session: session,
        callable: transport,
      );
      await adapter.adjustStock(request);
      await adapter.adjustStock(request);
      expect(transport.payloads[0], transport.payloads[1]);
      expect(transport.payloads.singleOrNull, isNull);
      expect(transport.payloads.first['expectedMembershipGeneration'], 2);
      expect(transport.payloads.first['expectedCafeId'], 'a');
      session.invalidate();
      final newSession = WorkspaceSession.fromVerified(
        workspace(generation: 4, cafe: 'b'),
      );
      expect(newSession.mutationData['expectedMembershipGeneration'], 4);
      await expectLater(
        FirebaseWorkspaceInventoryStockAdjuster(
          session: newSession,
          callable: transport,
        ).adjustStock(request),
        throwsA(isA<WorkspaceInventoryStockException>()),
      );
      await expectLater(
        adapter.adjustStock(request),
        throwsA(isA<WorkspaceInventoryStockException>()),
      );
      expect(transport.payloads.length, 2);
    },
  );
  test('late stock response cannot escape an invalidated session', () async {
    final request = newRequest();
    final session = WorkspaceSession.fromVerified(workspace());
    final transport = Transport()..pending = Completer();
    final adapter = FirebaseWorkspaceInventoryStockAdjuster(
      session: session,
      callable: transport,
    );
    final pending = adapter.adjustStock(request);
    final expectation = expectLater(
      pending,
      throwsA(isA<WorkspaceInventoryStockException>()),
    );
    session.invalidate();
    transport.pending!.complete(transport.result);
    await expectation;
  });
  test('missing session cannot dispatch a protected stock mutation', () async {
    final request = newRequest();
    final transport = Transport();
    await expectLater(
      FirebaseWorkspaceInventoryStockAdjuster(
        callable: transport,
      ).adjustStock(request),
      throwsA(isA<WorkspaceInventoryStockException>()),
    );
    expect(transport.payloads, isEmpty);
  });
  for (final action in InventoryLifecycleAction.values) {
    test('lifecycle ${action.name} sends the captured generation', () async {
      final session = WorkspaceSession.fromVerified(workspace());
      Map<String, Object>? payload;
      final adapter = FirebaseWorkspaceInventoryLifecycleManager(
        session: session,
        invoke: (data) async {
          payload = data;
          return {
            'itemId': 'item',
            'lifecycleState': action == InventoryLifecycleAction.archive
                ? 'archived'
                : 'active',
            'version': 2,
            'changed': true,
          };
        },
      );
      await adapter.setLifecycle(
        WorkspaceInventoryLifecycleRequest(
          idempotencyKey: 'lifecycle-key-01',
          itemId: 'item',
          action: action,
          expectedVersion: 1,
        ),
      );
      expect(payload!['expectedCafeId'], 'a');
      expect(payload!['expectedMembershipGeneration'], 2);
    });
  }
  for (final cause in [
    'logout',
    'switch',
    'generation',
    'workspace',
    'unavailable',
    'removed',
  ]) {
    test(
      'monitor invalidates old state on $cause and never adopts a rejoin',
      () async {
        final session = WorkspaceSession.fromVerified(workspace());
        final ids = StreamController<String?>.broadcast(sync: true);
        final authority = StreamController<bool>.broadcast(sync: true);
        final states = <bool>[];
        var current = workspace();
        var unavailable = false;
        final monitor = WorkspaceSessionMonitor(
          session: session,
          onState: states.add,
          resolve: () async {
            if (unavailable) throw StateError('offline');
            return current;
          },
        );
        monitor.start(ids.stream, authority.stream);
        authority.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(states, [true]);
        if (cause == 'logout') ids.add(null);
        if (cause == 'switch') ids.add('other');
        if (cause == 'removed') authority.add(false);
        if (cause == 'generation') current = workspace(generation: 4);
        if (cause == 'workspace') current = workspace(cafe: 'b');
        if (cause == 'unavailable') unavailable = true;
        if (['generation', 'workspace', 'unavailable'].contains(cause)) {
          authority.add(true);
        }
        await Future<void>.delayed(Duration.zero);
        expect(session.isActive, false);
        expect(states.last, false);
        current = workspace(generation: 6);
        authority.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(states.where((state) => state).length, 1);
        monitor.dispose();
        await ids.close();
        await authority.close();
      },
    );
  }
  test('pending verification cannot publish ready after logout', () async {
    final session = WorkspaceSession.fromVerified(workspace());
    final pending = Completer<CafeWorkspace>();
    final states = <bool>[];
    final monitor = WorkspaceSessionMonitor(
      session: session,
      resolve: () => pending.future,
      onState: states.add,
    );
    final verification = monitor.verify();
    monitor.invalidate();
    pending.complete(workspace());
    await verification;
    expect(states, [false]);
  });
  testWidgets(
    'boundary waits for verification and removes pushed routes on revocation',
    (tester) async {
      final ids = StreamController<String?>.broadcast();
      final authority = StreamController<bool>.broadcast();
      final session = WorkspaceSession.fromVerified(workspace());
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceSessionBoundary(
            session: session,
            identities: ids.stream,
            authority: authority.stream,
            resolve: () async => workspace(),
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const Scaffold(body: Text('Old detail')),
                      ),
                    );
                  },
                  child: const Text('Workspace data'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Workspace data'), findsNothing);
      authority.add(true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace data'));
      await tester.pumpAndSettle();
      expect(find.text('Old detail'), findsOneWidget);
      authority.add(false);
      await tester.pumpAndSettle();
      expect(find.text('Old detail'), findsNothing);
      expect(find.text('Workspace data'), findsNothing);
      expect(find.byType(WorkspaceGate), findsOneWidget);
      expect(session.isActive, false);
      await tester.pumpWidget(const SizedBox());
      await ids.close();
      await authority.close();
    },
  );
}
