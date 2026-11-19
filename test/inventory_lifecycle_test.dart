import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/workspace_activity.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_lifecycle_action.dart';
import 'package:velora/services/workspace_inventory_lifecycle_service.dart';
import 'package:velora/services/workspace_session.dart';

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

void main() {
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
