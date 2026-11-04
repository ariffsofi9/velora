import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/menu_item.dart';
import 'package:velora/repositories/workspace_menu_repository.dart';
import 'package:velora/screens/menu/menu_page.dart';
import 'package:velora/screens/menu/menu_edit_page.dart';
import 'menu_model_test.dart' show menuData;

class MenuDouble implements MenuRepository {
  CafeRole role = CafeRole.owner;
  final changes = StreamController<void>.broadcast(sync: true);
  List<MenuItem> items = [MenuItem.fromMap(menuData())];
  final keys = <String>[];
  int lists = 0, toggles = 0, lifecycles = 0;
  String? next;
  Object? listError, writeError;
  VoidCallback? onToggle;
  Completer<MenuItemsPage>? pending;
  MenuItem? latest;
  @override
  Stream<void> get sessionChanges => changes.stream;
  @override
  Future<CafeWorkspace> resolve() async => CafeWorkspace(
    cafeId: 'cafe-a',
    uid: 'owner-a',
    ownerUid: 'owner-a',
    role: role,
  );
  @override
  Future<MenuItemsPage> list({
    bool includeArchived = false,
    String? cursor,
  }) async {
    lists++;
    if (listError != null) throw listError!;
    if (pending != null) return pending!.future;
    return MenuItemsPage(items, next);
  }

  @override
  Future<MenuItem> get(String id) async => latest ?? items.first;
  @override
  Future<void> save({
    MenuItem? item,
    required MenuDraft draft,
    required String key,
  }) async {
    keys.add(key);
    if (writeError != null) throw writeError!;
  }

  @override
  Future<void> availability(MenuItem item, bool available, String key) async {
    toggles++;
    keys.add(key);
    onToggle?.call();
    if (writeError != null) throw writeError!;
  }

  @override
  Future<void> lifecycle(MenuItem item, bool archive, String key) async {
    lifecycles++;
    keys.add(key);
    if (writeError != null) throw writeError!;
  }
}

Widget app(Widget home, {double scale = 1}) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: home,
);
void main() {
  testWidgets('Owner sees RM price, availability and management actions', (
    tester,
  ) async {
    await tester.pumpWidget(app(MenuPage(repository: MenuDouble())));
    await tester.pumpAndSettle();
    expect(find.text('Latte'), findsOneWidget);
    expect(find.text('RM 12.50'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-add')), findsOneWidget);
  });
  testWidgets(
    'Staff has availability only; confirmation cancel performs no mutation',
    (tester) async {
      final repo = MenuDouble()..role = CafeRole.staff;
      await tester.pumpWidget(app(MenuPage(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Archive'), findsNothing);
      expect(find.byKey(const ValueKey('menu-add')), findsNothing);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.toggles, 0);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-confirm')));
      await tester.pumpAndSettle();
      expect(repo.toggles, 1);
      expect(repo.keys.single.length, 48);
    },
  );
  testWidgets(
    'archived Owner item offers restore and disables availability/edit',
    (tester) async {
      final repo = MenuDouble()
        ..items = [MenuItem.fromMap(menuData(archived: true))];
      await tester.pumpWidget(app(MenuPage(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-confirm')));
      await tester.pumpAndSettle();
      expect(repo.lifecycles, 1);
    },
  );
  testWidgets('loading, error retry, empty and load-more states are explicit', (
    tester,
  ) async {
    final repo = MenuDouble()
      ..listError = const MenuException(MenuFailure.unavailable);
    await tester.pumpWidget(app(MenuPage(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-error')), findsOneWidget);
    expect(find.text('Latte'), findsNothing);
    repo.listError = null;
    repo.items = [];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No menu items yet.'), findsOneWidget);
    repo.items = [MenuItem.fromMap(menuData())];
    repo.next = 'next';
    await tester.tap(find.byTooltip('Refresh menu'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Load More'));
    repo.next = null;
    repo.items = [
      MenuItem.fromMap({...menuData(id: 'second'), 'name': 'Tea'}),
    ];
    await tester.tap(find.text('Load More'));
    await tester.pumpAndSettle();
    expect(find.text('Latte'), findsOneWidget);
    expect(find.text('Tea'), findsOneWidget);
  });
  testWidgets('unchanged failed availability retry keeps idempotency key', (
    tester,
  ) async {
    final repo = MenuDouble()
      ..writeError = const MenuException(MenuFailure.unavailable);
    await tester.pumpWidget(app(MenuPage(repository: repo)));
    await tester.pumpAndSettle();
    for (var n = 0; n < 2; n++) {
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-confirm')));
      await tester.pumpAndSettle();
    }
    expect(repo.keys.length, 2);
    expect(repo.keys[0], repo.keys[1]);
  });
  testWidgets('session change discards pending list and disposal is safe', (
    tester,
  ) async {
    final repo = MenuDouble()..pending = Completer<MenuItemsPage>();
    await tester.pumpWidget(app(MenuPage(repository: repo)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repo.changes.add(null);
    await tester.pumpAndSettle();
    repo.pending!.complete(MenuItemsPage(repo.items, null));
    await tester.pumpAndSettle();
    expect(find.text('Latte'), findsNothing);
    expect(find.byKey(const ValueKey('menu-error')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Owner form validates price and retains key for unchanged save retry',
    (tester) async {
      final repo = MenuDouble()
        ..writeError = const MenuException(MenuFailure.unavailable);
      await tester.pumpWidget(app(MenuEditPage(repository: repo)));
      await tester.enterText(find.byType(TextFormField).at(0), 'New Latte');
      await tester.enterText(find.byType(TextFormField).at(1), 'Coffee');
      await tester.enterText(find.byType(TextFormField).at(2), '1.001');
      await tester.ensureVisible(find.text('Create Menu Item'));
      await tester.tap(find.text('Create Menu Item'));
      await tester.pumpAndSettle();
      expect(repo.keys, isEmpty);
      await tester.enterText(find.byType(TextFormField).at(2), '12.50');
      for (var n = 0; n < 2; n++) {
        await tester.ensureVisible(find.text('Create Menu Item'));
        await tester.tap(find.text('Create Menu Item'));
        await tester.pumpAndSettle();
      }
      expect(repo.keys.length, 2);
      expect(repo.keys[0], repo.keys[1]);
      await tester.enterText(find.byType(TextFormField).at(2), '13.50');
      await tester.ensureVisible(find.text('Create Menu Item'));
      await tester.tap(find.text('Create Menu Item'));
      await tester.pumpAndSettle();
      expect(repo.keys.last, isNot(repo.keys.first));
    },
  );
  testWidgets(
    'stale edit loads latest values and requires another explicit save',
    (tester) async {
      final repo = MenuDouble()
        ..writeError = const MenuException(MenuFailure.stale)
        ..latest = MenuItem.fromMap({
          ...menuData(version: 2),
          'name': 'Latest Latte',
        });
      await tester.pumpWidget(
        app(MenuEditPage(repository: repo, item: repo.items.first)),
      );
      await tester.ensureVisible(find.text('Save Changes'));
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        'Latest Latte',
      );
      expect(repo.keys.length, 1);
      expect(find.textContaining('Review them and save again'), findsOneWidget);
    },
  );
  testWidgets(
    'stale availability reloads latest list without automatically retrying the write',
    (tester) async {
      final repo = MenuDouble()
        ..role = CafeRole.staff
        ..writeError = const MenuException(MenuFailure.stale);
      repo.onToggle = () => repo.items = [
        MenuItem.fromMap({...menuData(version: 2), 'isAvailable': false}),
      ];
      await tester.pumpWidget(app(MenuPage(repository: repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-confirm')));
      await tester.pumpAndSettle();
      expect(repo.toggles, 1);
      expect(repo.lists, 2);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
      );
    },
  );
  testWidgets('load-more failure preserves cards and retries the same page', (
    tester,
  ) async {
    final repo = MenuDouble()..next = 'next';
    await tester.pumpWidget(app(MenuPage(repository: repo)));
    await tester.pumpAndSettle();
    repo.listError = const MenuException(MenuFailure.unavailable);
    await tester.ensureVisible(find.text('Load More'));
    await tester.tap(find.text('Load More'));
    await tester.pumpAndSettle();
    expect(find.text('Latte'), findsOneWidget);
    expect(find.text('Retry Load More'), findsOneWidget);
    repo.listError = null;
    repo.next = null;
    repo.items = [
      MenuItem.fromMap({...menuData(id: 'tea'), 'name': 'Tea'}),
    ];
    await tester.ensureVisible(find.text('Retry Load More'));
    await tester.tap(find.text('Retry Load More'));
    await tester.pumpAndSettle();
    expect(find.text('Latte'), findsOneWidget);
    expect(find.text('Tea'), findsOneWidget);
  });
  testWidgets(
    'Owner add form returns to the menu and refreshes after success',
    (tester) async {
      final repo = MenuDouble();
      await tester.pumpWidget(app(MenuPage(repository: repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'New Latte');
      await tester.enterText(find.byType(TextFormField).at(1), 'Coffee');
      await tester.enterText(find.byType(TextFormField).at(2), '12.50');
      await tester.ensureVisible(find.text('Create Menu Item'));
      await tester.tap(find.text('Create Menu Item'));
      await tester.pumpAndSettle();
      expect(repo.keys.length, 1);
      expect(repo.lists, 2);
      expect(find.byType(TextFormField), findsNothing);
    },
  );
  for (final width in [320.0, 393.0, 768.0, 1280.0]) {
    testWidgets('Menu fits $width at 2x text', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(MenuPage(repository: MenuDouble()), scale: 2),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
