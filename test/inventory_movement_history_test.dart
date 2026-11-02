import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/models/inventory_movement.dart';
import 'package:velora/repositories/workspace_inventory_movement_repository.dart';
import 'package:velora/screens/inventory/item_details_page.dart';
import 'package:velora/screens/inventory/stock/stock_history_page.dart';
import 'package:velora/services/workspace_session.dart';

WorkspaceSession session(String cafeId) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafeId,
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

InventoryItem item(String id, {String name = 'Flour'}) => InventoryItem(
  id: id,
  name: name,
  category: 'Dry Goods',
  quantity: 5,
  unit: 'kg',
  expiryDate: DateTime.utc(2030),
  imageUrl: '',
  createdAt: DateTime.utc(2029),
);

InventoryMovement movement(
  String id,
  InventoryMovementType type, {
  String? reason,
}) {
  final initial = type == InventoryMovementType.initialStock;
  final stockIn = type == InventoryMovementType.stockIn;
  return InventoryMovement(
    id: id,
    cafeId: 'cafe-a',
    itemId: 'item-a',
    actorUid: 'staff-a',
    type: type,
    direction: initial ? null : (stockIn ? 'in' : 'out'),
    quantity: initial ? 5 : 2,
    delta: initial ? null : (stockIn ? 2 : -2),
    previousQuantity: initial ? null : (stockIn ? 3 : 5),
    resultingQuantity: initial ? null : (stockIn ? 5 : 3),
    unit: 'kg',
    reason: reason,
    createdAt: DateTime.utc(2030, 1, 2, 10, 30),
    fromVersion: initial ? null : 1,
    resultVersion: initial ? null : 2,
    requestHash: 'hash-$id',
  );
}

class _Reader implements WorkspaceInventoryMovementReader {
  final List<Object> outcomes;
  final calls = <(String, WorkspaceMovementCursor?)>[];
  _Reader(this.outcomes);

  @override
  Future<WorkspaceMovementPage> getItemMovements(
    String itemId, {
    WorkspaceMovementCursor? cursor,
  }) async {
    calls.add((itemId, cursor));
    final outcome = outcomes.removeAt(0);
    if (outcome is Future<WorkspaceMovementPage>) return outcome;
    if (outcome is WorkspaceMovementPage) return outcome;
    throw outcome;
  }
}

class _CursorSource implements WorkspaceMovementDataSource {
  @override
  Future<List<WorkspaceMovementDocument>> fetchPage({
    required String path,
    required String itemId,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) async => List.generate(
    20,
    (index) => WorkspaceMovementDocument(
      id: 'cursor-$index',
      cursorToken: 'token-$index',
      data: {
        'cafeId': 'cafe-a',
        'itemId': 'item-a',
        'actorUid': 'staff-a',
        'type': 'initial_stock',
        'quantity': 1,
        'unit': 'kg',
        'requestHash': 'hash-$index',
        'schemaVersion': 1,
        'createdAt': DateTime.utc(2030),
      },
    ),
  );
}

Future<WorkspaceMovementCursor> cursor() async {
  final page = await WorkspaceInventoryMovementRepository(
    session: session('cafe-a'),
    dataSource: _CursorSource(),
  ).getItemMovements('item-a');
  return page.nextCursor!;
}

Widget app(Widget child) => MaterialApp(theme: AppTheme.light, home: child);

void main() {
  testWidgets('Stock History navigation uses selected verified item', (
    tester,
  ) async {
    final reader = _Reader([const WorkspaceMovementPage(movements: [])]);
    await tester.pumpWidget(
      app(
        ItemDetailsPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('open-stock-history')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('open-stock-history')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('open-stock-history')));
    await tester.pumpAndSettle();
    expect(find.byType(StockHistoryPage), findsOneWidget);
    expect(reader.calls.single.$1, 'item-a');
    expect(find.text('Stock In'), findsNothing);
  });

  testWidgets('shows initial loading then empty history', (tester) async {
    final pending = Completer<WorkspaceMovementPage>();
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: _Reader([pending.future]),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('stock-history-loading')), findsOneWidget);
    pending.complete(const WorkspaceMovementPage(movements: []));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-history-empty')), findsOneWidget);
  });

  testWidgets('renders movement types, reason, signed values and balances', (
    tester,
  ) async {
    final reader = _Reader([
      WorkspaceMovementPage(
        movements: [
          movement('initial', InventoryMovementType.initialStock),
          movement('in', InventoryMovementType.stockIn, reason: 'Delivery'),
          movement('out', InventoryMovementType.stockOut),
        ],
      ),
    ]);
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Initial Stock'), findsOneWidget);
    expect(find.text('Stock In'), findsOneWidget);
    expect(find.text('Stock Out'), findsOneWidget);
    expect(find.text('+2 kg'), findsOneWidget);
    expect(find.text('−2 kg'), findsOneWidget);
    expect(find.text('Reason: Delivery'), findsOneWidget);
    expect(find.text('Balance: 3 → 5 kg'), findsOneWidget);
  });

  testWidgets('maps permission, unavailable and invalid-data states', (
    tester,
  ) async {
    final cases = {
      WorkspaceMovementFailure.permissionDenied: 'History unavailable',
      WorkspaceMovementFailure.unavailable: 'Unable to load history',
      WorkspaceMovementFailure.invalidData: 'History data is invalid',
    };
    for (final entry in cases.entries) {
      await tester.pumpWidget(
        app(
          StockHistoryPage(
            item: item('item-a'),
            workspaceSession: session('cafe-a'),
            movementReader: _Reader([WorkspaceMovementException(entry.key)]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    }
  });

  testWidgets('initial error can retry without changing scope', (tester) async {
    final reader = _Reader([
      const WorkspaceMovementException(WorkspaceMovementFailure.unavailable),
      WorkspaceMovementPage(
        movements: [movement('initial', InventoryMovementType.initialStock)],
      ),
    ]);
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Initial Stock'), findsOneWidget);
    expect(reader.calls.map((call) => call.$1), everyElement('item-a'));
  });

  testWidgets('load more appends unique records and reaches end', (
    tester,
  ) async {
    final next = await cursor();
    final reader = _Reader([
      WorkspaceMovementPage(
        movements: [movement('initial', InventoryMovementType.initialStock)],
        nextCursor: next,
      ),
      WorkspaceMovementPage(
        movements: [
          movement('initial', InventoryMovementType.initialStock),
          movement('in', InventoryMovementType.stockIn),
        ],
      ),
    ]);
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stock-history-load-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movement-in')), findsOneWidget);
    expect(find.byKey(const ValueKey('movement-initial')), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-history-end')), findsOneWidget);
  });

  testWidgets('load-more failure preserves records and retries same cursor', (
    tester,
  ) async {
    final next = await cursor();
    final reader = _Reader([
      WorkspaceMovementPage(
        movements: [movement('initial', InventoryMovementType.initialStock)],
        nextCursor: next,
      ),
      const WorkspaceMovementException(WorkspaceMovementFailure.unavailable),
      WorkspaceMovementPage(
        movements: [movement('out', InventoryMovementType.stockOut)],
      ),
    ]);
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stock-history-load-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movement-initial')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('stock-history-load-more-error')),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movement-out')), findsOneWidget);
    expect(reader.calls[1].$2, same(reader.calls[2].$2));
  });

  testWidgets('repeated Load More taps start only one active request', (
    tester,
  ) async {
    final next = await cursor();
    final pending = Completer<WorkspaceMovementPage>();
    final reader = _Reader([
      WorkspaceMovementPage(
        movements: [movement('initial', InventoryMovementType.initialStock)],
        nextCursor: next,
      ),
      pending.future,
    ]);
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final loadMore = find.byKey(const ValueKey('stock-history-load-more'));
    await tester.tap(loadMore);
    await tester.pump();
    await tester.tap(loadMore, warnIfMissed: false);
    await tester.pump();
    expect(reader.calls, hasLength(2));
    pending.complete(const WorkspaceMovementPage(movements: []));
    await tester.pumpAndSettle();
  });

  testWidgets('disposing during a pending request is safe', (tester) async {
    final pending = Completer<WorkspaceMovementPage>();
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: _Reader([pending.future]),
        ),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    pending.complete(
      WorkspaceMovementPage(
        movements: [movement('stale', InventoryMovementType.stockIn)],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale results cannot replace a changed item scope', (
    tester,
  ) async {
    final stale = Completer<WorkspaceMovementPage>();
    final reader = _Reader([
      stale.future,
      WorkspaceMovementPage(
        movements: [movement('new', InventoryMovementType.stockIn)],
      ),
    ]);
    const pageKey = ValueKey('history-page');
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          key: pageKey,
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          key: pageKey,
          item: item('item-b', name: 'Sugar'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    stale.complete(
      WorkspaceMovementPage(
        movements: [movement('stale', InventoryMovementType.stockOut)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sugar'), findsOneWidget);
    expect(find.byKey(const ValueKey('movement-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('movement-stale')), findsNothing);
    expect(reader.calls[1].$1, 'item-b');
  });

  testWidgets('stale results cannot replace a changed cafe session', (
    tester,
  ) async {
    final stale = Completer<WorkspaceMovementPage>();
    final reader = _Reader([
      stale.future,
      WorkspaceMovementPage(
        movements: [movement('current', InventoryMovementType.stockIn)],
      ),
    ]);
    const pageKey = ValueKey('history-session-page');
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          key: pageKey,
          item: item('item-a'),
          workspaceSession: session('cafe-a'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          key: pageKey,
          item: item('item-a'),
          workspaceSession: session('cafe-b'),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    stale.complete(
      WorkspaceMovementPage(
        movements: [movement('stale', InventoryMovementType.stockOut)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movement-current')), findsOneWidget);
    expect(find.byKey(const ValueKey('movement-stale')), findsNothing);
    expect(reader.calls.map((call) => call.$1), everyElement('item-a'));
  });
}
