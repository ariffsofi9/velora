import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'package:velora/services/workspace_session.dart';

class _InventorySource implements WorkspaceInventoryDataSource {
  final Stream<List<WorkspaceInventoryDocument>> stream;
  String? watchedPath;

  _InventorySource(this.stream);

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw UnimplementedError();

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watchedPath = path;
    return stream;
  }
}

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'ai-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

WorkspaceInventoryDocument _item() => WorkspaceInventoryDocument(
  id: 'milk-a',
  data: {
    'name': 'Fresh Milk',
    'category': 'Dairy',
    'quantity': 1,
    'unit': 'L',
    'expiryDate': DateTime.now().add(const Duration(days: 1)),
    'imageUrl': '',
    'createdAt': DateTime.now(),
  },
);

Widget _app(_InventorySource source) => MaterialApp(
  theme: AppTheme.light,
  home: SuggestionsPage(
    workspaceSession: _session,
    repository: WorkspaceInventoryRepository(
      session: _session,
      dataSource: source,
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reads only the verified cafe and renders scoped insights', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_item()]));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(source.watchedPath, 'cafes/ai-cafe/inventory');
    expect(find.text('Fresh Milk'), findsWidgets);
    expect(find.text('Smart Restock Suggestions'), findsOneWidget);
  });

  testWidgets('empty cafe shows normal inventory guidance', (tester) async {
    final source = _InventorySource(Stream.value(const []));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(
      find.text('Add inventory items first to get AI insights.'),
      findsOneWidget,
    );
    expect(find.textContaining('Inventory is unavailable'), findsNothing);
  });

  testWidgets('loading and repository errors remain distinguishable', (
    tester,
  ) async {
    final controller = StreamController<List<WorkspaceInventoryDocument>>();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(_InventorySource(controller.stream)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.addError(StateError('permission denied'));
    await tester.pump();
    expect(
      find.text(
        'Inventory is unavailable. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('unsafe AI actions are visibly disabled and do not run', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_item()]));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    for (final label in ['Generate Recipes', 'Restock Advice']) {
      final gesture = tester.widget<GestureDetector>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(gesture.onTap, isNull);
    }
    expect(
      find.textContaining('secure workspace AI is enabled'),
      findsOneWidget,
    );
  });

  testWidgets('missing verified context fails closed without inventory access', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const SuggestionsPage()),
    );

    expect(
      find.text(
        'AI Insights is unavailable because workspace access was not verified.',
      ),
      findsOneWidget,
    );
  });
}
