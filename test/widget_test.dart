import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_empty_state.dart';

void main() {
  testWidgets('Empty inventory shows guidance and invokes Add Item action', (
    WidgetTester tester,
  ) async {
    var addRequests = 0;

    // Exercise the production widget without starting Firebase or auth routing.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InventoryEmptyState(onAdd: () => addRequests++),
        ),
      ),
    );

    expect(find.text('Your inventory is empty'), findsOneWidget);
    expect(
      find.text('Add your first item to start tracking food expiry.'),
      findsOneWidget,
    );
    final addButton = find.widgetWithText(ElevatedButton, 'Add Item');
    expect(addButton, findsOneWidget);
    expect(addRequests, 0);

    await tester.tap(addButton);
    await tester.pump();

    expect(addRequests, 1);
    expect(tester.takeException(), isNull);
  });
}
