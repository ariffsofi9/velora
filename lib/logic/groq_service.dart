import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class GroqService {
  final String _apiKey;
  final http.Client? _client;
  final Duration _timeout;

  // No credential is bundled in the app. Direct API injection supports tests
  // and trusted callers; production requests need an authenticated backend.
  GroqService({
    String apiKey = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) : _apiKey = apiKey,
       _client = client,
       _timeout = timeout;

  static const String _baseUrl =
      'https://api.groq.com/openai/v1/chat/completions';

  static const String _model = 'llama-3.1-8b-instant';

  Future<Map<String, dynamic>> generateRecipes({
    required List<Map<String, dynamic>> inventoryItems,
  }) async {
    final usableItems = _getUsableItems(inventoryItems);

    if (usableItems.isEmpty) {
      return _fallbackNoSafeRecipe();
    }

    if (_apiKey.trim().isEmpty) {
      return _error('Groq service is not configured. Please try again later.');
    }

    try {
      final send = _client?.post ?? http.post;
      final response = await send(
        Uri.parse(_baseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {'role': 'system', 'content': _systemPrompt()},
            {'role': 'user', 'content': _buildRecipePrompt(usableItems)},
          ],
          'temperature': 0.25,
          'max_tokens': 1600,
          'response_format': {'type': 'json_object'},
        }),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is! Map<String, dynamic> ||
            data['choices'] is! List ||
            (data['choices'] as List).isEmpty) {
          throw const FormatException('Missing completion');
        }
        final choice = data['choices'][0];
        if (choice is! Map ||
            choice['message'] is! Map ||
            choice['message']['content'] is! String) {
          throw const FormatException('Invalid completion');
        }
        final content = choice['message']['content'] as String;

        return _validateResult(
          jsonDecode(content),
          _getUsableItems(inventoryItems),
        );
      }

      if (response.statusCode == 429) {
        final seconds =
            (int.tryParse(response.headers['retry-after'] ?? '') ?? 60).clamp(
              1,
              3600,
            );
        return _error(
          'Groq rate limit reached. Please wait $seconds seconds before generating again.',
        );
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        return _error('Groq API key error. Please try again later.');
      }
      return _error(
        'Groq failed to generate recipes (HTTP ${response.statusCode}). Please try again later.',
      );
    } on TimeoutException {
      return _error('Groq request timed out. Please try again later.');
    } on FormatException {
      return _error(
        'Groq returned an invalid recipe response. Please try again.',
      );
    } catch (_) {
      return _error('Groq network request failed. Please try again later.');
    }
  }

  Map<String, dynamic> _error(String message) => {
    'status': 'error',
    'message': message,
    'recipes': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> _validateResult(
    dynamic value,
    List<Map<String, dynamic>> usableItems,
  ) {
    if (value is! Map<String, dynamic> || value['recipes'] is! List) {
      throw const FormatException('Invalid recipe envelope');
    }
    final usableNames = {
      for (final item in usableItems)
        _ingredientName(item['name'].toString()): item['name']
            .toString()
            .trim(),
    };
    final recipes = <Map<String, dynamic>>[];
    for (final recipe in (value['recipes'] as List).take(3)) {
      if (recipe is! Map<String, dynamic>) {
        throw const FormatException('Invalid recipe');
      }
      String text(String key) {
        final value = recipe[key];
        if (value is! String || value.trim().isEmpty) {
          throw const FormatException('Missing recipe text');
        }
        return value.trim();
      }

      List<String> list(String key, {bool optional = false}) {
        final value = recipe[key];
        if (value == null && optional) return [];
        if (value is! List ||
            value.any((item) => item is! String || item.trim().isEmpty)) {
          throw const FormatException('Invalid recipe list');
        }
        if (!optional && value.isEmpty) {
          throw const FormatException('Empty recipe list');
        }
        return value.cast<String>().map((item) => item.trim()).toList();
      }

      final claimedIngredients = list('ingredientsUsed');
      if (claimedIngredients.any(
        (name) => !usableNames.containsKey(_ingredientName(name)),
      )) {
        throw const FormatException('Recipe claims unavailable inventory');
      }
      recipes.add({
        'title': text('title'),
        'ingredientsUsed': claimedIngredients
            .map((name) => usableNames[_ingredientName(name)]!)
            .toSet()
            .toList(),
        'missingIngredients': list('missingIngredients', optional: true),
        'steps': list('steps'),
        'whyRecommended': text('whyRecommended'),
      });
    }
    return {
      'status': recipes.isEmpty ? 'restock_needed' : 'success',
      'message': value['message'] is String
          ? value['message']
          : recipes.isEmpty
          ? 'Not enough usable ingredients for a recipe.'
          : 'Generated cafe recipe suggestions.',
      'recipes': recipes,
    };
  }

  String _ingredientName(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  List<Map<String, dynamic>> _getUsableItems(
    List<Map<String, dynamic>> inventoryItems,
  ) {
    final today = DateTime.now();

    final usableItems = inventoryItems.where((item) {
      final name = item['name']?.toString().trim() ?? '';
      final quantity = _toInt(item['quantity']);
      final expiryDate = _toDateTime(item['expiryDate']);

      if (name.isEmpty) return false;
      if (quantity <= 0) return false;
      if (expiryDate == null) return false;

      final expiryOnly = DateTime(
        expiryDate.year,
        expiryDate.month,
        expiryDate.day,
      );

      final todayOnly = DateTime(today.year, today.month, today.day);

      return !expiryOnly.isBefore(todayOnly);
    }).toList();

    usableItems.sort((a, b) {
      final aDate = _toDateTime(a['expiryDate']);
      final bDate = _toDateTime(b['expiryDate']);

      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;

      return aDate.compareTo(bDate);
    });

    return usableItems;
  }

  String _systemPrompt() {
    return '''
You are Velora AI, a professional cafe chef and smart food inventory assistant for a small cafe or small F&B business.

You must return ONLY valid JSON.
Do not use markdown.
Do not add explanation outside JSON.

Main goal:
Generate realistic cafe-suitable recipe suggestions using safe usable inventory ingredients.

Recipe quality rules:
- Generate ONLY real, common, existing recipe names used in real cooking or cafe menus.
- Do NOT invent fake recipe names.
- Do NOT create random names such as "Inventory Mix", "Cafe Fresh Bowl", "AI Special", or "Smart Stock Stir".
- Recipe names must sound natural, for example:
  "Tortilla Pizza", "Egg Fried Rice", "Egg Mayo Sandwich", "Chicken Wrap",
  "Garlic Butter Toast", "Tomato Omelette", "Cheese Toast",
  "Creamy Mushroom Pasta", "Banana Pancake", "Fruit Yogurt Cup".

Cafe scope rules:
- Recipes must be suitable for a small cafe, bakery, dessert shop, beverage shop, or light F&B menu.
- Suitable categories include sandwiches, wraps, toast, pasta, rice meals, breakfast food, pastries, cakes, desserts, simple snacks, and cafe beverages.
- Avoid recipes that are too complex, too fancy, too restaurant-heavy, or unrelated to cafe operations.

Inventory safety rules:
- Expired ingredients are already removed.
- Quantity 0 ingredients are already removed.
- Use inventory ingredients as the main recipe base.
- Prioritize near-expiry ingredients first.
- Do not suggest a recipe if most main ingredients are missing.
- Missing ingredients must be optional, small, or realistic restock items only.
- If the inventory is not enough for a real recipe, return fewer recipes or an empty recipes list with a restock message.
- Do not force fake recipes just to reach 3 recipes.

Output rules:
- Maximum 3 recipes only.
- Each recipe must have a clean title only, without numbering.
- ingredientsUsed must contain only ingredients from the provided inventory.
- missingIngredients can contain optional restock ingredients only.
- Steps must be clear, complete, and practical for cafe staff.
- Each recipe should have 5 to 8 clear preparation steps.
- whyRecommended must explain how the recipe uses available stock or reduces waste.
''';
  }

  String _buildRecipePrompt(List<Map<String, dynamic>> usableItems) {
    final inventoryText = usableItems.map((item) {
      final name = item['name'] ?? '';
      final quantity = _toInt(item['quantity']);
      final category = item['category'] ?? 'Unknown';
      final expiryDate = _toDateTime(item['expiryDate']);
      final daysLeft = _daysLeft(expiryDate);

      return {
        'name': name,
        'quantity': quantity,
        'category': category,
        'daysLeft': daysLeft,
      };
    }).toList();

    return '''
Generate cafe recipe suggestions using this usable inventory:

${jsonEncode(inventoryText)}

Return JSON exactly in this structure:

{
  "status": "success",
  "message": "Generated cafe recipe suggestions.",
  "recipes": [
    {
      "title": "Real cafe recipe name",
      "ingredientsUsed": ["ingredient from inventory"],
      "missingIngredients": ["optional missing or restock ingredient"],
      "steps": [
        "Prepare the ingredients clearly.",
        "Explain the cooking or preparation process clearly.",
        "Continue with practical cafe preparation steps.",
        "Finish with serving or storage instruction."
      ],
      "whyRecommended": "Explain how this recipe reduces food waste or uses available cafe stock."
    }
  ]
}

Strict rules:
- Maximum 3 recipes only.
- Recipe title must be clean, for example "Tortilla Pizza", not "Recipe 1: Tortilla Pizza" and not "1. Tortilla Pizza".
- Suggest only real cafe-suitable recipes that exist in normal cooking references.
- Use inventory ingredients only in ingredientsUsed.
- Do not place missing ingredients inside ingredientsUsed.
- Do not use expired ingredients.
- Do not use quantity 0 ingredients.
- Prioritize ingredients with lowest daysLeft.
- Missing ingredients must be realistic restock items only, such as cheese, tomato sauce, bread, cream, butter, or seasoning.
- Do not suggest a recipe if the key main ingredient is missing.
- If only a small optional ingredient is missing, include it in missingIngredients.
- If there are not enough ingredients for a real cafe recipe, return:
{
  "status": "restock_needed",
  "message": "Not enough usable ingredients to generate a safe real cafe recipe. Please restock key ingredients first.",
  "recipes": []
}
- Cooking steps must be detailed enough for a cafe worker to follow.
- Do not write simple steps like "cook and serve" only.
- Each recipe should include 5 to 8 clear steps.
- Do not repeat recipe titles.
''';
  }

  Map<String, dynamic> _fallbackNoSafeRecipe() {
    return {
      'status': 'empty',
      'message': 'No AI suggestion available: no safe usable ingredients.',
      'recipes': [],
    };
  }

  int _toInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  DateTime? _toDateTime(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) return value;

    try {
      return value.toDate();
    } catch (_) {
      return null;
    }
  }

  int? _daysLeft(DateTime? expiryDate) {
    if (expiryDate == null) return null;

    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    final expiryOnly = DateTime(
      expiryDate.year,
      expiryDate.month,
      expiryDate.day,
    );

    return expiryOnly.difference(todayOnly).inDays;
  }
}
