import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/inventory_item.dart';
import '../screens/suggestions/utils_suggestions/recipe_parser.dart';

class SuggestionHelper {
  List<InventoryItem> convertDocs(List<QueryDocumentSnapshot> docs) {
    return docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;

      return InventoryItem(
        id: doc.id,
        name: data['name'] ?? '',
        category: data['category'] ?? '',
        quantity: (data['quantity'] as num?)?.toInt() ?? 0,
        expiryDate: data['expiryDate'] is Timestamp
            ? (data['expiryDate'] as Timestamp).toDate()
            : DateTime.now(),
        imageUrl: data['imageUrl'] ?? '',
        createdAt: data['createdAt'] is Timestamp
            ? (data['createdAt'] as Timestamp).toDate()
            : DateTime.now(),
      );
    }).toList();
  }

  List<InventoryItem> nearExpiryItems(List<InventoryItem> items) {
    final now = DateTime.now();

    final filtered = items.where((item) {
      final daysLeft = item.expiryDate.difference(now).inDays;
      return daysLeft <= 7;
    }).toList();

    filtered.sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
    return filtered.take(4).toList();
  }

  List<Map<String, String>> parseRecipes(String text) {
    final recipes = <Map<String, String>>[];
    final cleanedText = cleanAiText(text);
    // Accept both current headings and earlier cached recipe formats.
    final headings =
        RegExp(
              r'^[ \t]*(?:#{1,6}[ \t]+|Recipe[ \t]*(?:\d+)?[ \t]*:[ \t]*)([^\r\n]+?)[ \t]*$',
              multiLine: true,
              caseSensitive: false,
            )
            .allMatches(cleanedText)
            .where(
              (match) => !RegExp(
                r'^(?:ingredients(?: used)?|missing.*ingredients|steps|instructions|method|directions|why(?: recommended)?):?$',
                caseSensitive: false,
              ).hasMatch(match.group(1)!.trim()),
            )
            .toList();

    for (var i = 0; i < headings.length; i++) {
      final heading = headings[i];
      final end = i + 1 < headings.length
          ? headings[i + 1].start
          : cleanedText.length;
      final content = cleanedText
          .substring(heading.end, end)
          .replaceAll(RegExp(r'^\s*---\s*$', multiLine: true), '')
          .trim();
      final title = heading.group(1)!.trim();
      recipes.add({
        'title': RecipeParser.title({'title': title}),
        'content': content,
      });
    }

    if (recipes.isEmpty && RecipeParser.ingredients(cleanedText).isNotEmpty) {
      final lines = cleanedText.split('\n');
      recipes.add({
        'title': lines.first.trim(),
        'content': lines.skip(1).join('\n').trim(),
      });
    }

    return recipes;
  }

  List<InventoryItem> matchedIngredients(
    Map<String, String> recipe,
    List<InventoryItem> items,
  ) {
    final recipeText = '${recipe['title'] ?? ''} ${recipe['content'] ?? ''}'
        .toLowerCase();

    return items.where((item) {
      final name = item.name.toLowerCase().trim();

      if (name.isEmpty) return false;
      if (item.quantity <= 0) return false;

      return recipeText.contains(name);
    }).toList();
  }

  String daysLeftText(DateTime expiryDate) {
    final days = expiryDate.difference(DateTime.now()).inDays;

    if (days < 0) return 'Expired';
    if (days == 0) return 'Expires today';
    if (days == 1) return 'Expires tomorrow';
    return 'Expires in $days days';
  }

  String cleanAiText(String text) {
    return text
        .replaceAll('**', '')
        .replaceAll('*', '')
        .replaceAll('`', '')
        .replaceAll('####', '')
        .replaceAll('### ', '### ')
        .trim();
  }
}
