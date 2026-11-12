import 'dart:async';
import 'package:velora/widgets/dashboard/dashboard_header.dart';
import 'package:velora/repositories/workspace_activity_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_session.dart';
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

class _DiscoverInventorySource implements WorkspaceInventoryDataSource {
  final paths = <String>[];

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    paths.add(path);
    return Stream.value(const []);
  }

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw UnimplementedError();
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
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final entry in <String?, String>{
    'ariff sofi': 'ariff sofi',
    'Nur Aisyah Ahmad': 'Nur Aisyah Ahmad',
    '  ariff sofi  ': 'ariff sofi',
    '': 'Welcome back',
    '   ': 'Welcome back',
    null: 'Welcome back',
  }.entries) {
    testWidgets(
      'Dashboard greeting preserves full name or fallback: ${entry.key}',
      (tester) async {
        await tester.pumpWidget(
          app(
            DashboardHeader(
              firstName: entry.key,
              notificationBell: const SizedBox.shrink(),
            ),
          ),
        );
        expect(find.text(entry.value), findsOneWidget);
        if (entry.value == 'ariff sofi') {
          expect(find.text('ariff'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
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
    expect(find.text('Recent activity cannot load right now.'), findsOneWidget);
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

  testWidgets(
    'AI shortcut builds Discover with the original verified context',
    (tester) async {
      final source = _DiscoverInventorySource();
      final repository = WorkspaceInventoryRepository(
        session: dashboardSession,
        dataSource: source,
      );
      final observer = _RouteObserver();
      await tester.pumpWidget(
        app(
          DashboardPage(
            workspaceSession: dashboardSession,
            inventoryRepository: repository,
            firestore: dashboardFirestore(),
            onCheckNotifications: () {},
          ),
          observer: observer,
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('AI Suggestions'), 150);
      await tester.ensureVisible(find.text('AI Suggestions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI Suggestions'));
      await tester.pumpAndSettle();
      final destination = tester.widget<SuggestionsPage>(
        find.byType(SuggestionsPage),
      );
      expect(destination.workspaceSession, same(dashboardSession));
      expect(destination.repository, same(repository));
      expect(destination.aiService, isNull);
      expect(repository.collectionPath, 'cafes/dashboard-cafe/inventory');
      expect(source.paths, [
        'cafes/dashboard-cafe/inventory',
        'cafes/dashboard-cafe/inventory',
      ]);
      expect(
        find.text('Add inventory items first to get AI insights.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final invalidated in [false, true]) {
    testWidgets(
      'AI shortcut rejects ${invalidated ? 'invalidated' : 'mismatched'} context',
      (tester) async {
        final session = WorkspaceSession.fromVerified(
          const CafeWorkspace(
            cafeId: 'dashboard-cafe',
            uid: 'owner-a',
            ownerUid: 'owner-a',
            role: CafeRole.owner,
          ),
        );
        final repository = WorkspaceInventoryRepository(
          session: invalidated ? session : dashboardSession,
          dataSource: DashboardInventorySource(Stream.value(const [])),
        );
        final observer = _RouteObserver();
        await tester.pumpWidget(
          app(
            DashboardPage(
              workspaceSession: session,
              inventoryRepository: repository,
              firestore: dashboardFirestore(),
            ),
            observer: observer,
          ),
        );
        await tester.pumpAndSettle();
        final initialRoute = observer.latest;
        if (invalidated) session.invalidate();
        await tester.scrollUntilVisible(find.text('AI Suggestions'), 150);
        await tester.ensureVisible(find.text('AI Suggestions'));
        await tester.tap(find.text('AI Suggestions'));
        await tester.pumpAndSettle();
        expect(observer.latest, same(initialRoute));
        expect(find.byType(SuggestionsPage), findsNothing);
        expect(
          find.text('Workspace access could not be verified.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('inventory, add and alerts use the trusted Home callbacks', (
    tester,
  ) async {
    var addTaps = 0;
    var inventoryTaps = 0;
    var alertTaps = 0;
    var activityTaps = 0;
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
          onActivityTap: () => activityTaps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Item'));
    await tester.tap(find.text('Inventory'));
    await tester.tap(find.text('Alerts'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('open-activity')),
      250,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('open-activity')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-activity')));

    expect(addTaps, 1);
    expect(inventoryTaps, 1);
    expect(alertTaps, 1);
    expect(activityTaps, 1);
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

  testWidgets(
    'Recent Activity loads an empty scoped first page and retries errors',
    (tester) async {
      final source = _ActivitySource();
      final session = _activitySession();
      final repository = WorkspaceActivityRepository(
        session: session,
        dataSource: source,
      );
      await tester.pumpWidget(
        app(
          Scaffold(
            body: RecentActivityCard(
              workspaceSession: session,
              activityRepository: repository,
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(source.paths, ['cafes/dashboard-cafe/activities']);
      source.pending.removeAt(0).completeError(StateError('private error'));
      await tester.pumpAndSettle();
      expect(
        find.text('Recent activity cannot load right now.'),
        findsOneWidget,
      );
      expect(find.textContaining('private error'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      source.pending.removeAt(0).complete([]);
      await tester.pumpAndSettle();
      expect(find.text('No stock activity yet.'), findsOneWidget);
      expect(source.paths.length, 2);
    },
  );

  testWidgets('Dashboard injects canonical activity without global reads', (
    tester,
  ) async {
    final source = _ActivitySource();
    await tester.pumpWidget(
      app(
        DashboardPage(
          workspaceSession: dashboardSession,
          inventoryRepository: dashboardInventoryRepository(),
          firestore: dashboardFirestore(),
          activityRepository: WorkspaceActivityRepository(
            session: dashboardSession,
            dataSource: source,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Recent Activity'), 250);
    source.pending.removeAt(0).complete([_activityDocument('created', 1)]);
    await tester.pumpAndSettle();
    expect(find.text('Item Created'), findsOneWidget);
    expect(find.text('Milk created added to inventory'), findsOneWidget);
    expect(source.paths, ['cafes/dashboard-cafe/activities']);
    expect(source.limits, [20]);
    expect(source.descending, [true]);
    expect(source.cursors, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('canonical events sort newest first and display at most 20', (
    tester,
  ) async {
    final source = _ActivitySource();
    final session = _activitySession();
    await tester.pumpWidget(
      app(
        Scaffold(
          body: SingleChildScrollView(
            child: RecentActivityCard(
              workspaceSession: session,
              activityRepository: WorkspaceActivityRepository(
                session: session,
                dataSource: source,
              ),
            ),
          ),
        ),
      ),
    );
    final types = [
      'inventory_created',
      'inventory_updated',
      'inventory_update_noop',
      'inventory_stock_adjusted',
      'inventory_archived',
      'inventory_restored',
    ];
    source.pending
        .removeAt(0)
        .complete(
          List.generate(
            25,
            (i) => _activityDocument('$i', i, type: types[i % types.length]),
          ),
        );
    await tester.pumpAndSettle();
    final rows = tester
        .widgetList<Container>(
          find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith('recent-'),
          ),
        )
        .toList();
    expect(rows.length, 20);
    expect(rows.first.key, const ValueKey('recent-24'));
    expect(rows.last.key, const ValueKey('recent-5'));
    for (final title in [
      'Item Created',
      'Item Updated',
      'Update Checked',
      'Stock Out',
      'Item Archived',
      'Item Restored',
    ]) {
      expect(find.text(title), findsWidgets);
    }
    expect(source.paths.length, 1);
    expect(find.text('Load More'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final replacement in ['account', 'workspace', 'generation']) {
    testWidgets(
      '$replacement replacement suppresses late results and clears rendered activity',
      (tester) async {
        final source = _ActivitySource();
        final first = _activitySession();
        Widget card(WorkspaceSession session) => app(
          Scaffold(
            body: RecentActivityCard(
              workspaceSession: session,
              activityRepository: WorkspaceActivityRepository(
                session: session,
                dataSource: source,
              ),
            ),
          ),
        );
        await tester.pumpWidget(card(first));
        final late = source.pending.removeAt(0);
        final second = _activitySession(
          cafe: replacement == 'workspace' ? 'other-cafe' : 'dashboard-cafe',
          uid: replacement == 'account' ? 'other-user' : 'owner-a',
          generation: replacement == 'generation' ? 2 : 1,
        );
        await tester.pumpWidget(card(second));
        source.pending.removeAt(0).complete([
          _activityDocument('fresh', 2, cafe: second.cafeId),
        ]);
        await tester.pumpAndSettle();
        late.complete([_activityDocument('stale', 1)]);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('recent-fresh')), findsOneWidget);
        expect(find.byKey(const ValueKey('recent-stale')), findsNothing);
        await tester.pumpWidget(card(_activitySession()));
        expect(find.byKey(const ValueKey('recent-fresh')), findsNothing);
        source.pending.removeAt(0).complete([]);
        await tester.pumpAndSettle();
      },
    );
  }

  for (final populated in [false, true]) {
    testWidgets(
      'invalidated session rejects ${populated ? 'rendered' : 'pending'} activity',
      (tester) async {
        final source = _ActivitySource();
        final session = _activitySession();
        final repository = WorkspaceActivityRepository(
          session: session,
          dataSource: source,
        );
        Widget card() => app(
          Scaffold(
            body: RecentActivityCard(
              workspaceSession: session,
              activityRepository: repository,
            ),
          ),
        );
        await tester.pumpWidget(card());
        final pending = source.pending.removeAt(0);
        if (populated) {
          pending.complete([_activityDocument('old', 1)]);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('recent-old')), findsOneWidget);
        }
        session.invalidate();
        if (!populated) pending.complete([_activityDocument('old', 1)]);
        await tester.pumpWidget(card());
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('recent-old')), findsNothing);
        expect(
          find.text('Recent activity cannot load right now.'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsNothing);
      },
    );
  }

  testWidgets(
    'Dashboard session replacement rebinds repositories and discards its old card',
    (tester) async {
      final source = _ActivitySource();
      Widget dashboard(WorkspaceSession session) => app(
        DashboardPage(
          workspaceSession: session,
          inventoryRepository: WorkspaceInventoryRepository(
            session: session,
            dataSource: DashboardInventorySource(Stream.value(const [])),
          ),
          activityRepository: WorkspaceActivityRepository(
            session: session,
            dataSource: source,
          ),
          firestore: dashboardFirestore(),
        ),
      );
      await tester.pumpWidget(dashboard(_activitySession()));
      await tester.pump();
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Recent Activity'), 250);
      final late = source.pending.removeAt(0);
      await tester.pumpWidget(
        dashboard(_activitySession(cafe: 'other-cafe', uid: 'other-user')),
      );
      await tester.pump();
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Recent Activity'), 250);
      source.pending.removeAt(0).complete([
        _activityDocument('new', 2, cafe: 'other-cafe'),
      ]);
      await tester.pumpAndSettle();
      late.complete([_activityDocument('old', 1)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recent-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('recent-old')), findsNothing);
      expect(source.paths, [
        'cafes/dashboard-cafe/activities',
        'cafes/other-cafe/activities',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mismatched repository and cross-cafe records fail closed', (
    tester,
  ) async {
    final source = _ActivitySource();
    final session = _activitySession();
    final repository = WorkspaceActivityRepository(
      session: session,
      dataSource: source,
    );
    await tester.pumpWidget(
      app(
        Scaffold(
          body: RecentActivityCard(
            workspaceSession: _activitySession(),
            activityRepository: repository,
          ),
        ),
      ),
    );
    expect(source.paths, isEmpty);
    expect(find.text('Recent activity cannot load right now.'), findsOneWidget);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: RecentActivityCard(
            workspaceSession: session,
            activityRepository: repository,
          ),
        ),
      ),
    );
    source.pending.removeAt(0).complete([
      _activityDocument('wrong', 1, cafe: 'other'),
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recent-wrong')), findsNothing);
    expect(find.text('Recent activity cannot load right now.'), findsOneWidget);
  });
}

WorkspaceSession _activitySession({
  String cafe = 'dashboard-cafe',
  String uid = 'owner-a',
  int generation = 1,
}) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafe,
    uid: uid,
    ownerUid: 'owner-a',
    role: CafeRole.staff,
    membershipGeneration: generation,
  ),
);

class _ActivitySource implements WorkspaceActivityDataSource {
  final paths = <String>[];
  final limits = <int>[];
  final descending = <bool>[];
  final cursors = <Object?>[];
  final pending = <Completer<List<WorkspaceActivityDocument>>>[];
  @override
  Future<List<WorkspaceActivityDocument>> fetchPage({
    required String path,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) {
    paths.add(path);
    limits.add(limit);
    this.descending.add(descending);
    cursors.add(startAfter);
    final result = Completer<List<WorkspaceActivityDocument>>();
    pending.add(result);
    return result.future;
  }
}

WorkspaceActivityDocument _activityDocument(
  String id,
  int minute, {
  String cafe = 'dashboard-cafe',
  String type = 'inventory_created',
}) => WorkspaceActivityDocument(
  id: id,
  cursorToken: id,
  data: {
    'schemaVersion': 1,
    'cafeId': cafe,
    'itemId': 'item-a',
    'actorUid': 'owner-a',
    'type': type,
    'createdAt': DateTime.utc(2026, 1, 1, 0, minute),
    'requestHash': 'hash-$id',
    'itemName': 'Milk $id',
    'quantity': 2,
    'unit': 'L',
    'direction': 'out',
    'previousQuantity': 5,
    'resultingQuantity': 3,
    'fromVersion': 1,
    'resultVersion': type == 'inventory_update_noop' ? 1 : 2,
    'changedFields': ['name'],
    'updated': type != 'inventory_update_noop',
    'fromState': type == 'inventory_archived' ? 'active' : 'archived',
    'resultState': type == 'inventory_archived' ? 'archived' : 'active',
    'preservedQuantity': 3,
  },
);
