import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/repositories/workspace_inventory_movement_repository.dart';
import 'package:velora/screens/inventory/stock/stock_history_page.dart';
import 'package:velora/screens/inventory/utils_inventory/inventory_sort_helper.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_card.dart';
import 'package:velora/services/workspace_inventory_create_service.dart';
import 'package:velora/services/workspace_inventory_update_service.dart';
import 'package:velora/services/workspace_inventory_stock_service.dart';
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
  int watches = 0;

  _InventorySource(this.stream);

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw UnimplementedError();

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watches++;
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
    'default Add Edit Stock and Archive are contained while details remain readable',
    (tester) async {
      final source = _InventorySource(Stream.value([_milk()]));
      await tester.pumpWidget(_app(source));
      await tester.pumpAndSettle();
      expect(find.textContaining('4 L in stock'), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.byType(AddItemPage), findsNothing);
      expect(find.text(_unavailable), findsOneWidget);
      await tester.tap(find.text('Fresh Milk'));
      await tester.pumpAndSettle();
      final details = tester.widget<ItemDetailsPage>(
        find.byType(ItemDetailsPage),
      );
      expect(details.workspaceSession, same(_session));
      expect(details.repository!.session, same(_session));
      expect(find.text('4 L'), findsOneWidget);
      for (final label in [
        'Stock In',
        'Stock Out',
        'Edit Item',
        'Archive Item',
      ]) {
        if (label == 'Archive Item') {
          await tester.scrollUntilVisible(
            find.text(label),
            250,
            scrollable: find.byType(Scrollable).last,
          );
        } else {
          await tester.ensureVisible(find.text(label));
        }
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(find.byType(ItemDetailsPage), findsOneWidget);
        expect(find.byType(StockInPage), findsNothing);
        expect(find.byType(StockOutPage), findsNothing);
        expect(find.byType(EditItemPage), findsNothing);
        expect(find.text('Archive item?'), findsNothing);
        expect(find.text(_unavailable), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final role in CafeRole.values) {
    testWidgets('${role.name} reads only the verified cafe', (tester) async {
      final session = _newSession(role: role);
      final source = _InventorySource(Stream.value([_milk()]));
      final repository = WorkspaceInventoryRepository(
        session: session,
        dataSource: source,
      );
      await tester.pumpWidget(_journey(session, repository));
      await tester.pumpAndSettle();
      expect(source.watchedPath, 'cafes/verified-cafe/inventory');
      expect(find.text('Fresh Milk'), findsOneWidget);
    });
  }

  testWidgets('empty-state Add also remains contained', (tester) async {
    await tester.pumpWidget(_app(_InventorySource(Stream.value(const []))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Add Item'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Item'));
    await tester.pumpAndSettle();
    expect(find.byType(AddItemPage), findsNothing);
    expect(find.text(_unavailable), findsOneWidget);
  });

  testWidgets('pending old read cannot appear after replacement', (
    tester,
  ) async {
    final oldEvents = StreamController<List<WorkspaceInventoryDocument>>();
    final newEvents = StreamController<List<WorkspaceInventoryDocument>>();
    final oldSession = _newSession();
    final newSession = _newSession(cafe: 'other-cafe');
    final oldRepo = WorkspaceInventoryRepository(
      session: oldSession,
      dataSource: _InventorySource(oldEvents.stream),
    );
    final newRepo = WorkspaceInventoryRepository(
      session: newSession,
      dataSource: _InventorySource(newEvents.stream),
    );
    await tester.pumpWidget(_journey(oldSession, oldRepo));
    await tester.pumpWidget(_journey(newSession, newRepo));
    oldEvents.add([_milk()]);
    await tester.pump();
    expect(find.text('Fresh Milk'), findsNothing);
    expect(find.byKey(const ValueKey('inventory-loading')), findsOneWidget);
    newEvents.add([_item('Current item', 6)]);
    await tester.pumpAndSettle();
    expect(find.text('Current item'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    unawaited(oldEvents.close());
    unawaited(newEvents.close());
  });

  testWidgets(
    'repository from a different session is rejected before subscribing',
    (tester) async {
      final source = _InventorySource(Stream.value([_milk()]));
      final repository = WorkspaceInventoryRepository(
        session: _newSession(),
        dataSource: source,
      );
      await tester.pumpWidget(_journey(_newSession(), repository));
      await tester.pumpAndSettle();
      expect(source.watches, 0);
      expect(
        find.byKey(const ValueKey('inventory-read-error')),
        findsOneWidget,
      );
      expect(find.text('Fresh Milk'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Retry'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.byType(AddItemPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['identity', 'generation', 'account', 'cafe']) {
    testWidgets(
      '$change replacement immediately hides old items and suppresses late responses',
      (tester) async {
        final oldEvents = StreamController<List<WorkspaceInventoryDocument>>();
        final newEvents = StreamController<List<WorkspaceInventoryDocument>>();
        final oldSession = _newSession();
        final newSession = _newSession(
          cafe: change == 'cafe' ? 'other-cafe' : 'verified-cafe',
          uid: change == 'account' ? 'other-user' : 'staff-a',
          generation: change == 'generation' ? 2 : 1,
        );
        final oldRepository = WorkspaceInventoryRepository(
          session: oldSession,
          dataSource: _InventorySource(oldEvents.stream),
        );
        final source = _InventorySource(newEvents.stream);
        final newRepository = WorkspaceInventoryRepository(
          session: newSession,
          dataSource: source,
        );
        await tester.pumpWidget(_journey(oldSession, oldRepository));
        oldEvents.add([_milk()]);
        await tester.pumpAndSettle();
        expect(find.text('Fresh Milk'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'milk');
        await tester.pumpWidget(_journey(newSession, newRepository));
        expect(find.text('Fresh Milk'), findsNothing);
        expect(find.byKey(const ValueKey('inventory-loading')), findsOneWidget);
        oldEvents.add([_item('stale result', 7)]);
        await tester.pump();
        expect(find.text('stale result'), findsNothing);
        newEvents.add([_item('replacement', 9)]);
        await tester.pumpAndSettle();
        expect(find.text('replacement'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(source.watchedPath, 'cafes/${newSession.cafeId}/inventory');
        await tester.pumpWidget(const SizedBox());
        unawaited(oldEvents.close());
        unawaited(newEvents.close());
      },
    );
  }

  testWidgets('same-field replacement with the old repository fails closed', (
    tester,
  ) async {
    final session = _newSession();
    final source = _InventorySource(Stream.value([_milk()]));
    final repository = WorkspaceInventoryRepository(
      session: session,
      dataSource: source,
    );
    await tester.pumpWidget(_journey(session, repository));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_journey(_newSession(), repository));
    expect(find.text('Fresh Milk'), findsNothing);
    await tester.pumpAndSettle();
    expect(source.watches, 1);
    expect(find.byKey(const ValueKey('inventory-read-error')), findsOneWidget);
  });

  for (final populated in [false, true]) {
    testWidgets(
      'invalidation hides ${populated ? 'published' : 'pending'} data and blocks retry/navigation',
      (tester) async {
        final events = StreamController<List<WorkspaceInventoryDocument>>();
        final source = _InventorySource(events.stream);
        final session = _newSession();
        final repository = WorkspaceInventoryRepository(
          session: session,
          dataSource: source,
        );
        await tester.pumpWidget(_journey(session, repository));
        if (populated) {
          events.add([_milk()]);
          await tester.pumpAndSettle();
          expect(find.text('Fresh Milk'), findsOneWidget);
        }
        session.invalidate();
        events.add([_item('late after logout', 2)]);
        await tester.pumpWidget(_journey(session, repository));
        await tester.pumpAndSettle();
        expect(find.text('Fresh Milk'), findsNothing);
        expect(find.text('late after logout'), findsNothing);
        expect(
          find.byKey(const ValueKey('inventory-read-error')),
          findsOneWidget,
        );
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        expect(find.byType(AddItemPage), findsNothing);
        expect(source.watches, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        unawaited(events.close());
      },
    );
  }

  testWidgets('logout removes the inventory route while a read is pending', (
    tester,
  ) async {
    final events = StreamController<List<WorkspaceInventoryDocument>>();
    final session = _newSession();
    final repository = WorkspaceInventoryRepository(
      session: session,
      dataSource: _InventorySource(events.stream),
    );
    await tester.pumpWidget(_journey(session, repository));
    session.invalidate();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Signed out'))),
    );
    events.add([_milk()]);
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('Fresh Milk'), findsNothing);
    expect(tester.takeException(), isNull);
    unawaited(events.close());
  });

  testWidgets('removed category and clear filters synchronize form fields', (
    tester,
  ) async {
    final events = StreamController<List<WorkspaceInventoryDocument>>();
    await tester.pumpWidget(_app(_InventorySource(events.stream)));
    events.add([_milk(), _item('Other', 10)]);
    await tester.pumpAndSettle();
    await _select(tester, 'inventory-category-filter', 'Dairy');
    await _select(
      tester,
      'inventory-sort-order',
      InventorySortOption.quantity.label,
    );
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Clear filters'));
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<FormFieldState<String>>(
            find.byKey(const ValueKey('inventory-category-filter')),
          )
          .value,
      'All Categories',
    );
    expect(
      tester
          .state<FormFieldState<InventorySortOption>>(
            find.byKey(const ValueKey('inventory-sort-order')),
          )
          .value,
      InventorySortOption.expiry,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await _select(tester, 'inventory-category-filter', 'Dairy');
    events.add([_item('Other', 10)]);
    await tester.pumpAndSettle();
    expect(
      tester
          .state<FormFieldState<String>>(
            find.byKey(const ValueKey('inventory-category-filter')),
          )
          .value,
      'All Categories',
    );
    await tester.ensureVisible(find.text('Other'));
    expect(find.text('Other'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    unawaited(events.close());
  });

  testWidgets('search category status and sorting controls work together', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _InventorySource(
          Stream.value([
            _item('Zebra', 3),
            _item('Apple', 1),
            _item('Large', 9),
            _milk(),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _select(
      tester,
      'inventory-sort-order',
      InventorySortOption.name.label,
    );
    expect(
      tester
          .widgetList<InventoryCard>(find.byType(InventoryCard))
          .map((w) => w.item.name)
          .first,
      'Apple',
    );
    await _select(
      tester,
      'inventory-sort-order',
      InventorySortOption.quantity.label,
    );
    expect(
      tester
          .widgetList<InventoryCard>(find.byType(InventoryCard))
          .map((w) => w.item.quantity)
          .first,
      1,
    );
    await _select(tester, 'inventory-category-filter', 'General');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 800));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Low Stock'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Low Stock'))
          .selected,
      isTrue,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byType(TextField)),
      alignment: 0.5,
    );
    await tester.enterText(find.byType(TextField), '  EB  ');
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<InventoryCard>(find.byType(InventoryCard))
          .map((w) => w.item.name),
      ['Zebra'],
    );
  });

  testWidgets('details preserve scoped read-only Stock History navigation', (
    tester,
  ) async {
    final reader = _MovementReader();
    final source = _InventorySource(Stream.value([_milk()]));
    final repository = WorkspaceInventoryRepository(
      session: _session,
      dataSource: source,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: InventoryPage(
          workspaceSession: _session,
          repository: repository,
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fresh Milk'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Stock History'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Stock History'));
    await tester.pumpAndSettle();
    final history = tester.widget<StockHistoryPage>(
      find.byType(StockHistoryPage),
    );
    expect(history.workspaceSession, same(_session));
    expect(history.item.id, 'milk-a');
    expect(reader.items, ['milk-a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalidated and mismatched detail contexts hide item information',
    (tester) async {
      final session = _newSession();
      final repository = WorkspaceInventoryRepository(
        session: session,
        dataSource: _InventorySource(Stream.value([])),
      );
      final item = InventoryItem.fromMap(_milk().id, _milk().data);
      Widget details(WorkspaceSession contextSession) => MaterialApp(
        home: ItemDetailsPage(
          item: item,
          workspaceSession: contextSession,
          repository: repository,
        ),
      );
      await tester.pumpWidget(details(session));
      expect(find.text('Fresh Milk'), findsOneWidget);
      session.invalidate();
      await tester.pumpWidget(details(session));
      expect(find.text('Fresh Milk'), findsNothing);
      expect(
        find.text('Workspace access could not be verified.'),
        findsOneWidget,
      );
      await tester.pumpWidget(details(_newSession()));
      expect(find.text('Fresh Milk'), findsNothing);
    },
  );

  testWidgets(
    'explicit injected mutation adapters remain available without dispatch on navigation',
    (tester) async {
      final adapters = _MutationAdapters();
      final source = _InventorySource(Stream.value([_milk()]));
      final repository = WorkspaceInventoryRepository(
        session: _session,
        dataSource: source,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: InventoryPage(
            workspaceSession: _session,
            repository: repository,
            inventoryCreator: adapters,
            inventoryUpdater: adapters,
            stockAdjuster: adapters,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AddItemPage>(find.byType(AddItemPage)).creator,
        same(adapters),
      );
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fresh Milk'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit Item'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditItemPage>(find.byType(EditItemPage)).updater,
        same(adapters),
      );
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stock In'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<StockInPage>(find.byType(StockInPage)).adjuster,
        same(adapters),
      );
      expect(adapters.dispatches, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

const _unavailable =
    'Inventory changes are unavailable until secure workspace updates are enabled.';

WorkspaceSession _newSession({
  String cafe = 'verified-cafe',
  String uid = 'staff-a',
  int generation = 1,
  CafeRole role = CafeRole.staff,
}) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafe,
    uid: role == CafeRole.owner ? 'owner-a' : uid,
    ownerUid: 'owner-a',
    role: role,
    membershipGeneration: generation,
  ),
);

Widget _journey(
  WorkspaceSession session,
  WorkspaceInventoryRepository repository,
) => MaterialApp(
  theme: AppTheme.light,
  home: InventoryPage(workspaceSession: session, repository: repository),
);

Future<void> _select(WidgetTester tester, String key, String value) async {
  final dropdown = find.byKey(ValueKey(key));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

class _MovementReader implements WorkspaceInventoryMovementReader {
  final items = <String>[];
  @override
  Future<WorkspaceMovementPage> getItemMovements(
    String itemId, {
    WorkspaceMovementCursor? cursor,
  }) async {
    items.add(itemId);
    return const WorkspaceMovementPage(movements: []);
  }
}

class _MutationAdapters
    implements
        WorkspaceInventoryCreator,
        WorkspaceInventoryUpdater,
        WorkspaceInventoryStockAdjuster {
  int dispatches = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    dispatches++;
    throw StateError('Unexpected mutation dispatch');
  }
}
