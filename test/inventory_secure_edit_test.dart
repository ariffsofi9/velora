import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/edit_item_page.dart';
import 'package:velora/services/workspace_inventory_update_service.dart';
import 'package:velora/services/workspace_session.dart';

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'verified-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

InventoryItem _item({
  String id = 'item-a',
  String name = 'Milk',
  int version = 1,
}) => InventoryItem(
  id: id,
  name: name,
  category: 'Dairy',
  quantity: 4,
  unit: 'L',
  expiryDate: DateTime(2030, 1, 2),
  imageUrl: 'https://example.test/milk.png',
  createdAt: DateTime(2026),
  version: version,
);

class _Updater implements WorkspaceInventoryUpdater {
  final List<Object> outcomes;
  final requests = <WorkspaceInventoryUpdateRequest>[];

  _Updater(this.outcomes);

  @override
  Future<WorkspaceInventoryUpdateResult> updateItem(
    WorkspaceInventoryUpdateRequest request,
  ) async {
    requests.add(request);
    final outcome = outcomes.removeAt(0);
    if (outcome is Future<WorkspaceInventoryUpdateResult>) return outcome;
    if (outcome is WorkspaceInventoryUpdateResult) return outcome;
    throw outcome;
  }
}

class _Source implements WorkspaceInventoryDataSource {
  final List<WorkspaceInventoryDocument> documents;
  _Source(this.documents);

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async =>
      documents;

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) =>
      Stream.value(documents);
}

WorkspaceInventoryRepository _repository(InventoryItem item) =>
    WorkspaceInventoryRepository(
      session: _session,
      dataSource: _Source([
        WorkspaceInventoryDocument(
          id: item.id,
          data: {
            'name': item.name,
            'category': item.category,
            'quantity': item.quantity,
            'unit': item.unit,
            'expiryDate': item.expiryDate,
            'imageUrl': item.imageUrl,
            'createdAt': item.createdAt,
            'version': item.version,
          },
        ),
      ]),
    );

Widget _app({
  required InventoryItem item,
  required WorkspaceInventoryUpdater updater,
  WorkspaceInventoryRepository? repository,
  bool verified = true,
  String Function()? keyFactory,
}) => MaterialApp(
  theme: AppTheme.light,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EditItemPage(
              item: item,
              workspaceSession: verified ? _session : null,
              updater: updater,
              repository: repository,
              idempotencyKeyFactory: keyFactory,
            ),
          ),
        ),
        child: const Text('Open Edit'),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open Edit'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save Changes'));
  await tester.tap(find.text('Save Changes'));
}

void main() {
  test('legacy items use version 1 while invalid versions fail closed', () {
    final legacy = InventoryItem.fromMap('legacy', {
      'name': 'Legacy',
      'category': 'General',
      'quantity': 1,
      'expiryDate': DateTime(2030),
      'createdAt': DateTime(2029),
    });
    expect(legacy.version, 1);
    expect(
      () => InventoryItem.fromMap('invalid', {
        'name': 'Invalid',
        'category': 'General',
        'quantity': 1,
        'expiryDate': DateTime(2030),
        'createdAt': DateTime(2029),
        'version': 0,
      }),
      throwsFormatException,
    );
  });

  testWidgets('prefills metadata and keeps quantity read-only', (tester) async {
    final updater = _Updater(const []);
    await tester.pumpWidget(_app(item: _item(), updater: updater));
    await _open(tester);

    expect(find.text('Milk'), findsOneWidget);
    expect(find.text('Dairy'), findsOneWidget);
    expect(find.text('4 L'), findsOneWidget);
    final quantityField = tester.widget<EditableText>(
      find.descendant(
        of: find.ancestor(
          of: find.text('4 L'),
          matching: find.byType(TextFormField),
        ),
        matching: find.byType(EditableText),
      ),
    );
    expect(quantityField.readOnly, isTrue);
    expect(find.text('https://example.test/milk.png'), findsOneWidget);
  });

  testWidgets('missing workspace or item identity fails closed', (
    tester,
  ) async {
    final updater = _Updater(const []);
    await tester.pumpWidget(
      _app(
        item: _item(id: ''),
        updater: updater,
        verified: false,
      ),
    );
    await _open(tester);
    await _save(tester);
    await tester.pump();

    expect(
      find.textContaining('requires a verified workspace'),
      findsOneWidget,
    );
    expect(updater.requests, isEmpty);
  });

  testWidgets('success disables duplicate taps and returns to Inventory', (
    tester,
  ) async {
    final pending = Completer<WorkspaceInventoryUpdateResult>();
    final updater = _Updater([pending.future]);
    await tester.pumpWidget(
      _app(
        item: _item(),
        updater: updater,
        keyFactory: () => 'fixed-update-key-001',
      ),
    );
    await _open(tester);
    await tester.enterText(find.byType(TextField).first, 'Whole Milk');
    await _save(tester);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(ElevatedButton));
    expect(updater.requests, hasLength(1));
    expect(updater.requests.single.expectedVersion, 1);

    pending.complete(
      const WorkspaceInventoryUpdateResult(
        itemId: 'item-a',
        updated: true,
        version: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Open Edit'), findsOneWidget);
  });

  testWidgets('unchanged retry keeps key and changed form rotates it', (
    tester,
  ) async {
    var keyIndex = 0;
    final updater = _Updater([
      const WorkspaceInventoryUpdateException(
        WorkspaceInventoryUpdateFailure.unavailable,
      ),
      const WorkspaceInventoryUpdateException(
        WorkspaceInventoryUpdateFailure.unavailable,
      ),
      const WorkspaceInventoryUpdateResult(
        itemId: 'item-a',
        updated: true,
        version: 2,
      ),
    ]);
    await tester.pumpWidget(
      _app(
        item: _item(),
        updater: updater,
        keyFactory: () => 'update-key-${++keyIndex}'.padRight(16, '0'),
      ),
    );
    await _open(tester);
    await tester.enterText(find.byType(TextField).first, 'Whole Milk');
    await _save(tester);
    await tester.pumpAndSettle();
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await _save(tester);
    await tester.pumpAndSettle();
    expect(
      updater.requests[1].idempotencyKey,
      updater.requests[0].idempotencyKey,
    );

    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Oat Milk');
    await _save(tester);
    await tester.pumpAndSettle();
    expect(
      updater.requests[2].idempotencyKey,
      isNot(updater.requests[1].idempotencyKey),
    );
  });

  testWidgets('stale edit requires explicit reload before resubmission', (
    tester,
  ) async {
    final refreshed = _item(name: 'Remote Milk', version: 2);
    final updater = _Updater([
      const WorkspaceInventoryUpdateException(
        WorkspaceInventoryUpdateFailure.stale,
      ),
      const WorkspaceInventoryUpdateResult(
        itemId: 'item-a',
        updated: true,
        version: 3,
      ),
    ]);
    await tester.pumpWidget(
      _app(
        item: _item(),
        updater: updater,
        repository: _repository(refreshed),
        keyFactory: () => 'refresh-update-key',
      ),
    );
    await _open(tester);
    await tester.enterText(find.byType(TextField).first, 'Local Milk');
    await _save(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reload-latest-item')), findsOneWidget);
    expect(find.textContaining('changed elsewhere'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('reload-latest-item')));
    await tester.pumpAndSettle();
    expect(find.text('Remote Milk'), findsOneWidget);
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Reviewed Milk');
    await _save(tester);
    await tester.pumpAndSettle();
    expect(updater.requests[1].expectedVersion, 2);
  });
}
