import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/edit_item_page.dart';
import 'package:velora/screens/inventory/item_details_page.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_card.dart';
import 'package:velora/services/workspace_session.dart';

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'inventory-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

void main() {
  final item = InventoryItem(
    id: 'test-item',
    name: 'Fresh milk for coffee',
    category: 'Dairy',
    quantity: 2,
    expiryDate: DateTime.now().add(const Duration(days: 2)),
    imageUrl: '',
    createdAt: DateTime.now(),
  );
  final screens = <String, Widget Function()>{
    'Inventory row': () => Scaffold(
      body: SingleChildScrollView(
        child: InventoryCard(item: item, onTap: () {}),
      ),
    ),
    'Add Item': () => AddItemPage(workspaceSession: _session),
    'Edit Item': () => EditItemPage(item: item, workspaceSession: _session),
    'Item Details': () =>
        ItemDetailsPage(item: item, workspaceSession: _session),
  };

  testWidgets('Inventory row opens its existing details action', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: InventoryCard(item: item, onTap: () => opened = true),
        ),
      ),
    );

    await tester.tap(find.text(item.name));

    expect(opened, isTrue);
    expect(find.text('Low Stock'), findsOneWidget);
  });

  testWidgets('Add Item keeps required-field validation before saving', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: AddItemPage(workspaceSession: _session),
      ),
    );

    await tester.ensureVisible(find.text('Save Item'));
    await tester.tap(find.text('Save Item'));
    await tester.pump();

    expect(
      find.text('Please fill item name, quantity and expiry date'),
      findsOneWidget,
    );
  });

  testWidgets('Item Details exposes trusted stock and edit actions only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ItemDetailsPage(item: item),
      ),
    );

    expect(find.text('Edit Item'), findsOneWidget);
    expect(find.text('Stock In'), findsOneWidget);
    expect(find.text('Stock Out'), findsOneWidget);
    expect(find.text('Mark as Used'), findsNothing);
    expect(find.text('Delete Item'), findsNothing);
  });

  for (final entry in screens.entries) {
    for (final width in [320.0, 393.0, 768.0, 1280.0]) {
      testWidgets('${entry.key} fits $width at doubled text', (tester) async {
        tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: entry.value(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
