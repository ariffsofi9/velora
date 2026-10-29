import '../../core/theme/app_tokens.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'logic_suggestions/cook_now_deduction_service.dart';

part 'recipe_detail_state.dart';
part 'recipe_detail_dialogs.dart';
part 'recipe_detail_hero.dart';
part 'recipe_detail_ingredients.dart';
part 'recipe_detail_sections.dart';

class RecipeDetailPage extends StatefulWidget {
  final String title;
  final List<String> ingredients;
  final List<String> steps;
  final List<String> nearExpiryIngredients;
  final String whyRecommended;

  const RecipeDetailPage({
    super.key,
    required this.title,
    required this.ingredients,
    required this.steps,
    required this.nearExpiryIngredients,
    required this.whyRecommended,
  });

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends _RecipeDetailDialogs {
  @override
  Widget build(BuildContext context) {
    final isSmall = MediaQuery.of(context).size.width < 370;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        title: const Text(
          'Recipe Details',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SizedBox(
            height: double.infinity,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                isSmall ? 16 : 20,
                8,
                isSmall ? 16 : 20,
                110,
              ),
              children: [
                _HeroCard(title: _cleanTitle, isSmall: isSmall),
                const SizedBox(height: 18),
                _SectionCard(
                  title:
                      'Ingredients (${_inventoryIngredients.length + _missingIngredients.length})',
                  icon: Icons.restaurant_menu_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _IngredientGroupTitle(
                        title: 'Inventory Ingredients',
                        count: _inventoryIngredients.length,
                        color: const Color(0xFF10B981),
                      ),
                      const SizedBox(height: 10),
                      if (_inventoryIngredients.isEmpty)
                        const _EmptyMiniCard(
                          text: 'No inventory ingredient listed.',
                        ),
                      ..._inventoryIngredients.map((ingredient) {
                        return _IngredientRow(
                          name: ingredient,
                          isNearExpiry: _isNearExpiry(ingredient),
                          isMissing: false,
                        );
                      }),
                      if (_missingIngredients.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _IngredientGroupTitle(
                          title: 'Missing / Restock Ingredients',
                          count: _missingIngredients.length,
                          color: const Color(0xFFF59E0B),
                        ),
                        const SizedBox(height: 10),
                        ..._missingIngredients.map((ingredient) {
                          return _IngredientRow(
                            name: ingredient,
                            isNearExpiry: false,
                            isMissing: true,
                          );
                        }),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _SectionCard(
                  title: 'Cooking Steps',
                  icon: Icons.list_alt_rounded,
                  child: Column(
                    children: List.generate(_cleanSteps.length, (index) {
                      return _StepRow(
                        number: index + 1,
                        text: _cleanSteps[index],
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 18),
                _WhyCard(text: widget.whyRecommended),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _CookNowBottomBar(
        isCooking: _isCooking,
        onPressed: _handleCookNow,
      ),
    );
  }
}
