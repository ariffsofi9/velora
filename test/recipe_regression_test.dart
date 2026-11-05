import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/logic/ai_recipe_save_service.dart';
import 'package:velora/logic/suggestion_helper.dart';
import 'package:velora/screens/suggestions/logic_suggestions/groq_recipe_formatter.dart';
import 'package:velora/screens/suggestions/utils_suggestions/recipe_parser.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/recipe_preview_card.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/suggestion_ai_result.dart';
import 'package:velora/widgets/suggestions/empty_card.dart';

// Empty results must not read history or require Firebase initialization.
class _UnusedHistory implements AiRecipeSaveService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Empty results must not access recipe history');
}

void main() {
  test(
    'Legacy headings without colons and alternate ingredient lists survive',
    () {
      const body =
          'Ingredients Used\n\u2022 Egg\n* Milk\n1) Rice\nMissing / Restock Ingredients\n- Salt\nInstructions\n1) Mix.\n2. Cook.\nWhy Recommended\nUse available stock.';
      expect(RecipeParser.ingredients(body), [
        'Egg',
        'Milk',
        'Rice',
        'Missing / Restock: Salt',
      ]);
      expect(RecipeParser.steps(body), ['Mix.', 'Cook.']);
      expect(RecipeParser.why(body), 'Use available stock.');
    },
  );

  test('Markdown section headings do not become separate recipe cards', () {
    const text =
        '## Recipe 1: Omelette\n### Ingredients\n- Egg\n### Steps\n1. Cook.\n### Why\nUse eggs.\n## Recipe 2: Toast\n**Ingredients Used:**\nBread\n**Method:**\nToast the bread.\n**Why Recommended:** Use bread.';
    final recipes = SuggestionHelper().parseRecipes(text);
    expect(recipes.map(RecipeParser.title), ['Omelette', 'Toast']);
    expect(RecipeParser.ingredients(recipes.first['content']!), ['Egg']);
    expect(RecipeParser.ingredients(recipes.last['content']!), ['Bread']);
    expect(RecipeParser.steps(recipes.last['content']!), ['Toast the bread.']);
    expect(RecipeParser.why(recipes.last['content']!), 'Use bread.');
  });

  test('Plain title and inline legacy sections remain readable', () {
    const text =
        'Omelette\nIngredients: Egg\nSteps: Cook the egg.\nWhy: Use stock.';
    final recipes = SuggestionHelper().parseRecipes(text);
    expect(recipes.single['title'], 'Omelette');
    expect(RecipeParser.ingredients(recipes.single['content']!), ['Egg']);
    expect(RecipeParser.steps(recipes.single['content']!), ['Cook the egg.']);
  });

  test('Plain empty messages are never parsed as recipes', () {
    expect(
      SuggestionHelper().parseRecipes(
        'Not enough usable ingredients for a recipe.',
      ),
      isEmpty,
    );
    expect(
      SuggestionHelper().parseRecipes(
        'No recipe suggestions available right now.\nAll recipes were skipped.',
      ),
      isEmpty,
    );
  });

  for (final status in ['restock_needed', 'empty', 'success']) {
    testWidgets('Empty $status result shows only the empty state', (
      tester,
    ) async {
      final text = GroqRecipeFormatter().format({
        'status': status,
        'recipes': [],
        'message': 'No AI suggestion available: restock ingredients.',
      });
      expect(GroqRecipeFormatter.isEmptyResult(text), isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SuggestionAiResult(
              isLoading: false,
              isRecipeResult: true,
              isCached: false,
              inventoryChanged: false,
              resultText: text,
              items: [],
              helper: SuggestionHelper(),
              recipeSaveService: _UnusedHistory(),
              onRegenerate: () {},
            ),
          ),
        ),
      );
      expect(find.byType(EmptyCard), findsOneWidget);
      expect(find.text(text), findsOneWidget);
      expect(find.byType(RecipePreviewCard), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'Errors remain errors rather than being marked as successful empty results',
    () {
      final text = GroqRecipeFormatter().format({
        'status': 'error',
        'recipes': [],
        'message': 'Groq failed. Please try again.',
      });
      expect(GroqRecipeFormatter.isEmptyResult(text), isFalse);
    },
  );
}
