import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../logic/ai_recipe_save_service.dart';
import '../../../logic/suggestion_helper.dart';
import '../../../models/inventory_item.dart';
import '../../../widgets/suggestions/cache_notice.dart';
import '../../../widgets/suggestions/empty_card.dart';
import '../../../widgets/suggestions/inventory_changed_card.dart';
import '../../../widgets/suggestions/premium_loading_card.dart';
import '../../../widgets/suggestions/result_cards.dart';
import '../recipe_detail_page.dart';
import '../logic_suggestions/groq_recipe_formatter.dart';
import '../utils_suggestions/fallback_recipe_builder.dart';
import '../utils_suggestions/recipe_parser.dart';
import 'recipe_preview_card.dart';

class SuggestionAiResult extends StatelessWidget {
  final bool isLoading;
  final bool isRecipeResult;
  final bool isCached;
  final bool inventoryChanged;
  final String resultText;
  final List<InventoryItem> items;
  final SuggestionHelper helper;
  final AiRecipeSaveService recipeSaveService;
  final VoidCallback onRegenerate;

  const SuggestionAiResult({
    super.key,
    required this.isLoading,
    required this.isRecipeResult,
    required this.isCached,
    required this.inventoryChanged,
    required this.resultText,
    required this.items,
    required this.helper,
    required this.recipeSaveService,
    required this.onRegenerate,
  });

  bool _isErrorResult(String text) {
    final lower = text.toLowerCase();

    return lower.contains('failed') ||
        lower.contains('quota') ||
        lower.contains('rate limit') ||
        lower.contains('429') ||
        lower.contains('api key') ||
        lower.contains('try again') ||
        lower.contains('something went wrong') ||
        lower.contains('no ai suggestion');
  }

  void _openGeneratedRecipe(BuildContext context, Map<String, String> recipe) {
    final content = RecipeParser.content(recipe);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailPage(
          title: RecipeParser.title(recipe),
          ingredients: RecipeParser.ingredients(content),
          steps: RecipeParser.steps(content),
          nearExpiryIngredients: RecipeParser.nearExpiryNames(items),
          whyRecommended: RecipeParser.why(content),
        ),
      ),
    );
  }

  void _openSavedRecipe(BuildContext context, Map<String, dynamic> data) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailPage(
          title: data['title'] ?? 'Saved AI Recipe',
          ingredients: List<String>.from(data['ingredients'] ?? []),
          steps: List<String>.from(data['steps'] ?? []),
          nearExpiryIngredients: List<String>.from(
            data['nearExpiryIngredients'] ?? [],
          ),
          whyRecommended:
              data['whyRecommended'] ??
              'This recipe helps use available inventory items.',
        ),
      ),
    );
  }

  Widget _buildGeneratedCards(BuildContext context) {
    final recipes = helper.parseRecipes(resultText);

    if (recipes.isEmpty) {
      return EmptyCard(text: resultText);
    }

    return Column(
      children: recipes.map((recipe) {
        return RecipePreviewCard(
          title: RecipeParser.title(recipe),
          content: RecipeParser.content(recipe),
          onTap: () => _openGeneratedRecipe(context, recipe),
        );
      }).toList(),
    );
  }

  Widget _buildFallbackRecipeCard(BuildContext context) {
    final fallback = FallbackRecipeBuilder.buildRecipe(items);

    if (fallback == null) {
      return const EmptyCard(
        text: 'Add inventory items first to get recipe suggestions.',
      );
    }

    return RecipePreviewCard(
      title: fallback['title'] ?? 'Quick Inventory Recipe',
      content: fallback['content'] ?? '',
      badgeText: 'Demo fallback',
      onTap: () => _openSavedRecipe(context, fallback),
    );
  }

  Widget _buildRestockFallback() {
    return EmptyCard(text: FallbackRecipeBuilder.buildRestockText(items));
  }

  Widget _buildSavedOrFallback(BuildContext context, {String? notice}) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: recipeSaveService.savedRecipesStream(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EmptyCard(
                text:
                    notice ??
                    'No saved AI recipes yet. Showing demo-safe recipe.',
              ),
              const SizedBox(height: 12),
              _buildFallbackRecipeCard(context),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notice != null) EmptyCard(text: notice),
            ...docs.map((doc) {
              final data = doc.data();

              return RecipePreviewCard(
                title: data['title'] ?? 'Saved AI Recipe',
                content: data['content'] ?? '',
                badgeText: 'Saved',
                onTap: () => _openSavedRecipe(context, data),
              );
            }),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const PremiumLoadingCard();
    }

    if (isRecipeResult && GroqRecipeFormatter.isEmptyResult(resultText)) {
      return EmptyCard(text: resultText);
    }

    if (isRecipeResult && resultText.isEmpty) {
      return _buildSavedOrFallback(context);
    }

    if (!isRecipeResult && resultText.isEmpty) {
      return _buildRestockFallback();
    }

    if (_isErrorResult(resultText)) {
      if (isRecipeResult) {
        return _buildSavedOrFallback(context, notice: resultText);
      }

      return _buildRestockFallback();
    }

    return Column(
      children: [
        if (isCached) const CacheNotice(),
        if (inventoryChanged && isRecipeResult)
          InventoryChangedCard(onRegenerate: onRegenerate),
        if (isRecipeResult)
          _buildGeneratedCards(context)
        else
          ResultCards(
            results: helper.parseRecipes(resultText),
            inventoryItems: items,
            isRecipeResult: false,
            onCookRecipe: null,
          ),
      ],
    );
  }
}
