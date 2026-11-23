import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/models/inventory_movement.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/workspace_activity.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/repositories/workspace_inventory_movement_repository.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_lifecycle_action.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';
import 'package:velora/services/workspace_inventory_lifecycle_service.dart';
import 'package:velora/services/workspace_session.dart';

import 'inventory_movement_history_test.dart' show movement;
import 'platform_journal_store_test.dart' as journal;
import 'workspace_inventory_https_transport_test.dart' as transport;

Map<String, dynamic> data({String? lifecycle}) {
  final result = <String, dynamic>{
    'name': 'Milk',
    'category': 'Dairy',
    'quantity': 4,
    'unit': 'L',
    'expiryDate': DateTime.utc(2030, 1, 1),
    'imageUrl': '',
    'createdAt': DateTime.utc(2026, 1, 1),
    'version': 2,
  };
  if (lifecycle != null) result['lifecycleState'] = lifecycle;
  if (lifecycle == 'archived') {
    result['archivedAt'] = DateTime.utc(2026, 2, 1);
    result['archivedBy'] = 'staff-a';
  }
  return result;
}

class Source implements WorkspaceInventoryDataSource {
  final List<WorkspaceInventoryDocument> documents;
  Source(this.documents);
  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async =>
      documents;
  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) =>
      Stream.value(documents);
}

class Manager implements WorkspaceInventoryLifecycleManager {
  final Completer<WorkspaceInventoryLifecycleResult>? completer;
  final List<WorkspaceInventoryLifecycleRequest> requests = [];
  Manager({this.completer});
  @override
  Future<WorkspaceInventoryLifecycleResult> setLifecycle(
    WorkspaceInventoryLifecycleRequest request,
  ) {
    requests.add(request);
    return completer?.future ??
        Future.value(
          WorkspaceInventoryLifecycleResult(
            itemId: request.itemId,
            lifecycleState: request.action == InventoryLifecycleAction.archive
                ? 'archived'
                : 'active',
            version: request.expectedVersion + 1,
            changed: true,
          ),
        );
  }
}

final session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    uid: 'staff-a',
    cafeId: 'cafe-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

AndroidPilotPolicy _pilotPolicy(bool invalid) => AndroidPilotPolicy.parse(
  invalid
      ? {'VELORA_ANDROID_READ_ONLY_PILOT': 'false'}
      : {
          'VELORA_ANDROID_READ_ONLY_PILOT': 'true',
          'VELORA_FIREBASE_PROJECT': AndroidPilotPolicy.approvedProject,
          'VELORA_ANDROID_PILOT_BINDINGS': '[["owner","cafe"]]',
        },
  isWeb: false,
  platform: TargetPlatform.android,
);
final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

Future<void> confirmLifecycle(WidgetTester tester, String buttonKey) async {
  await tester.tap(find.byKey(ValueKey(buttonKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('lifecycle-confirm')));
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _settleMutation(WidgetTester tester) async {
  // Allow stream cleanup before advancing the fake animation clock.
  for (var turn = 0; turn < 3; turn++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pumpAndSettle();
}

class _LifecycleHistory implements WorkspaceInventoryMovementReader {
  final calls = <String>[];

  @override
  Future<WorkspaceMovementPage> getItemMovements(
    String itemId, {
    WorkspaceMovementCursor? cursor,
  }) async {
    calls.add(itemId);
    return WorkspaceMovementPage(
      movements: [movement('original', InventoryMovementType.initialStock)],
    );
  }
}

Future<void> pumpLifecycle(
  WidgetTester tester, {
  required bool archived,
  required WorkspaceSession workspace,
  required VoidCallback onChanged,
  VoidCallback? onReload,
  WorkspaceInventoryLifecycleManager? manager,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: InventoryLifecycleActionButton(
        item: InventoryItem.fromMap(
          'item-a',
          data(lifecycle: archived ? 'archived' : null),
        ),
        workspaceSession: workspace,
        manager: manager,
        onChanged: onChanged,
        onReload: onReload,
      ),
    ),
  ),
);

HttpsWorkspaceInventory httpsManager({
  required WorkspaceSession workspace,
  required http.Client client,
  required Future<String?> Function(InventoryHttpsSession) idToken,
}) {
  const projectId = 'velora-spark-test';
  final changes = StreamController<InventoryHttpsSession?>.broadcast(
    sync: true,
  );
  addTearDown(changes.close);
  final snapshot = InventoryHttpsSession(
    uid: workspace.uid,
    projectId: projectId,
    revision: 1,
    emailVerified: true,
    workspace: workspace,
  );
  return HttpsWorkspaceInventory(
    pilotPolicy: _normalPolicy,
    endpoint: Uri.https('inventory.offline.invalid'),
    projectId: projectId,
    endpointProjectId: projectId,
    client: client,
    currentSession: () => snapshot,
    sessionChanges: changes.stream,
    idToken: idToken,
  );
}

void main() {
  for (final lost in [false, true]) {
    testWidgets(
      'REAL guarded Archive and Restore preserve history, lost=$lost',
      (tester) async {
        const project = HttpsWorkspaceInventory.realProject;
        const itemId = 'item-a';
        final history = _LifecycleHistory();
        final source = Source([
          WorkspaceInventoryDocument(id: itemId, data: data()),
        ]);
        final fixture = transport.Fixture();
        addTearDown(fixture.close);
        final engine = journal.FakeTransactionalJournalEngine();
        final store = journal.store(engine);
        final writes = <Map<String, dynamic>>[];
        Map<String, Object> result = {};
        void publish() {
          source.documents[0] = WorkspaceInventoryDocument(
            id: itemId,
            data: {
              ...data(lifecycle: result['lifecycleState'] as String),
              'version': result['version'],
            },
          );
        }

        fixture.client = transport.FakeClient((sent) async {
          final payload =
              jsonDecode((sent as http.Request).body) as Map<String, dynamic>;
          if (sent.url.path == '/inventory/reconcile') {
            expect(payload, {'operation': 'lifecycle', 'request': writes.last});
            publish();
            return transport.response({'state': 'committed', 'result': result});
          }
          expect(sent.url.path, '/inventory/lifecycle');
          final archive = writes.isEmpty;
          expect(payload, {
            'idempotencyKey': payload['idempotencyKey'],
            'itemId': itemId,
            'action': archive ? 'archive' : 'restore',
            'expectedVersion': archive ? 2 : 3,
            'expectedCafeId': 'cafe-a',
            'expectedMembershipGeneration': 3,
          });
          final key = jsonEncode([
            project,
            'staff',
            'lifecycle',
            payload['idempotencyKey'],
          ]);
          expect(
            (await store.mutations.read(key) as Map)['state'],
            'dispatched',
          );
          writes.add(payload);
          result = {
            'cafeId': 'cafe-a',
            'itemId': itemId,
            'lifecycleState': archive ? 'archived' : 'active',
            'version': archive ? 3 : 4,
            'changed': true,
          };
          if (lost) throw http.ClientException('synthetic lost response');
          publish();
          return transport.response(result);
        });

        var revision = 0;
        Future<void> openInventory() async {
          final workspace = transport.workspace(
            cafe: 'cafe-a',
            uid: 'staff',
            generation: 3,
          );
          fixture.current = transport.snapshot(
            workspace,
            uid: 'staff',
            project: project,
            revision: ++revision,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: InventoryPage(
                workspaceSession: workspace,
                repository: WorkspaceInventoryRepository(
                  session: workspace,
                  dataSource: source,
                ),
                lifecycleManager: fixture.realAdapter(journal.store(engine)),
                movementReader: history,
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<void> checkHistory() async {
          await tester.tap(find.byTooltip('Stock history for Milk'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('movement-original')),
            findsOneWidget,
          );
          await tester.pageBack();
          await tester.pumpAndSettle();
        }

        Future<void> act(bool archive) async {
          await tester.tap(
            archive
                ? find.text('Milk')
                : find.byKey(const ValueKey('archived-item-a')),
          );
          await tester.pumpAndSettle();
          final action = find.byKey(
            ValueKey(archive ? 'archive-item' : 'restore-item'),
          );
          await tester.scrollUntilVisible(action, 160);
          await tester.tap(action);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('lifecycle-confirm')));
          await _settleMutation(tester);
        }

        Future<void> openArchived() async {
          await tester.tap(find.byTooltip('Archived Items'));
          await tester.pumpAndSettle();
        }

        Future<void> recover(bool archive) async {
          expect(find.textContaining('Confirmation pending'), findsOneWidget);
          fixture.current!.workspace.invalidate();
          await tester.pumpWidget(const SizedBox.shrink());
          await openInventory();
          if (!archive) await openArchived();
          final before = fixture.client.requests.length;
          await act(archive);
          expect(find.textContaining('Confirmation pending'), findsOneWidget);
          expect(fixture.client.requests, hasLength(before));
          await tester.pageBack();
          await tester.pumpAndSettle();
          if (!archive) {
            await tester.pageBack();
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byTooltip('Inventory recovery'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Check outcome'));
          await _settleMutation(tester);
          expect(
            find.text('The original inventory change was confirmed.'),
            findsOneWidget,
          );
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
        }

        await openInventory();
        await checkHistory();
        await act(true);
        if (lost) {
          await recover(true);
        } else {
          expect(find.text('Item archived.'), findsOneWidget);
          tester
              .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
              .clearSnackBars();
          await tester.pumpAndSettle();
        }
        expect(find.byTooltip('Stock history for Milk'), findsNothing);
        await openArchived();
        expect(find.byKey(const ValueKey('archived-item-a')), findsOneWidget);
        await checkHistory();
        await act(false);
        if (lost) {
          await recover(false);
        } else {
          expect(find.byKey(const ValueKey('archived-empty')), findsOneWidget);
          await tester.pageBack();
          await tester.pumpAndSettle();
        }
        await checkHistory();
        await openArchived();
        expect(find.byKey(const ValueKey('archived-empty')), findsOneWidget);
        expect(history.calls, [itemId, itemId, itemId]);
        expect(source.documents.single.id, itemId);
        expect(source.documents.single.data['quantity'], 4);
        expect(writes, hasLength(2));
        expect(
          writes.first['idempotencyKey'],
          isNot(writes.last['idempotencyKey']),
        );
        expect(fixture.client.requests.map((request) => request.url.path), [
          '/inventory/lifecycle',
          if (lost) '/inventory/reconcile',
          '/inventory/lifecycle',
          if (lost) '/inventory/reconcile',
        ]);
      },
    );
  }

  for (final archived in [false, true]) {
    testWidgets(
      'lifecycle archived=$archived is unavailable without an explicit manager',
      (tester) async {
        var changed = 0;
        await pumpLifecycle(
          tester,
          archived: archived,
          workspace: session,
          onChanged: () => changed++,
        );
        expect(
          find.text('Secure inventory updates are unavailable.'),
          findsOneWidget,
        );
        expect(find.byType(OutlinedButton), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(changed, 0);
      },
    );
  }

  for (final role in CafeRole.values) {
    final archived = role == CafeRole.staff;
    final action = archived
        ? InventoryLifecycleAction.restore
        : InventoryLifecycleAction.archive;
    test('${role.name} can dispatch ${action.name} using HTTPS', () async {
      final workspace = WorkspaceSession.fromVerified(
        CafeWorkspace(
          uid: role == CafeRole.owner ? 'owner-a' : 'staff-a',
          cafeId: 'cafe-a',
          ownerUid: 'owner-a',
          role: role,
          membershipGeneration: 7,
        ),
      );
      final requests = <http.Request>[];
      final tokenSessions = <InventoryHttpsSession>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'cafeId': workspace.cafeId,
            'itemId': 'item-a',
            'lifecycleState': archived ? 'active' : 'archived',
            'version': 3,
            'changed': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(client.close);
      final manager = httpsManager(
        workspace: workspace,
        client: client,
        idToken: (captured) async {
          tokenSessions.add(captured);
          return 'fixture.id.token';
        },
      );
      final result = await manager.setLifecycle(
        WorkspaceInventoryLifecycleRequest(
          idempotencyKey: 'fixture-lifecycle-key',
          itemId: 'item-a',
          action: action,
          expectedVersion: 2,
        ),
      );
      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url,
        Uri.https('inventory.offline.invalid', '/inventory/lifecycle'),
      );
      expect(request.headers['authorization'], 'Bearer fixture.id.token');
      expect(jsonDecode(request.body), {
        'idempotencyKey': 'fixture-lifecycle-key',
        'itemId': 'item-a',
        'action': action.name,
        'expectedVersion': 2,
        'expectedCafeId': 'cafe-a',
        'expectedMembershipGeneration': 7,
      });
      expect(tokenSessions.single.uid, workspace.uid);
      expect(tokenSessions.single.workspace, same(workspace));
      expect(result.itemId, 'item-a');
      expect(result.version, 3);
      expect(result.lifecycleState, archived ? 'active' : 'archived');
      expect(result.changed, isTrue);
    });
  }

  testWidgets('Restore dispatches through the injected manager', (
    tester,
  ) async {
    final manager = Manager();
    var changed = 0;
    await pumpLifecycle(
      tester,
      archived: true,
      workspace: session,
      manager: manager,
      onChanged: () => changed++,
    );

    await confirmLifecycle(tester, 'restore-item');

    final request = manager.requests.single;
    expect(request.itemId, 'item-a');
    expect(request.action, InventoryLifecycleAction.restore);
    expect(request.expectedVersion, 2);
    expect(request.idempotencyKey, matches(RegExp(r'^[0-9a-f]{48}$')));
    expect(changed, 1);
  });

  testWidgets(
    'lifecycle credential failure does not dispatch or report uncertainty',
    (tester) async {
      var tokenReads = 0;
      var dispatches = 0;
      var changed = 0;
      final client = MockClient((_) async {
        dispatches++;
        throw StateError('No request is allowed after credential failure.');
      });
      addTearDown(client.close);
      final manager = httpsManager(
        workspace: session,
        client: client,
        idToken: (_) async {
          tokenReads++;
          return null;
        },
      );
      await pumpLifecycle(
        tester,
        archived: false,
        workspace: session,
        manager: manager,
        onChanged: () => changed++,
      );
      await confirmLifecycle(tester, 'archive-item');
      expect(tokenReads, 1);
      expect(dispatches, 0);
      expect(changed, 0);
      expect(
        find.text('Your session could not be verified. Please sign in again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('stale lifecycle requires a reload before another action', (
    tester,
  ) async {
    final client = MockClient(
      (_) async => http.Response(
        '{"error":"aborted"}',
        409,
        headers: {'content-type': 'application/json'},
      ),
    );
    addTearDown(client.close);
    var reloads = 0;
    await pumpLifecycle(
      tester,
      archived: false,
      workspace: session,
      manager: httpsManager(
        workspace: session,
        client: client,
        idToken: (_) async => 'fixture.id.token',
      ),
      onChanged: () => fail('Stale transition cannot report success'),
      onReload: () => reloads++,
    );
    await confirmLifecycle(tester, 'archive-item');
    expect(find.byKey(const ValueKey('archive-item')), findsNothing);
    await tester.tap(find.text('Reload Inventory List'));
    expect(reloads, 1);
  });

  testWidgets('unknown lifecycle outcome has no automatic redispatch', (
    tester,
  ) async {
    final bodies = <String>[];
    final client = MockClient((request) async {
      bodies.add(request.body);
      return http.Response(
        '{"error":"unavailable","outcomeUnknown":true}',
        503,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.close);
    final manager = httpsManager(
      workspace: session,
      client: client,
      idToken: (_) async => 'fixture.id.token',
    );
    var changed = 0;
    await pumpLifecycle(
      tester,
      archived: true,
      workspace: session,
      manager: manager,
      onChanged: () => changed++,
    );
    await confirmLifecycle(tester, 'restore-item');
    expect(bodies, hasLength(1));
    expect(changed, 0);
    expect(
      find.text(
        'The inventory change could not be confirmed. Check inventory before another submission.',
      ),
      findsOneWidget,
    );
    await confirmLifecycle(tester, 'restore-item');
    expect(bodies, [bodies.first, bodies.first]);
    expect(changed, 0);
  });

  for (final invalid in [false, true]) {
    for (final archived in [false, true]) {
      test(
        'independent lifecycle invalid=$invalid archived=$archived rejects before preparation',
        () async {
          var invokes = 0;
          final service = FirebaseWorkspaceInventoryLifecycleManager(
            pilotPolicy: _pilotPolicy(invalid),
            invoke: (_) async {
              invokes++;
              return {};
            },
          );
          await expectLater(
            service.setLifecycle(
              WorkspaceInventoryLifecycleRequest(
                idempotencyKey: 'lifecycle-key-01',
                itemId: 'item-a',
                action: archived
                    ? InventoryLifecycleAction.restore
                    : InventoryLifecycleAction.archive,
                expectedVersion: 2,
              ),
            ),
            throwsA(isA<InventoryLifecyclePilotPolicyException>()),
          );
          expect(invokes, 0);
        },
      );
      testWidgets(
        'direct lifecycle invalid=$invalid archived=$archived rejects injected manager',
        (tester) async {
          final manager = Manager(),
              item = InventoryItem.fromMap(
                'item-a',
                data(lifecycle: archived ? 'archived' : null),
              );
          var changed = 0;
          await tester.pumpWidget(
            AndroidPilotAuthScope(
              dependencies: AndroidPilotAuthDependencies(
                policy: _pilotPolicy(invalid),
              ),
              child: MaterialApp(
                home: Scaffold(
                  body: InventoryLifecycleActionButton(
                    item: item,
                    workspaceSession: session,
                    manager: manager,
                    onChanged: () => changed++,
                  ),
                ),
              ),
            ),
          );
          expect(find.byType(OutlinedButton), findsNothing);
          expect(manager.requests, isEmpty);
          expect(changed, 0);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'captured lifecycle invalid=$invalid archived=$archived cannot dispatch',
        (tester) async {
          final manager = Manager(),
              item = InventoryItem.fromMap(
                'item-a',
                data(lifecycle: archived ? 'archived' : null),
              );
          var changed = 0;
          var policy = _normalPolicy;
          late StateSetter update;
          await tester.pumpWidget(
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return AndroidPilotAuthScope(
                  dependencies: AndroidPilotAuthDependencies(policy: policy),
                  child: MaterialApp(
                    home: Scaffold(
                      body: InventoryLifecycleActionButton(
                        item: item,
                        workspaceSession: session,
                        manager: manager,
                        onChanged: () => changed++,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
          final submit = tester
              .widget<OutlinedButton>(find.byType(OutlinedButton))
              .onPressed!;
          update(() => policy = _pilotPolicy(invalid));
          await tester.pump();
          submit();
          submit();
          await tester.pump();
          expect(manager.requests, isEmpty);
          expect(changed, 0);
          expect(find.byType(AlertDialog), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'lifecycle policy replacement during confirmation stops dispatch',
    (tester) async {
      final manager = Manager(), item = InventoryItem.fromMap('item-a', data());
      var policy = _normalPolicy;
      late StateSetter update;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AndroidPilotAuthScope(
              dependencies: AndroidPilotAuthDependencies(policy: policy),
              child: MaterialApp(
                home: Scaffold(
                  body: InventoryLifecycleActionButton(
                    item: item,
                    workspaceSession: session,
                    manager: manager,
                    onChanged: () {},
                  ),
                ),
              ),
            );
          },
        ),
      );
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed!();
      await tester.pumpAndSettle();
      update(() => policy = _pilotPolicy(false));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lifecycle-confirm')));
      await tester.pumpAndSettle();
      expect(manager.requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('legacy items are active and unknown lifecycle fails closed', () {
    expect(InventoryItem.fromMap('legacy', data()).isArchived, isFalse);
    expect(
      () => InventoryItem.fromMap('bad', data(lifecycle: 'deleted')),
      throwsFormatException,
    );
  });

  test('strict activity parser accepts valid lifecycle audits only', () {
    final base = <String, dynamic>{
      'schemaVersion': 1,
      'cafeId': 'cafe-a',
      'itemId': 'item-a',
      'actorUid': 'staff-a',
      'requestHash': 'hash-a',
      'preservedQuantity': 4,
      'fromVersion': 2,
      'resultVersion': 3,
      'createdAt': DateTime.utc(2026, 1, 1),
    };
    final archived = WorkspaceActivity.fromMap('archive-a', {
      ...base,
      'type': 'inventory_archived',
      'fromState': 'active',
      'resultState': 'archived',
    });
    expect(archived.type, WorkspaceActivityType.inventoryArchived);
    expect(
      () => WorkspaceActivity.fromMap('bad-a', {
        ...base,
        'type': 'inventory_restored',
        'fromState': 'active',
        'resultState': 'active',
      }),
      throwsFormatException,
    );
  });

  test(
    'repository separates active and archived items on the verified path',
    () async {
      final repository = WorkspaceInventoryRepository(
        session: session,
        dataSource: Source([
          WorkspaceInventoryDocument(id: 'active', data: data()),
          WorkspaceInventoryDocument(
            id: 'archived',
            data: data(lifecycle: 'archived'),
          ),
        ]),
      );
      expect((await repository.watchItems().first).single.id, 'active');
      expect(
        (await repository.watchArchivedItems().first).single.id,
        'archived',
      );
      expect(repository.collectionPath, 'cafes/cafe-a/inventory');
    },
  );

  testWidgets(
    'cancel performs no write; confirm prevents duplicate submission',
    (tester) async {
      final completer = Completer<WorkspaceInventoryLifecycleResult>();
      final manager = Manager(completer: completer);
      var changed = 0;
      final item = InventoryItem.fromMap('item-a', data());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InventoryLifecycleActionButton(
              item: item,
              manager: manager,
              onChanged: () => changed++,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('archive-item')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('lifecycle-cancel')));
      await tester.pumpAndSettle();
      expect(manager.requests, isEmpty);

      await tester.tap(find.byKey(const ValueKey('archive-item')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('lifecycle-confirm')));
      await tester.pump();
      expect(manager.requests, hasLength(1));
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('archive-item')))
            .onPressed,
        isNull,
      );
      completer.complete(
        const WorkspaceInventoryLifecycleResult(
          itemId: 'item-a',
          lifecycleState: 'archived',
          version: 3,
          changed: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(changed, 1);
    },
  );
}
