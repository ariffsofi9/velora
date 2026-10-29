import '../../core/theme/app_tokens.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../logic/ai_cache_service.dart';
import '../../logic/ai_generate_service.dart';
import '../../logic/ai_inventory_checker.dart';
import '../../logic/ai_quota_service.dart';
import '../../logic/ai_recipe_save_service.dart';
import '../../logic/ai_reset_helper.dart';
import '../../logic/groq_service.dart';
import '../../logic/suggestion_helper.dart';
import '../../models/inventory_item.dart';

import '../../widgets/suggestions/quota_status_card.dart';
import '../../widgets/suggestions/suggestion_sections.dart';

import 'logic_suggestions/groq_recipe_formatter.dart';
import 'logic_suggestions/local_restock_formatter.dart';
import 'logic_suggestions/skipped_recipe_service.dart';
import 'restock_suggestion_service.dart';
import 'widgets_suggestions/restock_suggestion_card.dart';
import 'widgets_suggestions/suggestion_ai_result.dart';

part 'suggestions_foundation.dart';
part 'suggestions_generation.dart';

class SuggestionsPage extends StatefulWidget {
  const SuggestionsPage({super.key});

  @override
  State<SuggestionsPage> createState() => _SuggestionsPageState();
}

class _SuggestionsPageState extends _SuggestionsGeneration {
  @override
  void _handleAiError(String result) {
    final retrySeconds = _extractSeconds(result);

    if (retrySeconds > 0) {
      _startCooldown(retrySeconds);
    }

    setState(() {
      _resultText = result;
      _resultSignature = '';
      _isCached = false;
      _isLoading = false;
      _aiStatus = _statusFromError(result);
    });
  }

  @override
  Future<void> _saveGeneratedRecipes(
    String result,
    List<InventoryItem> items,
  ) async {
    if (GroqRecipeFormatter.isEmptyResult(result)) return;

    final recipes = _helper.parseRecipes(result);

    final savedCount = await _recipeSaveService.saveGeneratedRecipes(
      recipes: recipes,
      items: items,
      rawResult: result,
    );

    if (savedCount <= 0) return;

    final message = savedCount == 1
        ? 'New Groq AI recipe saved for later.'
        : '$savedCount new Groq AI recipes saved for later.';

    _showSnack(message);
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();

    setState(() => _cooldownSeconds = seconds);

    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_cooldownSeconds <= 1) {
        timer.cancel();

        if (mounted) {
          setState(() => _cooldownSeconds = 0);
        }

        return;
      }

      if (mounted) {
        setState(() => _cooldownSeconds--);
      }
    });
  }

  int _extractSeconds(String text) {
    final match = RegExp(r'(\d+)\sseconds').firstMatch(text);

    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  @override
  bool _isErrorResult(String text) {
    final lower = text.toLowerCase();

    return lower.contains('failed') ||
        lower.contains('rate limit') ||
        lower.contains('quota') ||
        lower.contains('api key') ||
        lower.contains('try again') ||
        lower.contains('something went wrong') ||
        lower.contains('no ai suggestion');
  }

  String _statusFromError(String text) {
    final lower = text.toLowerCase();

    if (lower.contains('quota') || lower.contains('rate limit')) {
      return 'Quota limited';
    }
    if (lower.contains('api key')) return 'API key error';
    if (lower.contains('network')) return 'Network error';

    return 'Temporary error';
  }

  @override
  void _showSnack(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _quotaService.remaining(_usedQuota);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('inventory')
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Inventory is unavailable. Check your connection and try again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              );
            }

            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              );
            }

            final items = _helper.convertDocs(snapshot.data!.docs);
            final nearExpiry = _helper.nearExpiryItems(items);

            final restockSuggestions = _restockService.generateSuggestions(
              snapshot.data!.docs,
            );

            WidgetsBinding.instance.addPostFrameCallback((_) {
              _autoLoadCache(items);
              _checkInventoryChanged(items);
            });

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 110),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SuggestionPageTitle(),
                      const SizedBox(height: 18),
                      QuotaStatusCard(
                        used: _usedQuota,
                        limit: AiQuotaService.dailyLimit,
                        remaining: remaining,
                        cooldownSeconds: _cooldownSeconds,
                        resetCountdown: _resetCountdown,
                        resetTimeText: _resetTimeText,
                        groqStatus: _aiStatus,
                      ),
                      const SizedBox(height: 18),
                      SuggestionActionButtons(
                        onRecipeTap: () => _generateRecipes(items),
                        onRestockTap: () => _generateRestock(items),
                      ),
                      const SizedBox(height: 26),
                      const SuggestionSectionTitle(title: 'Near Expiry Items'),
                      const SizedBox(height: 12),
                      NearExpirySection(
                        nearExpiry: nearExpiry,
                        daysLeftText: _helper.daysLeftText,
                      ),
                      if (restockSuggestions.isNotEmpty) ...[
                        const SizedBox(height: 26),
                        const SuggestionSectionTitle(
                          title: 'Smart Restock Suggestions',
                        ),
                        const SizedBox(height: 12),
                        ...restockSuggestions.map(
                          (suggestion) =>
                              RestockSuggestionCard(suggestion: suggestion),
                        ),
                      ],
                      const SizedBox(height: 26),
                      _RecipeMemoryHeader(
                        title: _isRecipeResult
                            ? 'AI Recipes'
                            : 'Restock Advice',
                        isRecipeResult: _isRecipeResult,
                        skippedCount: _skippedCount,
                        hasResult: _resultText.trim().isNotEmpty,
                        onSkip: _skipFirstVisibleRecipe,
                        onClear: _clearSkippedRecipes,
                      ),
                      const SizedBox(height: 12),
                      SuggestionAiResult(
                        isLoading: _isLoading,
                        isRecipeResult: _isRecipeResult,
                        isCached: _isCached,
                        inventoryChanged: _inventoryChanged,
                        resultText: _resultText,
                        items: items,
                        helper: _helper,
                        recipeSaveService: _recipeSaveService,
                        onRegenerate: () => _generateRecipes(items),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RecipeMemoryHeader extends StatelessWidget {
  final String title;
  final bool isRecipeResult;
  final int skippedCount;
  final bool hasResult;
  final VoidCallback onSkip;
  final VoidCallback onClear;

  const _RecipeMemoryHeader({
    required this.title,
    required this.isRecipeResult,
    required this.skippedCount,
    required this.hasResult,
    required this.onSkip,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    if (!isRecipeResult) {
      return SuggestionSectionTitle(title: title);
    }

    return Row(
      children: [
        Expanded(child: SuggestionSectionTitle(title: title)),
        if (hasResult)
          TextButton.icon(
            onPressed: onSkip,
            icon: const Icon(Icons.visibility_off_rounded, size: 16),
            label: const Text('Skip'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFEF4444),
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        if (skippedCount > 0)
          TextButton(
            onPressed: onClear,
            child: Text(
              'Reset ($skippedCount)',
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}
