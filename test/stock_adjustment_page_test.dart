import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/screens/inventory/stock/stock_adjustment_page.dart';

void main() {
  final item = InventoryItem(
    id: 'milk',
    name: 'Milk',
    category: 'Dairy',
    quantity: 4,
    expiryDate: DateTime(2030),
    imageUrl: '',
    createdAt: DateTime(2029),
  );

  Widget app(Widget child, {double scale = 1}) => MaterialApp(
    theme: AppTheme.light,
    builder: (context, screen) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: screen!,
    ),
    home: child,
  );

  testWidgets('Stock In validates positive whole quantities', (tester) async {
    await tester.pumpWidget(app(StockInPage(item: item)));
    final field = find.byKey(const ValueKey('stock-quantity-field'));

    await tester.enterText(field, '0');
    await tester.pump();
    expect(find.text('Enter a whole number above 0.'), findsOneWidget);

    await tester.enterText(field, 'two');
    await tester.pump();
    expect(find.text('Enter a whole number above 0.'), findsOneWidget);

    await tester.enterText(field, '2');
    await tester.pump();
    expect(find.text('Enter a whole number above 0.'), findsNothing);
  });

  testWidgets('Stock Out rejects quantities above available stock', (
    tester,
  ) async {
    await tester.pumpWidget(app(StockOutPage(item: item)));
    await tester.enterText(
      find.byKey(const ValueKey('stock-quantity-field')),
      '5',
    );
    await tester.pump();

    expect(find.text('Available: 4'), findsOneWidget);
    expect(
      find.text('Quantity cannot exceed available stock.'),
      findsOneWidget,
    );
  });

  testWidgets('Preview is honest and cannot submit', (tester) async {
    await tester.pumpWidget(app(StockInPage(item: item)));

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();

    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Confirm Stock In'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Unit unavailable'), findsOneWidget);
    expect(
      find.textContaining('atomic, authorized transaction service'),
      findsOneWidget,
    );
  });

  for (final width in [320.0, 393.0, 768.0]) {
    for (final page in <String, Widget>{
      'Stock In': StockInPage(item: item),
      'Stock Out': StockOutPage(item: item),
    }.entries) {
      testWidgets('${page.key} fits $width at 2x text', (tester) async {
        tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(app(page.value, scale: 2));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  }
}
