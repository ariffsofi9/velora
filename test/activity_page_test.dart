import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/workspace_activity.dart';
import 'package:velora/repositories/workspace_activity_repository.dart';
import 'package:velora/screens/activity/activity_page.dart';
import 'package:velora/screens/home/widgets_home/recent_activity_card.dart';
import 'package:velora/services/workspace_session.dart';

WorkspaceSession _session(String cafeId) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafeId,
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

WorkspaceActivity _activity(
  String id, {
  WorkspaceActivityType type = WorkspaceActivityType.inventoryCreated,
  String cafeId = 'cafe-a',
}) => WorkspaceActivity(
  id: id,
  cafeId: cafeId,
  itemId: 'item-a',
  actorUid: 'staff-a',
  type: type,
  createdAt: DateTime.utc(2030, 1, 2, 3, 4),
  itemName: type == WorkspaceActivityType.inventoryCreated ? 'Milk' : null,
  quantity: type == WorkspaceActivityType.inventoryUpdated ? null : 2,
  unit: type == WorkspaceActivityType.inventoryUpdated ? null : 'L',
  direction: type == WorkspaceActivityType.inventoryStockAdjusted
      ? 'out'
      : null,
  previousQuantity: type == WorkspaceActivityType.inventoryStockAdjusted
      ? 5
      : null,
  resultingQuantity: type == WorkspaceActivityType.inventoryStockAdjusted
      ? 3
      : null,
  changedFields: type == WorkspaceActivityType.inventoryUpdated
      ? const ['name']
      : const [],
  updated: type == WorkspaceActivityType.inventoryUpdated ? true : null,
  reason: null,
);

class _Reader implements WorkspaceActivityReader {
  final List<Object> outcomes;
  int calls = 0;
  _Reader(this.outcomes);

  @override
  Future<WorkspaceActivityPage> getActivities({
    WorkspaceActivityCursor? cursor,
  }) async {
    calls++;
    final outcome = outcomes.removeAt(0);
    if (outcome is Future<WorkspaceActivityPage>) return outcome;
    if (outcome is WorkspaceActivityPage) return outcome;
    throw outcome;
  }
}

class _CursorSource implements WorkspaceActivityDataSource {
  @override
  Future<List<WorkspaceActivityDocument>> fetchPage({
    required String path,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) async => List.generate(
    20,
    (index) => WorkspaceActivityDocument(
      id: 'page-$index',
      cursorToken: 'cursor-$index',
      data: {
        'cafeId': 'cafe-a',
        'itemId': 'item-a',
        'actorUid': 'staff-a',
        'type': 'inventory_created',
        'itemName': 'Item $index',
        'quantity': index,
        'unit': 'pcs',
        'requestHash': 'request-$index',
        'schemaVersion': 1,
        'createdAt': DateTime.utc(2030).subtract(Duration(minutes: index)),
      },
    ),
  );
}

Widget _app(Widget home) => MaterialApp(theme: AppTheme.light, home: home);

void main() {
  testWidgets('renders supported events with honest details and actor label', (
    tester,
  ) async {
    final reader = _Reader([
      WorkspaceActivityPage(
        activities: [
          _activity('created'),
          _activity('updated', type: WorkspaceActivityType.inventoryUpdated),
          _activity(
            'stock',
            type: WorkspaceActivityType.inventoryStockAdjusted,
          ),
        ],
      ),
    ]);

    await tester.pumpWidget(
      _app(
        ActivityPage(
          workspaceSession: _session('cafe-a'),
          activityReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Item Created'), findsOneWidget);
    expect(find.text('Milk • 2 L'), findsOneWidget);
    expect(find.text('Item Updated'), findsOneWidget);
    expect(find.textContaining('Inventory item updated'), findsOneWidget);
    expect(find.text('Stock Out'), findsOneWidget);
    expect(find.textContaining('−2 L'), findsOneWidget);
    expect(find.textContaining('You •'), findsNWidgets(3));
  });

  testWidgets('shows empty, sanitized error and safe retry states', (
    tester,
  ) async {
    final reader = _Reader([
      const WorkspaceActivityException(WorkspaceActivityFailure.unavailable),
      const WorkspaceActivityPage(activities: []),
    ]);
    await tester.pumpWidget(
      _app(
        ActivityPage(
          workspaceSession: _session('cafe-a'),
          activityReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('activity-error')), findsOneWidget);
    expect(find.textContaining('offline details'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-empty')), findsOneWidget);
    expect(reader.calls, 2);
  });

  testWidgets('cafe switch clears stale in-flight results and cursor state', (
    tester,
  ) async {
    final pending = Completer<WorkspaceActivityPage>();
    final firstReader = _Reader([pending.future]);
    final secondReader = _Reader([
      WorkspaceActivityPage(
        activities: [_activity('cafe-b', cafeId: 'cafe-b')],
      ),
    ]);

    await tester.pumpWidget(
      _app(
        ActivityPage(
          workspaceSession: _session('cafe-a'),
          activityReader: firstReader,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      _app(
        ActivityPage(
          workspaceSession: _session('cafe-b'),
          activityReader: secondReader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-cafe-b')), findsOneWidget);

    pending.complete(
      WorkspaceActivityPage(activities: [_activity('stale-cafe-a')]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-stale-cafe-a')), findsNothing);
    expect(find.byKey(const ValueKey('activity-cafe-b')), findsOneWidget);
  });

  testWidgets(
    'load-more failure preserves records and retry appends older data',
    (tester) async {
      final firstPage = await WorkspaceActivityRepository(
        session: _session('cafe-a'),
        dataSource: _CursorSource(),
      ).getActivities();
      final reader = _Reader([
        firstPage,
        const WorkspaceActivityException(WorkspaceActivityFailure.unavailable),
        WorkspaceActivityPage(activities: [_activity('older')]),
      ]);

      await tester.pumpWidget(
        _app(
          ActivityPage(
            workspaceSession: _session('cafe-a'),
            activityReader: reader,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('activity-page-0')), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('activity-load-more')),
        500,
        scrollable: find.byType(Scrollable),
      );
      await tester.tap(find.byKey(const ValueKey('activity-load-more')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('activity-page-0')),
        -500,
        scrollable: find.byType(Scrollable),
      );
      expect(find.byKey(const ValueKey('activity-page-0')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('activity-load-more-error')),
        500,
        scrollable: find.byType(Scrollable),
      );
      expect(
        find.byKey(const ValueKey('activity-load-more-error')),
        findsOneWidget,
      );

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('activity-older')), findsOneWidget);
      expect(reader.calls, 3);
    },
  );

  testWidgets('dashboard entry action remains explicit and functional', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      _app(Scaffold(body: RecentActivityCard(onViewAll: () => opened = true))),
    );

    await tester.tap(find.text('View All'));
    expect(opened, isTrue);
    expect(
      find.text('Open Activity to view your workspace inventory history.'),
      findsOneWidget,
    );
  });
}
