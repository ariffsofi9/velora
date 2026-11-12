import '../../core/theme/app_tokens.dart';
import 'dart:async';

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
import '../../repositories/workspace_inventory_repository.dart';
import '../../services/workspace_session.dart';
import '../../services/secure_ai_service.dart';
import 'widgets_suggestions/secure_ai_suggestions.dart';
import '../../services/firebase_emulator_config.dart';
import 'widgets_suggestions/ai1_mock_recipe_content.dart';

import '../../widgets/suggestions/empty_card.dart';
import '../../widgets/suggestions/suggestion_sections.dart';

import 'logic_suggestions/groq_recipe_formatter.dart';
import 'logic_suggestions/local_restock_formatter.dart';
import 'logic_suggestions/skipped_recipe_service.dart';
import 'restock_suggestion_service.dart';
import 'widgets_suggestions/recipe_suggestions_content.dart';

part 'suggestions_foundation.dart';
part 'suggestions_generation.dart';

class SuggestionsPage extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final SecureAiService? aiService;

  const SuggestionsPage({
    super.key,
    this.workspaceSession,
    this.repository,
    this.aiService,
  });

  @override
  State<SuggestionsPage> createState() => _SuggestionsPageState();
}

class _SuggestionsPageState extends _SuggestionsGeneration {
  WorkspaceInventoryRepository? _repository;
  Stream<List<InventoryItem>>? _itemsStream;

  @override
  void initState() {
    _configureInventory();
    super.initState();
  }

  bool get _verified =>
      widget.workspaceSession?.isActive == true &&
      identical(_repository?.session, widget.workspaceSession);

  void _configureInventory() {
    final session = widget.workspaceSession;
    _repository = widget.repository;
    if (_repository == null && session?.isActive == true) {
      _repository = WorkspaceInventoryRepository(session: session!);
    }
    _itemsStream = _verified ? _repository!.watchItems() : null;
  }

  @override
  void didUpdateWidget(covariant SuggestionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.repository, widget.repository)) {
      _configureInventory();
    }
  }

  void _retryInventory() {
    if (!_verified) return;
    setState(() => _itemsStream = _repository!.watchItems());
  }

  @override
  Future<void> _loadQuota() async {}

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
  ) async {}

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
    final itemsStream = _itemsStream;
    if (!_verified || itemsStream == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'AI Insights is unavailable because workspace access was not verified.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: StreamBuilder<List<InventoryItem>>(
          stream: itemsStream,
          builder: (context, snapshot) {
            if (snapshot.hasError &&
                snapshot.connectionState != ConnectionState.waiting) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Inventory is unavailable. Check your connection and try again.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        key: const ValueKey('discover-inventory-retry'),
                        onPressed: _verified ? _retryInventory : null,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (!snapshot.hasData ||
                snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              );
            }

            final items = snapshot.data!;
            final nearExpiry = _helper.nearExpiryItems(items);
            final restockSuggestions = _restockService.generateSuggestions(
              items,
            );

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    MediaQuery.sizeOf(context).width < 375 ? 16 : 18,
                    18,
                    MediaQuery.sizeOf(context).width < 375 ? 16 : 18,
                    110,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SuggestionPageTitle(),
                      const SizedBox(height: 18),
                      if (widget.aiService != null)
                        SecureAiSuggestions(
                          key: ObjectKey(widget.aiService),
                          workspaceSession: widget.workspaceSession,
                          service: widget.aiService!,
                        )
                      else if (FirebaseEmulatorConfig.ai1Mock)
                        Ai1MockRecipeContent(
                          workspaceSession: widget.workspaceSession,
                        )
                      else
                        RecipeSuggestionsContent(
                          workspaceSession: widget.workspaceSession,
                        ),
                      const SizedBox(height: AppSpacing.xl),
                      const SuggestionSectionTitle(title: 'Inventory Insights'),
                      const SizedBox(height: AppSpacing.lg),
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
                              LocalRestockReminder(suggestion: suggestion),
                        ),
                      ],
                      const SizedBox(height: 26),
                      if (items.isEmpty)
                        const EmptyCard(
                          text: 'Add inventory items first to get AI insights.',
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
