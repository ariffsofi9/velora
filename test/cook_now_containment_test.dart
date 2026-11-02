import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/logic/cook_now_service.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/screens/suggestions/logic_suggestions/cook_now_deduction_service.dart';
import 'package:velora/screens/suggestions/recipe_detail_page.dart';

void main() {
  test(
    'legacy recipe deduction fails closed without partial results',
    () async {
      final result = await CookNowDeductionService().deductRecipeIngredients(
        userId: 'user-a',
        recipeTitle: 'Soup',
        ingredients: const ['Carrot', 'Milk'],
        portions: 2,
      );

      expect(result.success, isFalse);
      expect(result.message, CookNowDeductionService.unavailableMessage);
      expect(result.usedItems, isEmpty);
      expect(result.skippedItems, isEmpty);
    },
  );

  test('older CookNowService entry point also fails before mutation', () async {
    final item = InventoryItem(
      id: 'item-a',
      name: 'Carrot',
      category: 'Vegetable',
      quantity: 5,
      unit: 'pcs',
      expiryDate: DateTime.utc(2030),
      imageUrl: '',
      createdAt: DateTime.utc(2029),
    );

    await expectLater(
      CookNowService().cookRecipe([item]),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('secure workspace inventory deduction'),
        ),
      ),
    );
  });

  testWidgets(
    'recipe details stay readable and Cook Now explains unavailability',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: RecipeDetailPage(
            title: 'Vegetable Soup',
            ingredients: ['Carrot', 'Milk'],
            steps: ['Prepare ingredients', 'Cook gently'],
            nearExpiryIngredients: ['Milk'],
            whyRecommended: 'Uses available ingredients.',
          ),
        ),
      );

      expect(find.text('Vegetable Soup'), findsOneWidget);
      expect(find.text('Carrot'), findsOneWidget);

      await tester.tap(find.text('Cook Now'));
      await tester.pump();

      expect(
        find.text(CookNowDeductionService.unavailableMessage),
        findsOneWidget,
      );
      expect(find.text('Inventory Updated'), findsNothing);
    },
  );
}
