/// Standalone schema-v2 contract. No transport, Firebase or UI activation.
class GroqRecipeIngredient {
  final String itemId, unit;
  final num quantity;
  const GroqRecipeIngredient._(this.itemId, this.quantity, this.unit);
}

class GroqRecipe {
  final String title, whyRecommended;
  final List<GroqRecipeIngredient> ingredients;
  final List<String> steps;
  const GroqRecipe._(
    this.title,
    this.whyRecommended,
    this.ingredients,
    this.steps,
  );
}

class GroqRecipeResponse {
  final String requestId, status;
  final List<GroqRecipe> recipes;
  const GroqRecipeResponse._(this.requestId, this.status, this.recipes);

  static Never _invalid() =>
      throw const FormatException('Invalid Groq recipe response.');
  static bool _text(Object? value, int max) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= max &&
      value.trim() == value &&
      !RegExp(
        r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
      ).hasMatch(value);
  static bool _id(Object? value) =>
      _text(value, 128) &&
      value != '.' &&
      value != '..' &&
      !(value as String).contains('/') &&
      !value.contains('\\');
  static Map<dynamic, dynamic> _fields(Object? value, List<String> keys) {
    if (value is! Map ||
        value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key))) {
      _invalid();
    }
    return value;
  }

  factory GroqRecipeResponse.parse(
    Object? value,
    String expectedRequestId,
    int maxRecipes,
  ) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(expectedRequestId) ||
        maxRecipes < 1 ||
        maxRecipes > 3) {
      _invalid();
    }
    final data = _fields(value, [
      'schemaVersion',
      'requestId',
      'provider',
      'status',
      'recipes',
    ]);
    if (data['schemaVersion'] is! int ||
        data['schemaVersion'] != 2 ||
        data['provider'] != 'groq' ||
        data['requestId'] != expectedRequestId ||
        !['ok', 'no_suggestions'].contains(data['status'])) {
      _invalid();
    }
    final rows = data['recipes'];
    if (rows is! List ||
        rows.length > maxRecipes ||
        (data['status'] == 'ok') != rows.isNotEmpty) {
      _invalid();
    }
    final recipes = <GroqRecipe>[];
    for (final value in rows) {
      final row = _fields(value, [
        'title',
        'ingredients',
        'steps',
        'whyRecommended',
      ]);
      if (!_text(row['title'], 100) || !_text(row['whyRecommended'], 300)) {
        _invalid();
      }
      final ingredients = row['ingredients'], steps = row['steps'];
      if (ingredients is! List ||
          ingredients.isEmpty ||
          ingredients.length > 10 ||
          steps is! List ||
          steps.isEmpty ||
          steps.length > 8 ||
          steps.any((step) => !_text(step, 300))) {
        _invalid();
      }
      final parsed = <GroqRecipeIngredient>[];
      final seen = <String>{};
      for (final value in ingredients) {
        final ingredient = _fields(value, ['itemId', 'quantity', 'unit']);
        final id = ingredient['itemId'],
            quantity = ingredient['quantity'],
            unit = ingredient['unit'];
        if (!_id(id) ||
            quantity is! num ||
            !quantity.isFinite ||
            quantity <= 0 ||
            quantity > 1000000 ||
            !['kg', 'g', 'L', 'ml', 'pcs'].contains(unit) ||
            (unit == 'pcs' && quantity != quantity.truncateToDouble()) ||
            !seen.add(id as String)) {
          _invalid();
        }
        parsed.add(GroqRecipeIngredient._(id, quantity, unit as String));
      }
      recipes.add(
        GroqRecipe._(
          row['title'] as String,
          row['whyRecommended'] as String,
          List.unmodifiable(parsed),
          List.unmodifiable(steps.cast<String>()),
        ),
      );
    }
    // Stock availability and inventory ownership remain backend authority.
    return GroqRecipeResponse._(
      expectedRequestId,
      data['status'] as String,
      List.unmodifiable(recipes),
    );
  }
}
