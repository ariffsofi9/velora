import 'dart:async';
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

void main() {
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
