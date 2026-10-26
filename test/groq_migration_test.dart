import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/logic/ai_reset_helper.dart';
import 'package:velora/logic/groq_service.dart';
import 'package:velora/logic/suggestion_helper.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/screens/suggestions/logic_suggestions/groq_recipe_formatter.dart';
import 'package:velora/screens/suggestions/logic_suggestions/local_restock_formatter.dart';
import 'package:velora/screens/suggestions/logic_suggestions/skipped_recipe_service.dart';
import 'package:velora/screens/suggestions/utils_suggestions/recipe_parser.dart';

void main() {
  final tomorrow = DateTime.now().add(const Duration(days: 1));
  final inventory = <Map<String, dynamic>>[
    {'name': 'Egg', 'quantity': 4, 'expiryDate': tomorrow},
  ];
  Map<String, dynamic> recipe(String title) => {
    'title': title,
    'ingredientsUsed': ['Egg'],
    'missingIngredients': ['Salt'],
    'steps': ['Beat the egg.', 'Cook until set.'],
    'whyRecommended': 'Use the egg before expiry.',
  };
  http.Response success(List<Map<String, dynamic>> recipes) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {
            'content': jsonEncode({'recipes': recipes}),
          },
        },
      ],
    }),
    200,
  );
  GroqService service(Future<http.Response> Function(http.Request) handler) =>
      GroqService(apiKey: 'unit-test-placeholder', client: MockClient(handler));

  test(
    'Missing configuration makes no request and returns no invented recipe',
    () async {
      final groq = GroqService(
        client: MockClient((_) async {
          fail('No network request is allowed without configuration');
        }),
      );
      final result = await groq.generateRecipes(inventoryItems: inventory);
      expect(result['status'], 'error');
      expect(result['recipes'], isEmpty);
      expect(result['message'], contains('not configured'));
    },
  );

  test(
    'Request uses supported JSON format and only positive unexpired stock',
    () async {
      final groq = service((request) async {
        expect(
          request.url.toString(),
          'https://api.groq.com/openai/v1/chat/completions',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'llama-3.1-8b-instant');
        expect(body['response_format'], {'type': 'json_object'});
        final prompt = body['messages'][1]['content'] as String;
        expect(prompt, contains('Egg'));
        expect(prompt, isNot(contains('UnsafeMilk')));
        expect(prompt, isNot(contains('EmptyRice')));
        return success([recipe('Omelette')]);
      });
      final result = await groq.generateRecipes(
        inventoryItems: [
          ...inventory,
          {
            'name': 'UnsafeMilk',
            'quantity': 2,
            'expiryDate': DateTime.now().subtract(const Duration(days: 2)),
          },
          {'name': 'EmptyRice', 'quantity': 0, 'expiryDate': tomorrow},
        ],
      );
      expect(result['status'], 'success');
      expect(result['recipes'][0]['title'], 'Omelette');
    },
  );

  test('All unusable inventory bypasses the provider', () async {
    final groq = service((_) async {
      fail('No request expected');
    });
    final result = await groq.generateRecipes(
      inventoryItems: [
        {'name': 'Egg', 'quantity': 0, 'expiryDate': tomorrow},
      ],
    );
    expect(result['status'], 'empty');
    expect(result['recipes'], isEmpty);
  });

  for (final code in [401, 403, 429, 500]) {
    test(
      'HTTP $code returns an explicit error, never a fabricated recipe',
      () async {
        final groq = service(
          (_) async => http.Response(
            'private upstream details',
            code,
            headers: {'retry-after': '12'},
          ),
        );
        final result = await groq.generateRecipes(inventoryItems: inventory);
        expect(result['status'], 'error');
        expect(result['recipes'], isEmpty);
        expect(result['message'], isNot(contains('private upstream details')));
        final text = GroqRecipeFormatter().format(result);
        if (code == 429) {
          expect(text, contains('12 seconds'));
        } else {
          expect(
            text.toLowerCase(),
            anyOf(contains('failed'), contains('api key')),
          );
        }
      },
    );
  }

  test('Timeout is handled without live requests or real keys', () async {
    final groq = service((_) async => throw TimeoutException('simulated'));
    final result = await groq.generateRecipes(inventoryItems: inventory);
    expect(result['status'], 'error');
    expect(result['message'], contains('timed out'));
    expect(result['recipes'], isEmpty);
  });

  test('Network failure does not leak exception contents', () async {
    final groq = service(
      (_) async => throw http.ClientException('private details'),
    );
    final result = await groq.generateRecipes(inventoryItems: inventory);
    expect(result['status'], 'error');
    expect(result['message'], isNot(contains('private details')));
  });

  for (final invalid in [
    'not json',
    jsonEncode({'recipes': 'invalid'}),
    jsonEncode({
      'recipes': [
        {'title': 'Incomplete'},
      ],
    }),
  ]) {
    test(
      'Invalid provider content is rejected: ${invalid.length} characters',
      () async {
        final groq = service(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': invalid},
                },
              ],
            }),
            200,
          ),
        );
        final result = await groq.generateRecipes(inventoryItems: inventory);
        expect(result['status'], 'error');
        expect(result['recipes'], isEmpty);
        expect(result['message'], contains('invalid'));
      },
    );
  }

  test('Malformed completion envelopes are invalid responses', () async {
    final groq = service((_) async => http.Response('{"choices": []}', 200));
    final result = await groq.generateRecipes(inventoryItems: inventory);
    expect(result['status'], 'error');
    expect(result['message'], contains('invalid'));
  });

  test(
    'Provider output stays capped at the existing three-recipe maximum',
    () async {
      final result = await service(
        (_) async => success([
          recipe('One'),
          recipe('Two'),
          recipe('Three'),
          recipe('Four'),
        ]),
      ).generateRecipes(inventoryItems: inventory);
      expect(result['recipes'], hasLength(3));
    },
  );

  test('Legacy provider labels do not erase saved recipe names', () {
    expect(
      RecipeParser.title({'title': 'Generated by Legacy AI Omelette'}),
      'Omelette',
    );
  });

  test('Empty valid recipe list preserves restock-needed response', () async {
    final result = await service(
      (_) async => success([]),
    ).generateRecipes(inventoryItems: inventory);
    expect(result['status'], 'restock_needed');
    expect(result['recipes'], isEmpty);
  });

  test(
    'Groq JSON survives formatter, parser, history fields and skipped filtering',
    () async {
      SharedPreferences.setMockInitialValues({});
      final result = await service(
        (_) async => success([recipe('Omelette'), recipe('Egg Toast')]),
      ).generateRecipes(inventoryItems: inventory);
      final formatted = GroqRecipeFormatter().format(result);
      final recipes = SuggestionHelper().parseRecipes(formatted);
      expect(recipes.map(RecipeParser.title), ['Omelette', 'Egg Toast']);
      expect(RecipeParser.ingredients(RecipeParser.content(recipes.first)), [
        'Egg',
        'Missing / Restock: Salt',
      ]);
      expect(RecipeParser.steps(RecipeParser.content(recipes.first)), [
        'Beat the egg.',
        'Cook until set.',
      ]);
      expect(
        RecipeParser.why(RecipeParser.content(recipes.first)),
        'Use the egg before expiry.',
      );
      const skipped = SkippedRecipeService();
      await skipped.skipRecipe('Omelette');
      final visible = await skipped.filterSkippedRecipes(
        recipes: recipes,
        titleGetter: RecipeParser.title,
      );
      expect(visible.single['title'], 'Egg Toast');
      expect(visible.single['content'], contains('Ingredients Used:'));
      await skipped.clearSkippedRecipes();
      expect(await skipped.getSkippedRecipes(), isEmpty);
    },
  );

  test('Existing cached recipe heading formats remain readable', () {
    const text =
        'Recipe: Omelette\nIngredients Used:\n- Egg\nSteps:\n1. Cook.\nWhy Recommended:\nUse stock.\n\n---\nRecipe 2: Toast\nIngredients:\n- Bread\nSteps:\n1. Toast.\nWhy:\nUse bread.';
    final recipes = SuggestionHelper().parseRecipes(text);
    expect(recipes.map(RecipeParser.title), ['Omelette', 'Toast']);
    expect(RecipeParser.ingredients(recipes.last['content']!), ['Bread']);
    expect(RecipeParser.why(recipes.last['content']!), 'Use bread.');
  });

  test(
    'Application counter reset matches local midnight, including year end',
    () {
      final info = AiResetHelper.getResetInfo(
        now: DateTime(2026, 12, 31, 23, 30),
      );
      expect(info['countdown'], '0h 30m');
      expect(info['timeText'], contains('00:00 local time'));
    },
  );

  test('Local restock logic remains available without an AI provider', () {
    final item = InventoryItem(
      id: 'egg',
      name: 'Egg',
      category: 'Dairy',
      quantity: 1,
      expiryDate: tomorrow,
      imageUrl: '',
      createdAt: DateTime.now(),
    );
    final advice = LocalRestockFormatter().format([item]);
    expect(advice, contains('Ingredient: Egg'));
    expect(advice, contains('Current Quantity: 1'));
  });
}
