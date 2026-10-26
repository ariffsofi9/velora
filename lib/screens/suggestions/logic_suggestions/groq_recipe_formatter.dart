class GroqRecipeFormatter {
  static const emptyHeading = 'No recipe suggestions available.';

  static bool isEmptyResult(String text) =>
      text.trimLeft().startsWith(emptyHeading);

  String format(Map<String, dynamic> result) {
    final recipes = result['recipes'];

    if (recipes is List && recipes.isEmpty && result['status'] != 'error') {
      final message = result['message']?.toString().trim() ?? '';
      return message.isEmpty ? emptyHeading : '$emptyHeading\n\n$message';
    }
    if (recipes is! List || recipes.isEmpty) {
      return result['message']?.toString() ??
          'No AI suggestion available from Groq.';
    }

    final buffer = StringBuffer();

    for (var i = 0; i < recipes.length; i++) {
      final recipe = recipes[i] as Map<String, dynamic>;

      final title = _cleanRecipeTitle(
        recipe['title']?.toString() ?? 'Recipe ${i + 1}',
      );

      final ingredientsUsed = _stringList(recipe['ingredientsUsed']);
      final missingIngredients = _stringList(recipe['missingIngredients']);
      final steps = _stringList(recipe['steps']);

      final whyRecommended =
          recipe['whyRecommended']?.toString() ??
          'Recommended to reduce waste and make better use of available cafe inventory.';

      buffer.writeln('### $title');
      buffer.writeln('');

      buffer.writeln('Ingredients Used:');
      if (ingredientsUsed.isEmpty) {
        buffer.writeln('- Inventory ingredients');
      } else {
        for (final item in ingredientsUsed) {
          buffer.writeln('- ${_cleanListItem(item)}');
        }
      }

      if (missingIngredients.isNotEmpty) {
        buffer.writeln('');
        buffer.writeln('Missing / Restock Ingredients:');

        for (final item in missingIngredients) {
          buffer.writeln('- ${_cleanListItem(item)}');
        }
      }

      buffer.writeln('');
      buffer.writeln('Steps:');

      if (steps.isEmpty) {
        buffer.writeln('1. Prepare all ingredients before cooking.');
        buffer.writeln('2. Follow the normal cafe preparation method.');
        buffer.writeln('3. Serve fresh to the customer.');
      } else {
        for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
          buffer.writeln('${stepIndex + 1}. ${_cleanStep(steps[stepIndex])}');
        }
      }

      buffer.writeln('');
      buffer.writeln('Why Recommended:');
      buffer.writeln(whyRecommended.trim());

      if (i != recipes.length - 1) {
        buffer.writeln('');
        buffer.writeln('---');
        buffer.writeln('');
      }
    }

    return buffer.toString().trim();
  }

  String _cleanRecipeTitle(String value) {
    return value
        .replaceAll(RegExp(r'^Recipe\s*\d+\s*:\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'^\d+\.\s*'), '')
        .trim();
  }

  String _cleanListItem(String value) {
    return value
        .replaceAll(RegExp(r'^[-•]\s*'), '')
        .replaceAll(RegExp(r'^\d+\.\s*'), '')
        .trim();
  }

  String _cleanStep(String value) {
    return value
        .replaceAll(RegExp(r'^\d+\.\s*'), '')
        .replaceAll(RegExp(r'^[-•]\s*'), '')
        .trim();
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }

    return [];
  }
}
