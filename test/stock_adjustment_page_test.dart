import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/stock/stock_adjustment_page.dart';
import 'package:velora/services/workspace_inventory_stock_service.dart';
import 'package:velora/services/workspace_session.dart';

final session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'verified-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);
InventoryItem item({int quantity = 4, int version = 1}) => InventoryItem(
  id: 'milk',
  name: 'Milk',
  category: 'Dairy',
  quantity: quantity,
  unit: 'L',
  expiryDate: DateTime(2030),
  imageUrl: '',
  createdAt: DateTime(2029),
  version: version,
);

class _Adjuster implements WorkspaceInventoryStockAdjuster {
  final List<Object> outcomes;
  final requests = <WorkspaceInventoryStockRequest>[];
  _Adjuster(this.outcomes);
  @override
  Future<WorkspaceInventoryStockResult> adjustStock(
    WorkspaceInventoryStockRequest request,
  ) async {
    requests.add(request);
    final outcome = outcomes.removeAt(0);
    if (outcome is Future<WorkspaceInventoryStockResult>) return outcome;
    if (outcome is WorkspaceInventoryStockResult) return outcome;
    throw outcome;
  }
}

class _Source implements WorkspaceInventoryDataSource {
  final InventoryItem latest;
  _Source(this.latest);
  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async =>
      [
        WorkspaceInventoryDocument(
          id: latest.id,
          data: {
            'name': latest.name,
            'category': latest.category,
            'quantity': latest.quantity,
            'unit': latest.unit,
            'expiryDate': latest.expiryDate,
            'imageUrl': latest.imageUrl,
            'createdAt': latest.createdAt,
            'version': latest.version,
          },
        ),
      ];
  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) =>
      const Stream.empty();
}

Widget app(Widget child) => MaterialApp(theme: AppTheme.light, home: child);
const success = WorkspaceInventoryStockResult(
  itemId: 'milk',
  direction: StockDirection.stockIn,
  quantity: 2,
  resultingQuantity: 6,
  version: 2,
  adjusted: true,
);
Future<void> submit(WidgetTester tester, String value) async {
  await tester.enterText(
    find.byKey(const ValueKey('stock-quantity-field')),
    value,
  );
  await tester.ensureVisible(
    find.byKey(const ValueKey('stock-confirm-button')),
  );
  await tester.pump();
  final buttonFinder = find.byKey(const ValueKey('stock-confirm-button'));
  final button = tester.widget<ElevatedButton>(buttonFinder);
  expect(button.onPressed, isNotNull);
  expect(buttonFinder.hitTestable(), findsOneWidget);
  await tester.tap(buttonFinder);
}

Future<void> dismissFeedback(WidgetTester tester) async {
  tester
      .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
      .clearSnackBars();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('validates limit and previews exact-zero stock out', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        StockOutPage(
          item: item(),
          workspaceSession: session,
          adjuster: _Adjuster(const []),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('stock-quantity-field')),
      '5',
    );
    await tester.pump();
    expect(
      find.text('Quantity cannot exceed available stock.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('stock-quantity-field')),
      '1.5',
    );
    await tester.pump();
    expect(find.text('Enter a whole number above 0.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('stock-quantity-field')),
      '4',
    );
    await tester.pump();
    expect(find.text('Resulting stock: 0 L'), findsOneWidget);
  });

  testWidgets('missing verified session fails closed', (tester) async {
    final adjuster = _Adjuster(const []);
    await tester.pumpWidget(app(StockInPage(item: item(), adjuster: adjuster)));
    await submit(tester, '2');
    await tester.pump();
    expect(find.text('A verified workspace item is required.'), findsOneWidget);
    expect(adjuster.requests, isEmpty);
  });

  testWidgets('success blocks double tap and sends snapshot version', (
    tester,
  ) async {
    final pending = Completer<WorkspaceInventoryStockResult>();
    final adjuster = _Adjuster([pending.future]);
    await tester.pumpWidget(
      app(
        StockInPage(
          item: item(),
          workspaceSession: session,
          adjuster: adjuster,
          idempotencyKeyFactory: () => 'fixed-stock-key-001',
        ),
      ),
    );
    expect(find.text('Current stock: 4 L'), findsOneWidget);
    await submit(tester, '2');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('stock-confirm-button')));
    expect(adjuster.requests, hasLength(1));
    expect(adjuster.requests.single.expectedVersion, 1);
    pending.complete(success);
    await tester.pumpAndSettle();
  });

  testWidgets('default runtime key generation reaches callable safely', (
    tester,
  ) async {
    final adjuster = _Adjuster([success]);
    await tester.pumpWidget(
      app(
        StockInPage(
          item: item(),
          workspaceSession: session,
          adjuster: adjuster,
        ),
      ),
    );

    await submit(tester, '3');
    await tester.pumpAndSettle();

    expect(adjuster.requests, hasLength(1));
    expect(
      adjuster.requests.single.idempotencyKey.length,
      inInclusiveRange(16, 128),
    );
    expect(adjuster.requests.single.quantity, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unexpected pre-call failure restores button and shows feedback',
    (tester) async {
      final adjuster = _Adjuster(const []);
      await tester.pumpWidget(
        app(
          StockInPage(
            item: item(),
            workspaceSession: session,
            adjuster: adjuster,
            idempotencyKeyFactory: () => throw StateError('key failure'),
          ),
        ),
      );

      await submit(tester, '2');
      await tester.pump();

      expect(
        find.text('Unable to start the stock adjustment. Please try again.'),
        findsOneWidget,
      );
      expect(adjuster.requests, isEmpty);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('stock-confirm-button')),
      );
      expect(button.onPressed, isNotNull);
    },
  );

  testWidgets('retry keeps key while changed quantity rotates key', (
    tester,
  ) async {
    var index = 0;
    final adjuster = _Adjuster([
      const WorkspaceInventoryStockException(
        WorkspaceInventoryStockFailure.unavailable,
      ),
      const WorkspaceInventoryStockException(
        WorkspaceInventoryStockFailure.unavailable,
      ),
      success,
    ]);
    await tester.pumpWidget(
      app(
        StockInPage(
          item: item(),
          workspaceSession: session,
          adjuster: adjuster,
          idempotencyKeyFactory: () => 'stock-key-${++index}'.padRight(16, '0'),
        ),
      ),
    );
    await submit(tester, '2');
    await tester.pumpAndSettle();
    expect(adjuster.requests, hasLength(1));
    final first = adjuster.requests.single;
    await dismissFeedback(tester);

    await submit(tester, '2');
    await tester.pumpAndSettle();
    expect(adjuster.requests, hasLength(2));
    final retry = adjuster.requests[1];
    expect(retry.idempotencyKey, first.idempotencyKey);
    expect(retry.fingerprint, first.fingerprint);
    await dismissFeedback(tester);

    await submit(tester, '3');
    await tester.pumpAndSettle();
    expect(adjuster.requests, hasLength(3));
    final changed = adjuster.requests[2];
    expect(changed.idempotencyKey, isNot(retry.idempotencyKey));
    expect(changed.quantity, 3);
    expect(changed.fingerprint, isNot(retry.fingerprint));
  });

  testWidgets('stale result requires explicit scoped reload', (tester) async {
    final latest = item(quantity: 8, version: 2);
    final repository = WorkspaceInventoryRepository(
      session: session,
      dataSource: _Source(latest),
    );
    final adjuster = _Adjuster([
      const WorkspaceInventoryStockException(
        WorkspaceInventoryStockFailure.stale,
      ),
    ]);
    await tester.pumpWidget(
      app(
        StockInPage(
          item: item(),
          workspaceSession: session,
          adjuster: adjuster,
          repository: repository,
          idempotencyKeyFactory: () => 'reload-stock-key',
        ),
      ),
    );
    await submit(tester, '2');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reload-latest-stock-item')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reload-latest-stock-item')));
    await tester.pumpAndSettle();
    expect(find.text('Current stock: 8 L'), findsOneWidget);
    expect(find.text('Version 2'), findsOneWidget);
    expect(adjuster.requests, hasLength(1));
  });
}
