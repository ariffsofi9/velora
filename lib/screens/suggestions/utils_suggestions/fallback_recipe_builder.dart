import '../../../models/inventory_item.dart';

class FallbackRecipeBuilder {
  static Map<String, dynamic>? buildRecipe(List<InventoryItem> items) {
    final usable = _usableNames(items).take(3).toList();
    final expired = _expiredNames(items);

    if (usable.isEmpty) {
      return {
        'title': 'No Safe Recipe Available',
        'content': _noSafeRecipeContent(expired),
        'ingredients': <String>[],
        'steps': <String>[
          'Remove expired items from inventory.',
          'Add fresh stock before generating recipe suggestions.',
        ],
        'nearExpiryIngredients': <String>[],
        'whyRecommended':
            'Expired items are excluded because they are not safe for recipe suggestions.',
      };
    }

    final title = '${_titleCase(usable.take(2).join(' '))} Quick Stir Fry';

    return {
      'title': title,
      'content': _recipeContent(title, usable, expired),
      'ingredients': usable,
      'steps': [
        'Wash and prepare the ingredients.',
        'Cut the ingredients into small pieces.',
        'Heat a pan with a little oil.',
        'Cook the ingredients for a few minutes.',
        'Serve while hot.',
      ],
      'nearExpiryIngredients': usable,
      'whyRecommended':
          'This demo-safe recipe only uses non-expired inventory items.',
    };
  }

  static String buildRestockText(List<InventoryItem> items) {
    final usable = _usableNames(items);
    final expired = _expiredNames(items);

    return '''
Groq quota limit reached. Showing demo-safe restock suggestions based on your inventory.

Restock Suggestions:
- Review usable stock: ${usable.isEmpty ? 'No usable stock available' : usable.take(5).join(', ')}.
- Remove expired stock: ${expired.isEmpty ? 'No expired stock found' : expired.join(', ')}.
- Restock expired or low quantity items first.
- Avoid overbuying to reduce food waste.

This fallback excludes expired items from recipe suggestions.
''';
  }

  static List<String> _usableNames(List<InventoryItem> items) {
    return items
        .where((item) => !_isExpired(item))
        .map((item) => item.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
  }

  static List<String> _expiredNames(List<InventoryItem> items) {
    return items
        .where(_isExpired)
        .map((item) => item.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
  }

  static bool _isExpired(InventoryItem item) {
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    final expiryOnly = DateTime(
      item.expiryDate.year,
      item.expiryDate.month,
      item.expiryDate.day,
    );

    return expiryOnly.isBefore(todayOnly);
  }

  static String _recipeContent(
    String title,
    List<String> names,
    List<String> expired,
  ) {
    final expiredText = expired.isEmpty
        ? ''
        : '\n\nExpired items excluded:\n${expired.map((name) => '- $name').join('\n')}';

    return '''
$title

Ingredients:
${names.map((name) => '- $name').join('\n')}

Steps:
1. Wash and prepare the ingredients.
2. Cut the ingredients into small pieces.
3. Heat a pan with a little oil.
4. Cook the ingredients for a few minutes.
5. Serve while hot.

Why:
This recipe helps use non-expired available inventory items.$expiredText
''';
  }

  static String _noSafeRecipeContent(List<String> expired) {
    return '''
No safe recipe can be suggested right now.

Expired items:
${expired.isEmpty ? '- None' : expired.map((name) => '- $name').join('\n')}

Advice:
1. Do not use expired ingredients for recipes.
2. Remove expired stock from inventory.
3. Add fresh items before generating recipe suggestions.
''';
  }

  static String _titleCase(String text) {
    return text
        .split(' ')
        .where((word) => word.trim().isNotEmpty)
        .map((word) {
          final clean = word.trim();
          return clean[0].toUpperCase() + clean.substring(1).toLowerCase();
        })
        .join(' ');
  }
}
