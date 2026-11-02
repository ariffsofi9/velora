import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/edit_item_page.dart';
import 'package:velora/screens/inventory/item_details_page.dart';
import 'package:velora/screens/inventory/stock/stock_adjustment_page.dart';
import 'package:velora/services/workspace_session.dart';

class _InventorySource implements WorkspaceInventoryDataSource {
  final Stream<List<WorkspaceInventoryDocument>> stream;
  String? watchedPath;

  _InventorySource(this.stream);

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw UnimplementedError();

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watchedPath = path;
    return stream;
  }
}

class _RetryInventorySource implements WorkspaceInventoryDataSource {
  int watchCount = 0;

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw UnimplementedError();

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watchCount++;
    if (watchCount == 1) return Stream.error(StateError('unavailable'));
    return Stream.value([_milk()]);
  }
}

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'verified-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

WorkspaceInventoryDocument _milk() => WorkspaceInventoryDocument(
  id: 'milk-a',
  data: {
    'name': 'Fresh Milk',
    'category': 'Dairy',
    'quantity': 4,
    'unit': 'L',
    'expiryDate': DateTime.now().add(const Duration(days: 3)),
    'imageUrl': '',
    'createdAt': DateTime.now(),
  },
);

WorkspaceInventoryDocument _item(String id, int quantity) =>
    WorkspaceInventoryDocument(
      id: id,
      data: {
        'name': id,
        'category': 'General',
        'quantity': quantity,
        'unit': 'pcs',
        'expiryDate': DateTime.now().add(const Duration(days: 30)),
        'imageUrl': '',
        'createdAt': DateTime.now(),
      },
    );

Widget _app(WorkspaceInventoryDataSource source, {double textScale = 1}) =>
    MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: InventoryPage(
        workspaceSession: _session,
        repository: WorkspaceInventoryRepository(
          session: _session,
          dataSource: source,
        ),
      ),
    );

void main() {
  testWidgets('empty verified cafe shows the normal empty state', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value(const []));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(source.watchedPath, 'cafes/verified-cafe/inventory');
    expect(find.text('Your inventory is empty'), findsOneWidget);
    expect(find.text('Something went wrong.'), findsNothing);
  });

  testWidgets('populated cafe renders scoped inventory and keeps filtering', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_milk()]));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(source.watchedPath, 'cafes/verified-cafe/inventory');
    expect(find.text('Fresh Milk'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'coffee');
    await tester.pump();
    expect(find.text('No matching items found.'), findsOneWidget);
    expect(find.text('Clear filters'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    expect(find.text('Fresh Milk'), findsOneWidget);
  });

  testWidgets('loading state is distinct from empty and error states', (
    tester,
  ) async {
    final controller = StreamController<List<WorkspaceInventoryDocument>>();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(_InventorySource(controller.stream)));
    await tester.pump();

    expect(find.byKey(const ValueKey('inventory-loading')), findsOneWidget);
    expect(find.text('Your inventory is empty'), findsNothing);
    expect(find.byKey(const ValueKey('inventory-read-error')), findsNothing);
  });

  testWidgets('category and sort controls expose current inventory options', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_milk()]));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('inventory-category-filter')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('inventory-sort-order')), findsOneWidget);
    expect(find.text('All Categories'), findsOneWidget);
    expect(find.text('Expiry Soonest'), findsOneWidget);
  });

  testWidgets('inventory controls fit a 320px screen at doubled text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(_InventorySource(Stream.value([_milk()])), textScale: 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('inventory-category-filter')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('inventory-sort-order')), findsOneWidget);
  });

  testWidgets('malformed scoped inventory fails with a generic safe message', (
    tester,
  ) async {
    final malformed = WorkspaceInventoryDocument(
      id: 'bad-item',
      data: {
        'name': 'Bad item',
        'category': 'General',
        'quantity': 'unknown',
        'unit': 'pcs',
        'expiryDate': DateTime.now(),
        'createdAt': DateTime.now(),
      },
    );
    final source = _InventorySource(Stream.value([malformed]));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(find.text('Inventory could not be loaded.'), findsOneWidget);
    expect(find.textContaining('unknown'), findsNothing);
    expect(find.textContaining('Invalid inventory'), findsNothing);
  });

  testWidgets('Low Stock filter uses shared below equal and above boundary', (
    tester,
  ) async {
    final source = _InventorySource(
      Stream.value([_item('below', 4), _item('equal', 5), _item('above', 6)]),
    );

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Low Stock'));
    await tester.pump();

    expect(find.text('below'), findsOneWidget);
    expect(find.text('equal'), findsOneWidget);
    expect(find.text('above'), findsNothing);
  });

  testWidgets('repository errors preserve the inventory error state', (
    tester,
  ) async {
    final source = _InventorySource(
      Stream.error(StateError('permission denied')),
    );

    await tester.pumpWidget(_app(source));
    await tester.pump();

    expect(find.text('Inventory could not be loaded.'), findsOneWidget);
    expect(find.text('Your inventory is empty'), findsNothing);
  });

  testWidgets('Retry creates a fresh scoped subscription and can recover', (
    tester,
  ) async {
    final source = _RetryInventorySource();

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();
    expect(find.text('Inventory could not be loaded.'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(source.watchCount, 2);
    expect(find.text('Fresh Milk'), findsOneWidget);
    expect(find.text('Inventory could not be loaded.'), findsNothing);
  });

  testWidgets(
    'scoped Stock, Edit and Add are reachable without legacy mutations',
    (tester) async {
      final source = _InventorySource(Stream.value([_milk()]));

      await tester.pumpWidget(_app(source));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fresh Milk'));
      await tester.pumpAndSettle();

      expect(find.byType(ItemDetailsPage), findsOneWidget);
      await tester.tap(find.text('Stock In'));
      await tester.pumpAndSettle();
      expect(find.byType(StockInPage), findsOneWidget);
      var navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit Item'));
      await tester.pumpAndSettle();
      expect(find.byType(EditItemPage), findsOneWidget);
      navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.byType(AddItemPage), findsOneWidget);
    },
  );
}
