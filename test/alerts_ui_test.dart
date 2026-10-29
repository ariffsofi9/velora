import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/alerts/alerts_page.dart';
import 'package:velora/screens/notifications/notification_alert_item.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_alert_card.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_empty_view.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_filter_bar.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_header_card.dart';

import 'dashboard_test_fakes.dart';

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

  testWidgets('Named Alerts route preserves existing inventory thresholds', (
    tester,
  ) async {
    final today = DateTime.now();
    final firestore = DashboardFirestore({
      'inventory': dashboardCollection([
        {
          'id': 'low',
          'name': 'Coffee Beans',
          'quantity': 5,
          'expiryDate': Timestamp.fromDate(today.add(const Duration(days: 20))),
        },
        {
          'id': 'expiry',
          'name': 'Fresh Milk',
          'quantity': 12,
          'expiryDate': Timestamp.fromDate(today.add(const Duration(days: 2))),
        },
        {
          'id': 'healthy',
          'name': 'Rice',
          'quantity': 20,
          'expiryDate': Timestamp.fromDate(today.add(const Duration(days: 20))),
        },
      ]),
    });
    await tester.pumpWidget(app(AlertsPage(firestore: firestore)));
    await tester.pump();

    expect(find.text('Coffee Beans'), findsOneWidget);
    expect(find.text('Fresh Milk'), findsOneWidget);
    expect(find.text('Rice'), findsNothing);

    await tester.tap(find.text('Near Expiry'));
    await tester.pump();
    expect(find.text('Coffee Beans'), findsNothing);
    expect(find.text('Fresh Milk'), findsOneWidget);
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
