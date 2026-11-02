import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart' hide Type;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/dashboard/dashboard_page.dart';
import 'package:velora/screens/home/widgets_home/bottom_bar.dart';
import 'package:velora/screens/home/widgets_home/recent_activity_card.dart';
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
      final stream = StreamController<List<WorkspaceInventoryDocument>>();
      final db = dashboardFirestore();
      await tester.pumpWidget(
        app(
          DashboardPage(
            workspaceSession: dashboardSession,
            inventoryRepository: dashboardInventoryRepository(
              stream: stream.stream,
            ),
            firestore: db,
            onCheckNotifications: () {},
          ),
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
  testWidgets('Scoped inventory uses the shared low-stock threshold', (
    tester,
  ) async {
    final db = dashboardFirestore();
    await tester.pumpWidget(
      app(
        DashboardPage(
          workspaceSession: dashboardSession,
          inventoryRepository: dashboardInventoryRepository(),
          firestore: db,
          onCheckNotifications: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('total-count'))).data,
      '6',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('near-expiry-count'))).data,
      '2',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('low-stock-count'))).data,
      '5',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('expired-count'))).data,
      '1',
    );
    await tester.scrollUntilVisible(find.text('Recent Activity'), 250);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Recent activity is unavailable until secure workspace activity is enabled.',
      ),
      findsOneWidget,
    );
    final query = db.collections['inventory_records']!;
    expect(query.calls, isEmpty);
  });

  testWidgets('Dashboard reads only the verified cafe inventory path', (
    tester,
  ) async {
    final source = DashboardInventorySource(
      Stream.value([
        WorkspaceInventoryDocument(
          id: 'milk-a',
          data: {
            'name': 'Milk',
            'category': 'Dairy',
            'quantity': 2,
            'unit': 'L',
            'expiryDate': DateTime.now().add(const Duration(days: 2)),
            'imageUrl': '',
            'createdAt': DateTime.now(),
          },
        ),
      ]),
    );
    final repository = WorkspaceInventoryRepository(
      session: dashboardSession,
      dataSource: source,
    );

    await tester.pumpWidget(
      app(
        DashboardPage(
          workspaceSession: dashboardSession,
          inventoryRepository: repository,
          firestore: dashboardFirestore(),
          onCheckNotifications: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(source.watchedPath, 'cafes/dashboard-cafe/inventory');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('total-count'))).data,
      '1',
    );
  });

  final destinations = <String, Type>{'AI Suggestions': SuggestionsPage};
  for (final entry in destinations.entries) {
    testWidgets('${entry.key} keeps its production navigation destination', (
      tester,
    ) async {
      final observer = _RouteObserver();
      await tester.pumpWidget(
        app(
          DashboardPage(
            workspaceSession: dashboardSession,
            inventoryRepository: dashboardInventoryRepository(),
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

  testWidgets('inventory, add and alerts use the trusted Home callbacks', (
    tester,
  ) async {
    var addTaps = 0;
    var inventoryTaps = 0;
    var alertTaps = 0;
    await tester.pumpWidget(
      app(
        DashboardPage(
          workspaceSession: dashboardSession,
          inventoryRepository: dashboardInventoryRepository(),
          firestore: dashboardFirestore(),
          onCheckNotifications: () {},
          onAddTap: () => addTaps++,
          onInventoryTap: () => inventoryTaps++,
          onAlertTap: () => alertTaps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Item'));
    await tester.tap(find.text('Inventory'));
    await tester.tap(find.text('Alerts'));

    expect(addTaps, 1);
    expect(inventoryTaps, 1);
    expect(alertTaps, 1);
  });

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
                  workspaceSession: dashboardSession,
                  inventoryRepository: dashboardInventoryRepository(),
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
    await tester.pumpWidget(
      app(Scaffold(body: RecentActivityCard(activityStream: stream.stream))),
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
