class FakeRecipe {
  final String title, whyRecommended;
  final List<String> ingredientItemIds, steps;
  const FakeRecipe(
    this.title,
    this.ingredientItemIds,
    this.steps,
    this.whyRecommended,
  );
  // Schema v1 supplies IDs only. Quantities/units are deliberately absent.
}

class FakeRecipeResponse {
  final String requestId, status;
  final List<FakeRecipe> recipes;
  const FakeRecipeResponse(this.requestId, this.status, this.recipes);
  static bool _text(Object? value, int max) =>
      value is String &&
      value.isNotEmpty &&
      value.trim() == value &&
      value.length <= max &&
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);
  static bool _id(Object? value) =>
      _text(value, 128) &&
      value != '.' &&
      value != '..' &&
      !(value as String).contains('/') &&
      !value.contains('\\');
  factory FakeRecipeResponse.parse(
    Map<String, dynamic> data,
    String expected,
    int maxRecipes,
  ) {
    const keys = [
      'schemaVersion',
      'requestId',
      'provider',
      'status',
      'recipes',
    ];
    if (data.keys.any((key) => !keys.contains(key)) ||
        data.length != keys.length ||
        data['schemaVersion'] != 1 ||
        data['provider'] != 'fake' ||
        data['requestId'] != expected ||
        !['ok', 'no_suggestions'].contains(data['status']) ||
        data['recipes'] is! List)
      throw const FormatException('Invalid fake recipe response.');
    final rows = data['recipes'] as List;
    if (rows.length > maxRecipes || (data['status'] == 'ok') != rows.isNotEmpty)
      throw const FormatException('Invalid recipe status.');
    final recipes = <FakeRecipe>[];
    for (final row in rows) {
      if (row is! Map ||
          row.length != 4 ||
          row.keys.any(
            (key) => ![
              'title',
              'ingredientItemIds',
              'steps',
              'whyRecommended',
            ].contains(key),
          ) ||
          !_text(row['title'], 100) ||
          !_text(row['whyRecommended'], 300) ||
          row['ingredientItemIds'] is! List ||
          row['steps'] is! List)
        throw const FormatException('Invalid fake recipe.');
      final ids = row['ingredientItemIds'] as List,
          steps = row['steps'] as List;
      if (ids.isEmpty ||
          ids.length > 10 ||
          ids.any((id) => !_id(id)) ||
          ids.toSet().length != ids.length ||
          steps.isEmpty ||
          steps.length > 8 ||
          steps.any((step) => !_text(step, 300)))
        throw const FormatException('Invalid fake recipe.');
      recipes.add(
        FakeRecipe(
          row['title'],
          List.unmodifiable(ids.cast<String>()),
          List.unmodifiable(steps.cast<String>()),
          row['whyRecommended'],
        ),
      );
    }
    return FakeRecipeResponse(
      expected,
      data['status'],
      List.unmodifiable(recipes),
    );
  }
}
