import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class GroqService {
  static const String _apiKey = '';

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

    try {
      final response = await http
          .post(
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
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final content = data['choices'][0]['message']['content'];

        return jsonDecode(content);
      }

      return _fallbackApiFailed(response.statusCode);
    } on TimeoutException {
      return _fallbackMessage(
        'Groq request timeout. Showing safe cafe recipe suggestion.',
      );
    } catch (_) {
      return _fallbackMessage(
        'Groq failed. Showing safe cafe recipe suggestion.',
      );
    }
  }

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
      if (expiryDate == null) return true;

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
      'message': 'No safe usable ingredients available.',
      'recipes': [],
    };
  }

  Map<String, dynamic> _fallbackApiFailed(int statusCode) {
    return _fallbackMessage(
      'Groq API error $statusCode. Showing safe cafe recipe suggestion.',
    );
  }

  Map<String, dynamic> _fallbackMessage(String message) {
    return {
      'status': 'fallback',
      'message': message,
      'recipes': [
        {
          'title': 'Egg Fried Rice',
          'ingredientsUsed': ['Egg', 'Rice'],
          'missingIngredients': ['Salt', 'Cooking oil'],
          'steps': [
            'Prepare cooked rice, egg, and any available cafe seasoning before starting.',
            'Heat a pan over medium heat and add a small amount of cooking oil if available.',
            'Crack the egg into the pan and stir until it begins to set.',
            'Add the cooked rice and mix well so the egg coats the rice evenly.',
            'Season lightly with salt or available seasoning, then continue stir-frying for 2 to 3 minutes.',
            'Check that the rice is hot and the egg is fully cooked before serving.',
            'Serve warm in a bowl or takeaway container for cafe service.',
          ],
          'whyRecommended':
              'This fallback recipe uses common cafe inventory items and helps reduce waste by using basic stock safely.',
        },
      ],
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
