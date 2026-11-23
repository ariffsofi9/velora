import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/models/inventory_movement.dart';
import 'package:velora/repositories/workspace_inventory_movement_repository.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/add_item/widgets_add/add_item_save_button.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
import 'package:velora/services/workspace_inventory_create_service.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';
import 'package:velora/services/workspace_session.dart';

import 'platform_journal_store_test.dart' as journal;
import 'workspace_inventory_https_transport_test.dart' as transport;

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'verified-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

class _Creator implements WorkspaceInventoryCreator {
  final List<WorkspaceInventoryCreateRequest> requests = [];
  final List<Object> outcomes;

  _Creator(this.outcomes);

  @override
  Future<WorkspaceInventoryCreateResult> createItem(
    WorkspaceInventoryCreateRequest request,
  ) async {
    requests.add(request);
    final outcome = outcomes.removeAt(0);
    if (outcome is Future<WorkspaceInventoryCreateResult>) return outcome;
    if (outcome is WorkspaceInventoryCreateResult) return outcome;
    throw outcome;
  }
}

Widget _app({
  WorkspaceInventoryCreator? creator,
  required String Function() keyFactory,
}) => MaterialApp(
  theme: AppTheme.light,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddItemPage(
              workspaceSession: _session,
              creator: creator,
              idempotencyKeyFactory: keyFactory,
            ),
          ),
        ),
        child: const Text('Open Add Item'),
      ),
    ),
  ),
);

Future<void> _openAndFill(WidgetTester tester) async {
  await tester.tap(find.text('Open Add Item'));
  await tester.pumpAndSettle();
  await _fill(tester);
}

Future<void> _fill(WidgetTester tester, {String quantity = '4'}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'Fresh Milk');
  await tester.enterText(fields.at(1), quantity);
  await tester.ensureVisible(find.text('Select date'));
  await tester.tap(find.text('Select date'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.chevron_right).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('15').last);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Future<void> _settleMutation(WidgetTester tester) async {
  // Let stream cancellation futures complete before advancing the fake
  // animation clock across the adapter's cleanup deadline.
  for (var turn = 0; turn < 3; turn++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pumpAndSettle();
}

class _InventorySource implements WorkspaceInventoryDataSource {
  InventoryItem? item;
  int subscriptions = 0;

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async {
    expect(path, 'cafes/cafe/inventory');
    final current = item;
    return [
      if (current != null)
        WorkspaceInventoryDocument(id: current.id, data: current.toMap()),
    ];
  }

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    subscriptions++;
    return Stream.fromFuture(readCollection(path));
  }
}

class _InitialStockReader implements WorkspaceInventoryMovementReader {
  final _InventorySource source;
  _InitialStockReader(this.source);

  @override
  Future<WorkspaceMovementPage> getItemMovements(
    String itemId, {
    WorkspaceMovementCursor? cursor,
  }) async {
    final item = source.item!;
    expect(itemId, item.id);
    expect(cursor, isNull);
    return WorkspaceMovementPage(
      movements: [
        InventoryMovement(
          id: 'initial',
          cafeId: 'cafe',
          itemId: item.id,
          actorUid: 'staff',
          type: InventoryMovementType.initialStock,
          direction: null,
          quantity: item.quantity,
          delta: null,
          previousQuantity: null,
          resultingQuantity: null,
          unit: item.unit,
          reason: null,
          createdAt: item.createdAt,
          fromVersion: null,
          resultVersion: null,
          requestHash: 'synthetic',
        ),
      ],
    );
  }
}

void main() {
  for (final lost in [false, true]) {
    testWidgets('REAL Add Item refreshes inventory, lost response=$lost', (
      tester,
    ) async {
      final fixture = transport.Fixture();
      addTearDown(fixture.close);
      final engine = journal.FakeTransactionalJournalEngine();
      final store = journal.store(engine);
      final source = _InventorySource();
      const project = HttpsWorkspaceInventory.realProject;
      final result = transport.acknowledgement('create');
      Map<String, dynamic>? original;
      void publishItem() {
        source.item = InventoryItem(
          id: result['itemId'] as String,
          name: 'Fresh Milk',
          category: 'Meat',
          quantity: lost ? 0 : 4,
          unit: 'kg',
          expiryDate: DateTime.utc(2030),
          imageUrl: '',
          createdAt: DateTime.utc(2029),
        );
      }

      fixture.client = transport.FakeClient((sent) async {
        final body =
            jsonDecode((sent as http.Request).body) as Map<String, dynamic>;
        if (sent.url.path == '/inventory/reconcile') {
          expect(body, {'operation': 'create', 'request': original});
          publishItem();
          return transport.response({'state': 'committed', 'result': result});
        }
        expect(sent.url.path, '/inventory/create');
        expect(original, isNull);
        original = body;
        expect(body['expectedCafeId'], 'cafe');
        expect(body['expectedMembershipGeneration'], 3);
        expect(body['quantity'], lost ? 0 : 4);
        final key = jsonEncode([
          project,
          'staff',
          'create',
          body['idempotencyKey'],
        ]);
        expect((await store.mutations.read(key) as Map)['state'], 'dispatched');
        if (lost) throw http.ClientException('synthetic lost response');
        publishItem();
        return transport.response(result);
      });

      Future<void> openInventory(int revision) async {
        final workspace = transport.workspace(uid: 'staff', generation: 3);
        fixture.current = transport.snapshot(
          workspace,
          uid: 'staff',
          project: project,
          revision: revision,
        );
        final adapter = fixture.realAdapter(journal.store(engine));
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: InventoryPage(
              workspaceSession: workspace,
              repository: WorkspaceInventoryRepository(
                session: workspace,
                dataSource: source,
              ),
              inventoryCreator: adapter,
              movementReader: _InitialStockReader(source),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> addItem() async {
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        await _fill(tester, quantity: lost ? '0' : '4');
        final save = find.text('Save Item');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await _settleMutation(tester);
      }

      await openInventory(1);
      final before = source.subscriptions;
      await addItem();
      if (lost) {
        expect(find.textContaining('Confirmation pending'), findsOneWidget);
        expect(
          tester
              .widget<AddItemSaveButton>(find.byType(AddItemSaveButton))
              .enabled,
          isFalse,
        );
        expect(find.textContaining('added successfully'), findsNothing);
        fixture.current!.workspace.invalidate();
        await tester.pumpWidget(const SizedBox.shrink());
        await openInventory(2);
        await addItem();
        expect(find.textContaining('Confirmation pending'), findsOneWidget);
        expect(fixture.client.requests, hasLength(1));
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Inventory recovery'));
        await tester.pumpAndSettle();
        expect(find.text('Fresh Milk'), findsOneWidget);
        final beforeRecovery = source.subscriptions;
        await tester.tap(find.text('Check outcome'));
        await _settleMutation(tester);
        expect(
          find.text('The original inventory change was confirmed.'),
          findsOneWidget,
        );
        expect(source.subscriptions, beforeRecovery + 1);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      } else {
        expect(source.subscriptions, before + 1);
      }
      expect(find.byType(AddItemPage), findsNothing);
      expect(find.byTooltip('Stock history for Fresh Milk'), findsOneWidget);
      expect(fixture.client.requests.map((request) => request.url.path), [
        '/inventory/create',
        if (lost) '/inventory/reconcile',
      ]);
      await tester.tap(find.byTooltip('Stock history for Fresh Milk'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('movement-initial')), findsOneWidget);
    });
  }

  testWidgets(
    'verified Add requires an explicit creator before allocating a key',
    (tester) async {
      var keys = 0;
      await tester.pumpWidget(_app(keyFactory: () => 'add-key-${++keys}'));
      await _openAndFill(tester);
      await tester.ensureVisible(find.text('Save Item'));
      await tester.tap(find.text('Save Item'));
      await tester.pump();

      expect(
        find.text('Secure inventory updates are unavailable.'),
        findsOneWidget,
      );
      expect(find.byType(AddItemPage), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(keys, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown HTTPS creation remains unconfirmed without auto-retry', (
    tester,
  ) async {
    var keys = 0;
    final creator = _Creator([
      InventoryHttpsCreateException(
        WorkspaceInventoryCreateFailure.unavailable,
        const InventoryHttpsFailure('unavailable', outcomeUnknown: true),
      ),
    ]);
    await tester.pumpWidget(
      _app(creator: creator, keyFactory: () => 'unknown-add-${++keys}'),
    );
    await _openAndFill(tester);
    await tester.ensureVisible(find.text('Save Item'));
    await tester.tap(find.text('Save Item'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Item creation could not be confirmed'),
      findsOneWidget,
    );
    expect(find.byType(AddItemPage), findsOneWidget);
    expect(creator.requests, hasLength(1));
    expect(keys, 1);
  });

  testWidgets(
    'unverified direct route fails closed without a callable request',
    (tester) async {
      final creator = _Creator(const []);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: AddItemPage(creator: creator),
        ),
      );

      await tester.ensureVisible(find.text('Save Item'));
      await tester.tap(find.text('Save Item'));
      await tester.pump();

      expect(
        find.textContaining('requires a verified workspace'),
        findsOneWidget,
      );
      expect(creator.requests, isEmpty);
    },
  );

  testWidgets(
    'pending submission disables duplicate taps and returns success',
    (tester) async {
      final pending = Completer<WorkspaceInventoryCreateResult>();
      final creator = _Creator([pending.future]);
      await tester.pumpWidget(
        _app(creator: creator, keyFactory: () => 'fixed-request-key'),
      );
      await _openAndFill(tester);

      await tester.ensureVisible(find.text('Save Item'));
      await tester.tap(find.text('Save Item'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(AddItemSaveButton));
      expect(creator.requests, hasLength(1));

      pending.complete(
        const WorkspaceInventoryCreateResult(itemId: 'item-a', created: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open Add Item'), findsOneWidget);
      final request = creator.requests.single;
      expect(request.imageUrl, '');
      expect(request.name, 'Fresh Milk');
      expect(request.category, 'Meat');
      expect(request.quantity, 4);
      expect(request.unit, 'kg');
      expect(request.expiryDate.day, 15);
      expect(request.idempotencyKey, 'fixed-request-key');
    },
  );

  testWidgets('retry keeps its key until the submission changes', (
    tester,
  ) async {
    var keyIndex = 0;
    final creator = _Creator([
      const WorkspaceInventoryCreateException(
        WorkspaceInventoryCreateFailure.unavailable,
      ),
      const WorkspaceInventoryCreateException(
        WorkspaceInventoryCreateFailure.unavailable,
      ),
      const WorkspaceInventoryCreateResult(itemId: 'item-b', created: true),
    ]);
    await tester.pumpWidget(
      _app(
        creator: creator,
        keyFactory: () => 'request-key-${++keyIndex}'.padRight(16, '0'),
      ),
    );
    await _openAndFill(tester);

    await tester.ensureVisible(find.text('Save Item'));
    await tester.tap(find.text('Save Item'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check your connection'), findsOneWidget);
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save Item'));
    await tester.tap(find.text('Save Item'));
    await tester.pumpAndSettle();
    expect(
      creator.requests[1].idempotencyKey,
      creator.requests[0].idempotencyKey,
    );

    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '5');
    await tester.ensureVisible(find.text('Save Item'));
    await tester.tap(find.text('Save Item'));
    await tester.pumpAndSettle();
    expect(
      creator.requests[2].idempotencyKey,
      isNot(creator.requests[1].idempotencyKey),
    );
    expect(creator.requests[2].quantity, 5);
  });

  testWidgets('permission rejection remains visible and does not pop', (
    tester,
  ) async {
    final creator = _Creator([
      const WorkspaceInventoryCreateException(
        WorkspaceInventoryCreateFailure.permissionDenied,
      ),
    ]);
    await tester.pumpWidget(
      _app(creator: creator, keyFactory: () => 'permission-key-01'),
    );
    await _openAndFill(tester);

    await tester.ensureVisible(find.text('Save Item'));
    await tester.tap(find.text('Save Item'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('do not have permission to add an item'),
      findsOneWidget,
    );
    expect(creator.requests, hasLength(1));
    expect(find.byType(AddItemPage), findsOneWidget);
  });
}
