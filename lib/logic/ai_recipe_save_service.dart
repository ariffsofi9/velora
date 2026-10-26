import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/inventory_item.dart';
import '../screens/suggestions/utils_suggestions/recipe_parser.dart';

class AiRecipeSaveService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _recipes =>
      _firestore.collection('ai_recipe_suggestions');

  Stream<QuerySnapshot<Map<String, dynamic>>> savedRecipesStream() {
    return _recipes
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots();
  }

  Future<int> saveGeneratedRecipes({
    required List<Map<String, String>> recipes,
    required List<InventoryItem> items,
    required String rawResult,
  }) async {
    final validRecipes = recipes.where((recipe) {
      final title = recipe['title']?.trim() ?? '';
      final content = recipe['content']?.trim() ?? '';
      return title.isNotEmpty && content.isNotEmpty;
    }).toList();

    if (validRecipes.isEmpty || _isBadResult(rawResult)) return 0;

    final batch = _firestore.batch();
    final inventorySnapshot = _inventorySnapshot(items);
    final nearExpiryNames = RecipeParser.nearExpiryNames(items);

    for (final recipe in validRecipes) {
      final content = RecipeParser.content(recipe);
      final doc = _recipes.doc();

      batch.set(doc, {
        'title': RecipeParser.title(recipe),
        'content': content,
        'ingredients': RecipeParser.ingredients(content),
        'steps': RecipeParser.steps(content),
        'nearExpiryIngredients': nearExpiryNames,
        'whyRecommended': RecipeParser.why(content),
        'inventorySnapshot': inventorySnapshot,
        'source': 'groq',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
    return validRecipes.length;
  }

  List<String> _inventorySnapshot(List<InventoryItem> items) {
    return items
        .map((item) => item.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
  }

  bool _isBadResult(String text) {
    final lower = text.toLowerCase();

    return lower.contains('failed') ||
        lower.contains('rate limit') ||
        lower.contains('quota') ||
        lower.contains('api key') ||
        lower.contains('try again') ||
        lower.contains('something went wrong') ||
        lower.contains('no ai suggestion');
  }
}
