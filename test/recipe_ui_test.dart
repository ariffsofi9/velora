import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/suggestions/recipe_detail_page.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/recipe_preview_card.dart';

void main() {
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

  Widget details() => const RecipeDetailPage(
    title: 'Tomato Pasta',
    ingredients: [
      'Tomato - 2 pcs',
      'Pasta - 200 g',
      'Missing: Basil - 4 leaves',
    ],
    steps: ['Boil the pasta.', 'Cook the tomato sauce.', 'Combine and serve.'],
    nearExpiryIngredients: ['Tomato - 2 pcs'],
    whyRecommended: 'Uses tomatoes that are close to expiry.',
  );

  testWidgets('Recipe card retains its existing open action', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: RecipePreviewCard(
            title: 'Tomato Pasta',
            content: 'Ingredients:\nTomato\nSteps:\nCook.',
            onTap: () => opened = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Tomato Pasta'));
    expect(opened, isTrue);
  });

  testWidgets('Recipe details preserve quantities and availability labels', (
    tester,
  ) async {
    await tester.pumpWidget(app(details()));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Tomato - 2 pcs'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Tomato - 2 pcs'), findsOneWidget);
    expect(find.text('Pasta - 200 g'), findsOneWidget);
    expect(find.text('Basil - 4 leaves'), findsOneWidget);
    expect(find.text('Near Expiry'), findsOneWidget);
    expect(find.text('Restock'), findsOneWidget);
    expect(find.text('Cook Now'), findsOneWidget);
  });

  for (final width in [320.0, 393.0, 768.0]) {
    testWidgets('Recipe Details fits $width at 2x text', (tester) async {
      tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(app(details(), scale: 2));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  }
}
