import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart' hide Type;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/dashboard/dashboard_page.dart';
import 'package:velora/screens/home/widgets_home/bottom_bar.dart';
import 'package:velora/screens/home/widgets_home/recent_activity_card.dart';
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
import 'package:velora/screens/notifications/notification_page.dart';
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'dashboard_test_fakes.dart';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      latest = route;
}

Widget app(Widget child, {double scale = 1, NavigatorObserver? observer}) =>
    MaterialApp(
      theme: AppTheme.light,
      navigatorObservers: [?observer],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );

void main() {
  testWidgets(
    'Loading and failed inventory stay readable at compact size and 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final stream = StreamController<QuerySnapshot<Map<String, dynamic>>>();
      final db = DashboardFirestore({
        'inventory': DashboardCollection(stream.stream),
      });
      await tester.pumpWidget(
        app(
          DashboardPage(firestore: db, onCheckNotifications: () {}),
          scale: 2,
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      stream.addError(StateError('offline'));
      await tester.pump();
      expect(find.text('Inventory health unavailable'), findsOneWidget);
      expect(find.byKey(const ValueKey('total-count')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      unawaited(stream.close());
    },
  );
  testWidgets(
    'Live inventory thresholds, unread alerts and activity query are preserved',
    (tester) async {
      final db = dashboardFirestore();
      await tester.pumpWidget(
        app(DashboardPage(firestore: db, onCheckNotifications: () {})),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('total-count'))).data,
        '6',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('near-expiry-count')))
            .data,
        '3',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('low-stock-count'))).data,
        '4',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('expired-count'))).data,
        '1',
      );
      expect(find.text('2'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Recent Activity'), 250);
      await tester.pumpAndSettle();
      expect(find.text('Stock In'), findsOneWidget);
      expect(find.text('Milk added to inventory'), findsOneWidget);
      expect(find.text('5 min ago'), findsOneWidget);
      expect(find.text('Stock Out'), findsOneWidget);
      expect(find.textContaining('2 used'), findsOneWidget);
      expect(find.text('2 hours ago'), findsOneWidget);
      final query = db.collections['inventory_records']!;
      expect(query.orderedField, 'createdAt');
      expect(query.descending, isTrue);
      expect(query.queryLimit, 4);
    },
  );

  final destinations = <String, Type>{
    'Add Item': AddItemPage,
    'Inventory': InventoryPage,
    'AI Suggestions': SuggestionsPage,
    'Alerts': NotificationPage,
  };
  for (final entry in destinations.entries) {
    testWidgets('${entry.key} keeps its production navigation destination', (
      tester,
    ) async {
      final observer = _RouteObserver();
      await tester.pumpWidget(
        app(
          DashboardPage(
            firestore: dashboardFirestore(),
            onCheckNotifications: () {},
          ),
          observer: observer,
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(entry.key), 150);
      await tester.ensureVisible(find.text(entry.key));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      final route = observer.latest! as MaterialPageRoute<dynamic>;
      final context = tester.element(find.byType(DashboardPage));
      // Inspect the real route without building a destination that needs Firebase.
      expect(route.builder(context).runtimeType, entry.value);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final width in [320.0, 393.0, 768.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Dashboard and navigation fit width $width at text scale $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final taps = <int>[];
          await tester.pumpWidget(
            app(
              Scaffold(
                body: DashboardPage(
                  firestore: dashboardFirestore(),
                  onCheckNotifications: () {},
                ),
                bottomNavigationBar: VeloraBottomBar(
                  currentIndex: 0,
                  onTap: taps.add,
                ),
              ),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(find.text('Recent Activity'), 250);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final label in ['Home', 'Inventory', 'AI Tips', 'Profile']) {
            await tester.tap(
              find.descendant(
                of: find.byType(VeloraBottomBar),
                matching: find.text(label),
              ),
            );
          }
          await tester.tap(
            find.descendant(
              of: find.byType(VeloraBottomBar),
              matching: find.bySemanticsLabel('Add Item'),
            ),
          );
          expect(taps, [0, 1, 3, 4, 2]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Recent Activity shows loading, empty and error feedback', (
    tester,
  ) async {
    final stream = StreamController<QuerySnapshot<Map<String, dynamic>>>();
    final db = DashboardFirestore({
      'inventory_records': DashboardCollection(stream.stream),
    });
    await tester.pumpWidget(
      app(Scaffold(body: RecentActivityCard(firestore: db))),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    stream.add(DashboardSnapshot([]));
    await tester.pump();
    expect(find.text('No stock activity yet.'), findsOneWidget);
    stream.addError(StateError('offline'));
    await tester.pump();
    expect(find.text('Recent activity cannot load right now.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    unawaited(stream.close());
  });
}
