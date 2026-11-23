import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/logic/low_stock_policy.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/alerts/alerts_page.dart';
import 'package:velora/screens/inventory/item_details_page.dart';
import 'package:velora/screens/home/widgets_home/notification_bell.dart';
import 'package:velora/screens/notifications/notification_alert_item.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_alert_card.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_empty_view.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_filter_bar.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_header_card.dart';
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

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'alerts-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

WorkspaceInventoryDocument _item(
  String id,
  String name,
  int quantity,
  int expiryDays,
) => WorkspaceInventoryDocument(
  id: id,
  data: {
    'name': name,
    'category': 'General',
    'quantity': quantity,
    'unit': 'pcs',
    'expiryDate': DateTime.now().add(Duration(days: expiryDays)),
    'imageUrl': '',
    'createdAt': DateTime.now(),
  },
);

AlertsPage _alerts(_InventorySource source) => AlertsPage(
  workspaceSession: _session,
  repository: WorkspaceInventoryRepository(
    session: _session,
    dataSource: source,
  ),
);

void main() {
  final alert = NotificationAlertItem(
    id: 'low-stock-milk',
    title: 'Low Stock',
    message: 'Milk is running low. Only 2 left.',
    type: AlertType.stock,
    priority: AlertPriority.medium,
    isRead: false,
    isDismissed: false,
    createdAt: DateTime(2030),
  );

  Widget app(Widget child, {double scale = 1}) => MaterialApp(
    theme: AppTheme.light,
    builder: (context, screen) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: screen!,
    ),
    home: Scaffold(body: child),
  );

  testWidgets('Alert filters expose only supported alert groups', (
    tester,
  ) async {
    var selected = 'All';
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) => NotificationFilterBar(
            selected: selected,
            onSelected: (value) => setState(() => selected = value),
          ),
        ),
      ),
    );

    expect(find.text('All'), findsOneWidget);
    expect(find.text('Low Stock'), findsOneWidget);
    expect(find.text('Near Expiry'), findsOneWidget);
    expect(find.text('Expired'), findsNothing);

    await tester.tap(find.text('Low Stock'));
    await tester.pump();
    expect(selected, 'Low Stock');
  });

  testWidgets('Scoped Alerts use the shared low-stock threshold', (
    tester,
  ) async {
    final source = _InventorySource(
      Stream.value([
        _item('low', 'Coffee Beans', 5, 20),
        _item('above', 'Tea Leaves', 6, 20),
        _item('expiry', 'Fresh Milk', 12, 2),
        _item('healthy', 'Rice', 20, 20),
      ]),
    );
    await tester.pumpWidget(app(_alerts(source)));
    await tester.pump();

    expect(source.watchedPath, 'cafes/alerts-cafe/inventory');
    expect(find.text('Coffee Beans'), findsOneWidget);
    expect(find.text('Fresh Milk'), findsOneWidget);
    expect(find.text('Tea Leaves'), findsNothing);
    expect(find.text('Rice'), findsNothing);

    await tester.tap(find.text('Near Expiry'));
    await tester.pump();
    expect(find.text('Coffee Beans'), findsNothing);
    expect(find.text('Fresh Milk'), findsOneWidget);
  });

  testWidgets('Empty cafe shows normal no-alerts guidance', (tester) async {
    await tester.pumpWidget(
      app(_alerts(_InventorySource(Stream.value(const [])))),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('No active alerts.\nYour inventory looks good.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'stock alert drill-down uses the original item and verified workspace',
    (tester) async {
      final source = _InventorySource(
        Stream.value([
          _item('out', 'Coffee', 0, 20),
          _item('low', 'Coffee', 5, 20),
        ]),
      );
      final repository = WorkspaceInventoryRepository(
        session: _session,
        dataSource: source,
      );
      await tester.pumpWidget(
        app(
          AlertsPage(
            workspaceSession: _session,
            repository: repository,
            initialStockAttention: StockAttention.outOfStock,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final selected = find.byKey(const ValueKey('inventory-alert-out'));
      expect(selected, findsOneWidget);
      expect(find.byKey(const ValueKey('inventory-alert-low')), findsNothing);
      expect(find.text('Out of stock'), findsOneWidget);
      await tester.tap(selected);
      await tester.pumpAndSettle();
      final details = tester.widget<ItemDetailsPage>(
        find.byType(ItemDetailsPage),
      );
      expect(details.item.id, 'out');
      expect(details.repository, same(repository));
      expect(details.workspaceSession, same(_session));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Low Stock'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inventory-alert-low')), findsOneWidget);
      expect(selected, findsNothing);
    },
  );

  testWidgets(
    'replaced alert sessions hide stale rows and denial clears current stock',
    (tester) async {
      final oldUpdates = StreamController<List<WorkspaceInventoryDocument>>();
      final newUpdates = StreamController<List<WorkspaceInventoryDocument>>();
      addTearDown(oldUpdates.close);
      addTearDown(newUpdates.close);
      final nextWorkspace = WorkspaceSession.fromVerified(
        const CafeWorkspace(
          cafeId: 'new-cafe',
          uid: 'staff-b',
          ownerUid: 'owner-b',
          role: CafeRole.staff,
        ),
      );
      final oldSource = _InventorySource(oldUpdates.stream);
      final newSource = _InventorySource(newUpdates.stream);
      Future<void> show(WorkspaceSession workspace, _InventorySource source) =>
          tester.pumpWidget(
            app(
              AlertsPage(
                workspaceSession: workspace,
                repository: WorkspaceInventoryRepository(
                  session: workspace,
                  dataSource: source,
                ),
              ),
            ),
          );
      await show(_session, oldSource);
      oldUpdates.add([_item('old', 'Previous café item', 0, 20)]);
      await tester.pump();
      expect(find.text('Previous café item'), findsOneWidget);
      final oldTap = tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(const ValueKey('inventory-alert-old')),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!;
      await show(nextWorkspace, newSource);
      oldUpdates.add([_item('stale', 'Late previous café item', 1, 20)]);
      newUpdates.add([_item('current', 'Current café item', 2, 20)]);
      await tester.pump();
      expect(find.text('Previous café item'), findsNothing);
      expect(find.text('Late previous café item'), findsNothing);
      expect(find.text('Current café item'), findsOneWidget);
      oldTap();
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailsPage), findsNothing);
      expect(newSource.watchedPath, 'cafes/new-cafe/inventory');
      newUpdates.addError(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Current café item'), findsNothing);
      expect(find.text('Retry alerts'), findsOneWidget);
    },
  );

  testWidgets('Loading and scoped repository errors remain visible', (
    tester,
  ) async {
    final controller = StreamController<List<WorkspaceInventoryDocument>>();
    addTearDown(controller.close);
    await tester.pumpWidget(app(_alerts(_InventorySource(controller.stream))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.addError(StateError('permission denied'));
    await tester.pump();
    expect(find.text('Retry alerts'), findsOneWidget);
  });

  testWidgets('Unverified access and legacy bell actions fail closed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: Column(
            children: [
              Expanded(child: AlertsPage()),
              NotificationBell(),
            ],
          ),
        ),
      ),
    );
    expect(
      find.text(
        'Alerts are unavailable because workspace access was not verified.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Alerts'));
    await tester.pump();
    expect(
      find.textContaining('secure workspace notifications'),
      findsOneWidget,
    );
  });

  testWidgets('Alert card preserves read and dismiss interactions', (
    tester,
  ) async {
    var reads = 0;
    var dismissals = 0;
    var visible = true;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) => visible
              ? NotificationAlertCard(
                  alert: alert,
                  isRead: false,
                  onToggleRead: () => reads++,
                  onDismiss: () {
                    dismissals++;
                    setState(() => visible = false);
                  },
                )
              : const SizedBox.shrink(),
        ),
      ),
    );

    await tester.tap(find.text('Mark read'));
    expect(reads, 1);

    await tester.drag(find.byType(Dismissible), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(dismissals, 1);
  });

  for (final width in [320.0, 393.0, 768.0]) {
    testWidgets('Alert presentation fits $width at 2x text', (tester) async {
      tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        app(
          ListView(
            children: [
              NotificationHeaderCard(total: 1, unread: 1, onReadAll: () {}),
              NotificationFilterBar(selected: 'All', onSelected: (_) {}),
              Padding(
                padding: const EdgeInsets.all(20),
                child: NotificationAlertCard(
                  alert: alert,
                  isRead: false,
                  onToggleRead: () {},
                  onDismiss: () {},
                ),
              ),
              const SizedBox(height: 220, child: NotificationEmptyView()),
            ],
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
