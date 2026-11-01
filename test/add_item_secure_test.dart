import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/add_item/widgets_add/add_item_save_button.dart';
import 'package:velora/services/workspace_inventory_create_service.dart';
import 'package:velora/services/workspace_session.dart';

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
  required WorkspaceInventoryCreator creator,
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
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'Fresh Milk');
  await tester.enterText(fields.at(1), '4');
  await tester.ensureVisible(find.text('Select date'));
  await tester.tap(find.text('Select date'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.chevron_right).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('15').last);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
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
      expect(creator.requests.single.imageUrl, '');
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
      find.textContaining('workspace access could not be verified'),
      findsOneWidget,
    );
    expect(creator.requests, hasLength(1));
    expect(find.byType(AddItemPage), findsOneWidget);
  });
}
