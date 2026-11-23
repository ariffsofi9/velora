import 'package:velora/screens/inventory/stock/stock_adjustment_page.dart';
import 'package:velora/services/workspace_inventory_stock_service.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/models/inventory_movement.dart';
import 'package:velora/repositories/workspace_inventory_movement_repository.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
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

class _InventorySource implements WorkspaceInventoryDataSource {
  final paths = <String>[];

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async {
    paths.add(path);
    return [
      WorkspaceInventoryDocument(id: 'item-a', data: item('item-a').toMap()),
      WorkspaceInventoryDocument(
        id: 'archived-b',
        data: {
          ...item('archived-b', name: 'Archived Sugar').toMap(),
          'lifecycleState': 'archived',
          'archivedAt': DateTime.utc(2029),
          'archivedBy': 'owner-a',
        },
      ),
    ];
  }

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) =>
      Stream.fromFuture(readCollection(path));
}

Future<WorkspaceMovementCursor> cursor() async {
  final page = await WorkspaceInventoryMovementRepository(
    session: session('cafe-a'),
    dataSource: _CursorSource(),
  ).getItemMovements('item-a');
  return page.nextCursor!;
}

Widget app(Widget child) => MaterialApp(theme: AppTheme.light, home: child);

AndroidPilotPolicy _pilotPolicy(bool invalid) => AndroidPilotPolicy.parse(
  invalid
      ? {'VELORA_ANDROID_READ_ONLY_PILOT': 'false'}
      : {
          'VELORA_ANDROID_READ_ONLY_PILOT': 'true',
          'VELORA_FIREBASE_PROJECT': AndroidPilotPolicy.approvedProject,
          'VELORA_ANDROID_PILOT_BINDINGS': '[["owner","cafe"]]',
        },
  isWeb: false,
  platform: TargetPlatform.android,
);
final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

class _PolicyAdjuster implements WorkspaceInventoryStockAdjuster {
  final requests = <WorkspaceInventoryStockRequest>[];
  Completer<WorkspaceInventoryStockResult>? pending;
  @override
  Future<WorkspaceInventoryStockResult> adjustStock(
    WorkspaceInventoryStockRequest request,
  ) async {
    requests.add(request);
    return pending == null
        ? WorkspaceInventoryStockResult(
            itemId: request.itemId,
            direction: request.direction,
            quantity: request.quantity,
            resultingQuantity: 4,
            version: 2,
            adjusted: true,
          )
        : await pending!.future;
  }
}

void main() {
  for (final invalid in [false, true]) {
    for (final out in [false, true]) {
      testWidgets(
        'direct Stock out=$out invalid=$invalid rejects injected adjuster',
        (tester) async {
          final adjuster = _PolicyAdjuster(),
              workspace = session('cafe-a'),
              record = item('item-a');
          var keys = 0;
          final page = StockAdjustmentPage(
            item: record,
            type: out
                ? StockAdjustmentType.stockOut
                : StockAdjustmentType.stockIn,
            workspaceSession: workspace,
            adjuster: adjuster,
            idempotencyKeyFactory: () {
              keys++;
              return 'stock-request-01';
            },
          );
          await tester.pumpWidget(
            AndroidPilotAuthScope(
              dependencies: AndroidPilotAuthDependencies(
                policy: _pilotPolicy(invalid),
              ),
              child: app(page),
            ),
          );
          expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
          expect(adjuster.requests, isEmpty);
          expect(keys, 0);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'captured Stock out=$out invalid=$invalid performs zero allocation',
        (tester) async {
          final adjuster = _PolicyAdjuster(),
              workspace = session('cafe-a'),
              record = item('item-a');
          var keys = 0, policy = _normalPolicy;
          late StateSetter update;
          await tester.pumpWidget(
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return AndroidPilotAuthScope(
                  dependencies: AndroidPilotAuthDependencies(policy: policy),
                  child: app(
                    StockAdjustmentPage(
                      item: record,
                      type: out
                          ? StockAdjustmentType.stockOut
                          : StockAdjustmentType.stockIn,
                      workspaceSession: workspace,
                      adjuster: adjuster,
                      idempotencyKeyFactory: () {
                        keys++;
                        return 'stock-request-01';
                      },
                    ),
                  ),
                );
              },
            ),
          );
          await tester.enterText(find.byType(TextField).first, '1');
          final submit = tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('stock-confirm-button')),
              )
              .onPressed!;
          update(() => policy = _pilotPolicy(invalid));
          await tester.pump();
          submit();
          submit();
          await tester.pump();
          expect(adjuster.requests, isEmpty);
          expect(keys, 0);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets('pending Stock completion is fenced by session replacement', (
    tester,
  ) async {
    final adjuster = _PolicyAdjuster()
          ..pending = Completer<WorkspaceInventoryStockResult>(),
        record = item('item-a');
    var workspace = session('cafe-a');
    late StateSetter update;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return AndroidPilotAuthScope(
            dependencies: AndroidPilotAuthDependencies(policy: _normalPolicy),
            child: app(
              StockAdjustmentPage(
                item: record,
                type: StockAdjustmentType.stockOut,
                workspaceSession: workspace,
                adjuster: adjuster,
              ),
            ),
          );
        },
      ),
    );
    await tester.enterText(find.byType(TextField).first, '1');
    tester
        .widget<ElevatedButton>(
          find.byKey(const ValueKey('stock-confirm-button')),
        )
        .onPressed!();
    await tester.pump();
    expect(adjuster.requests, hasLength(1));
    update(() => workspace = session('cafe-b'));
    await tester.pump();
    adjuster.pending!.complete(
      const WorkspaceInventoryStockResult(
        itemId: 'item-a',
        direction: StockDirection.stockOut,
        quantity: 1,
        resultingQuantity: 4,
        version: 2,
        adjusted: true,
      ),
    );
    await tester.pump();
    expect(find.textContaining('completed successfully'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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

  testWidgets('stale results cannot replace a new session in the same cafe', (
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
    expect(find.byKey(const ValueKey('movement-current')), findsOneWidget);
    expect(find.byKey(const ValueKey('movement-stale')), findsNothing);
    expect(reader.calls.map((call) => call.$1), everyElement('item-a'));
  });

  testWidgets('active and archived rows open history for their own item', (
    tester,
  ) async {
    final workspace = session('cafe-a');
    final source = _InventorySource();
    final reader = _Reader([
      WorkspaceMovementPage(
        movements: [movement('listed', InventoryMovementType.stockIn)],
      ),
      const WorkspaceMovementPage(movements: []),
    ]);
    await tester.pumpWidget(
      app(
        InventoryPage(
          workspaceSession: workspace,
          repository: WorkspaceInventoryRepository(
            session: workspace,
            dataSource: source,
          ),
          movementReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stock history for Flour'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movement-listed')), findsOneWidget);
    expect(
      tester
          .widget<StockHistoryPage>(find.byType(StockHistoryPage))
          .workspaceSession,
      same(workspace),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Archived Items'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stock history for Archived Sugar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-history-empty')), findsOneWidget);
    expect(reader.calls, [('item-a', null), ('archived-b', null)]);
    expect(source.paths, everyElement('cafes/cafe-a/inventory'));
  });

  testWidgets(
    'opening history after confirmed Stock Out fetches the movement',
    (tester) async {
      final workspace = session('cafe-a');
      final adjuster = _PolicyAdjuster();
      final reader = _Reader([
        const WorkspaceMovementPage(movements: []),
        WorkspaceMovementPage(
          movements: [movement('confirmed', InventoryMovementType.stockOut)],
        ),
      ]);
      await tester.pumpWidget(
        app(
          InventoryPage(
            workspaceSession: workspace,
            repository: WorkspaceInventoryRepository(
              session: workspace,
              dataSource: _InventorySource(),
            ),
            stockAdjuster: adjuster,
            movementReader: reader,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final history = find.byTooltip('Stock history for Flour');
      await tester.tap(history);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stock-history-empty')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flour'));
      await tester.pumpAndSettle();
      final stockOut = find.text('Stock Out');
      await tester.ensureVisible(stockOut);
      await tester.tap(stockOut);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('stock-quantity-field')),
        '2',
      );
      final confirm = find.byKey(const ValueKey('stock-confirm-button'));
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(adjuster.requests.single.itemId, 'item-a');
      expect(adjuster.requests.single.direction, StockDirection.stockOut);
      await tester.tap(history);
      await tester.pumpAndSettle();
      expect(reader.calls, [('item-a', null), ('item-a', null)]);
      expect(find.byKey(const ValueKey('movement-confirmed')), findsOneWidget);
    },
  );

  testWidgets('history discards a pending result when authority is suspended', (
    tester,
  ) async {
    final workspace = session('cafe-a');
    final pending = Completer<WorkspaceMovementPage>();
    await tester.pumpWidget(
      app(
        StockHistoryPage(
          item: item('item-a'),
          workspaceSession: workspace,
          movementReader: _Reader([pending.future]),
        ),
      ),
    );
    workspace.suspendAuthority();
    pending.complete(
      WorkspaceMovementPage(
        movements: [movement('hidden', InventoryMovementType.stockIn)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movement-hidden')), findsNothing);
    expect(
      find.text('Workspace access could not be verified.'),
      findsOneWidget,
    );
  });
}
