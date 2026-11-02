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

void main() {
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
