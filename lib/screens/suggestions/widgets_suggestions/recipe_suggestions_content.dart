import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import '../../../models/fake_recipe_response.dart';
import '../../../services/fake_recipe_client.dart';
import '../../../services/workspace_session.dart';

import '../../../core/theme/app_tokens.dart';
import '../restock_suggestion_service.dart';

/// The existing local recommendation data, rendered without fixed-width chips.
class LocalRestockReminder extends StatelessWidget {
  final RestockSuggestion suggestion;
  const LocalRestockReminder({super.key, required this.suggestion});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(suggestion.itemName, style: text.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(suggestion.priorityLabel, style: text.bodySmall),
              const SizedBox(height: AppSpacing.sm),
              Text(suggestion.reason, style: text.bodyMedium),
              const SizedBox(height: AppSpacing.sm),
              Text(suggestion.suggestion, style: text.bodyMedium),
              const SizedBox(height: AppSpacing.md),
              Text(
                '${suggestion.quantity} in stock · ${suggestion.category}',
                style: text.bodySmall,
              ),
              if (suggestion.daysLeft != null)
                Text(
                  suggestion.daysLeft! < 0
                      ? 'Expired'
                      : suggestion.daysLeft == 0
                      ? 'Expires today'
                      : '${suggestion.daysLeft} day${suggestion.daysLeft == 1 ? '' : 's'} left',
                  style: text.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Presentation data only. No legacy recipe parser, provider or persistence.
class RecipePresentation {
  final String title;
  final String? description;
  final List<RecipeIngredientPresentation> ingredients;
  final List<String> preparation;
  final List<String> instructions;
  final ImageProvider? image;
  final String? imageDescription;
  final String? metadata;

  const RecipePresentation({
    required this.title,
    this.description,
    required this.ingredients,
    this.preparation = const [],
    this.instructions = const [],
    this.image,
    this.imageDescription,
    this.metadata,
  });

  factory RecipePresentation.fromFake(FakeRecipe recipe) => RecipePresentation(
    title: recipe.title,
    description: recipe.whyRecommended,
    metadata:
        'Fake emulator recipe • Not AI-generated. Quantities and units are not supplied.',
    ingredients: [
      for (final id in recipe.ingredientItemIds)
        RecipeIngredientPresentation('Ingredient ID: $id', '', ''),
    ],
    instructions: recipe.steps,
  );
}

class RecipeIngredientPresentation {
  final String name;
  // Preserve supplied quantity text, including decimals, without rounding.
  final String quantity;
  final String unit;
  const RecipeIngredientPresentation(this.name, this.quantity, this.unit);
}

const sampleRecipe = RecipePresentation(
  title: 'Banana oat smoothie',
  description:
      'A simple banana and oat drink. This sample is not based on your inventory.',
  ingredients: [
    RecipeIngredientPresentation('Banana', '1', 'pcs'),
    RecipeIngredientPresentation('Milk', '200', 'ml'),
    RecipeIngredientPresentation('Oats', '30', 'g'),
  ],
  preparation: ['Peel the banana and measure the milk and oats.'],
  instructions: [
    'Place the banana, milk and oats in a blender. Secure the lid.',
    'Blend until the oats are finely broken down and the mixture is smooth.',
    'Pour into a glass and serve immediately.',
  ],
);

enum RecipeDemoState { initial, loading, results, empty, error }

class RecipeSuggestionsContent extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  // Dependency injection for offline tests; profile/client guards still apply.
  final FakeRecipeClient? client;
  const RecipeSuggestionsContent({
    super.key,
    this.workspaceSession,
    this.client,
  });

  @override
  State<RecipeSuggestionsContent> createState() =>
      _RecipeSuggestionsContentState();
}

class _RecipeSuggestionsContentState extends State<RecipeSuggestionsContent> {
  RecipeDemoState? _demo;
  RecipeDemoState _state = RecipeDemoState.initial;
  List<FakeRecipe> _recipes = const [];
  FakeRecipeClient? _client;
  StreamSubscription<Object?>? _authSubscription;
  int _generation = 0;
  String? _message;
  bool get _available => _client?.isAvailable ?? false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    if (!FakeRecipeClient.profileEnabled || widget.workspaceSession == null) {
      return;
    }
    final candidate =
        widget.client ?? FakeRecipeClient(session: widget.workspaceSession!);
    final session = widget.workspaceSession!;
    if (candidate.session.uid != session.uid ||
        candidate.session.cafeId != session.cafeId ||
        candidate.session.ownerUid != session.ownerUid ||
        candidate.session.role != session.role) {
      return;
    }
    _client = candidate;
    if (!_client!.isAvailable) return;
    var uid = widget.workspaceSession!.uid;
    _authSubscription = _client!.authChanges.listen(
      (user) {
        if (user?.uid == uid) return;
        uid = user?.uid ?? '';
        if (!mounted) return;
        setState(() {
          _generation++;
          _recipes = const [];
          _state = RecipeDemoState.error;
          _message = 'Workspace access changed. Reopen Recipe Suggestions.';
        });
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() {
          _generation++;
          _recipes = const [];
          _state = RecipeDemoState.error;
          _message =
              'Workspace access could not be verified. Reopen Recipe Suggestions.';
        });
      },
    );
  }

  @override
  void didUpdateWidget(covariant RecipeSuggestionsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceSession != widget.workspaceSession ||
        oldWidget.client != widget.client) {
      _generation++;
      _authSubscription?.cancel();
      _authSubscription = null;
      _client = null;
      _recipes = const [];
      _state = RecipeDemoState.initial;
      _message = null;
      _connect();
    }
  }

  @override
  void dispose() {
    _generation++;
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    if (!_available || _state == RecipeDemoState.loading) return;
    final generation = ++_generation;
    setState(() {
      _demo = null;
      _recipes = const [];
      _message = null;
      _state = RecipeDemoState.loading;
    });
    try {
      final random = Random.secure();
      final requestId =
          'ui-${List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join()}';
      final response = await _client!
          .generate(requestId: requestId)
          .timeout(const Duration(seconds: 40));
      if (!mounted || generation != _generation) return;
      setState(() {
        _recipes = response.recipes;
        _state = _recipes.isEmpty
            ? RecipeDemoState.empty
            : RecipeDemoState.results;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _recipes = const [];
        _state = RecipeDemoState.error;
        _message =
            'Fake recipes could not be loaded. Check workspace access and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Recipes for your café', style: text.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _available
                      ? 'Isolated fake recipe demo. No AI provider is called and no inventory is changed.'
                      : 'Recipe generation is not available yet. Explore a sample recipe while inventory insights remain available.',
                  style: text.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: _available && _state != RecipeDemoState.loading
                      ? _generate
                      : null,
                  child: const Text('Generate Recipes'),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  key: const ValueKey('preview-sample-recipes'),
                  onPressed: () =>
                      setState(() => _demo = RecipeDemoState.results),
                  child: const Text('Preview sample recipes'),
                ),
                const OutlinedButton(
                  onPressed: null,
                  child: Text('Restock Advice'),
                ),
              ],
            ),
          ),
        ),
        if (_state != RecipeDemoState.initial) ...[
          const SizedBox(height: AppSpacing.lg),
          if (_state == RecipeDemoState.loading)
            const Column(
              children: [
                CircularProgressIndicator(),
                Text('Loading fake recipes…'),
              ],
            ),
          if (_state == RecipeDemoState.empty)
            const Text('No fake recipes match the eligible inventory.'),
          if (_state == RecipeDemoState.error) ...[
            Text(_message!),
            OutlinedButton(
              onPressed: _available ? _generate : null,
              child: const Text('Retry recipes'),
            ),
          ],
          if (_state == RecipeDemoState.results) ...[
            Text('Fake Recipes', style: text.titleLarge),
            for (final recipe in _recipes)
              Card(
                child: ListTile(
                  title: Text(recipe.title),
                  subtitle: const Text(
                    'Fake emulator recipe • Ingredient IDs only\nView recipe',
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppColors.primary,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RecipePresentationDetails(
                        recipe: RecipePresentation.fromFake(recipe),
                        isDemo: false,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
        if (_demo != null) ...[
          const SizedBox(height: AppSpacing.xl),
          Text('Presentation demo', style: text.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Sample data only. No AI request is made and no inventory is changed.',
            style: text.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<RecipeDemoState>(
            key: ValueKey(_demo),
            initialValue: _demo,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Preview state'),
            items: [
              for (final state in RecipeDemoState.values)
                DropdownMenuItem(value: state, child: Text(_stateLabel(state))),
            ],
            onChanged: (state) => setState(() => _demo = state),
          ),
          const SizedBox(height: AppSpacing.lg),
          RecipeDemoResult(
            state: _demo!,
            onRetry: () => setState(() => _demo = RecipeDemoState.results),
          ),
          TextButton(
            onPressed: () => setState(() => _demo = null),
            child: const Text('Close preview'),
          ),
        ],
      ],
    );
  }
}

String _stateLabel(RecipeDemoState state) => switch (state) {
  RecipeDemoState.initial => 'Initial',
  RecipeDemoState.loading => 'Loading',
  RecipeDemoState.results => 'Results',
  RecipeDemoState.empty => 'Empty',
  RecipeDemoState.error => 'Error',
};

class RecipeDemoResult extends StatelessWidget {
  final RecipeDemoState state;
  final VoidCallback? onRetry;
  const RecipeDemoResult({super.key, required this.state, this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (state == RecipeDemoState.results) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Suggested Recipes',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(AppSpacing.lg),
              title: Text(sampleRecipe.title),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: AppSpacing.sm),
                child: Text('Sample recipe • 3 ingredients\nView recipe'),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: AppColors.primary,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const RecipePresentationDetails(recipe: sampleRecipe),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state == RecipeDemoState.loading) ...[
              Semantics(
                label: 'Demo loading state',
                child: const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Text(switch (state) {
              RecipeDemoState.initial =>
                'Your sample recipe preview will appear here.',
              RecipeDemoState.loading => 'Loading sample preview…',
              RecipeDemoState.empty =>
                'No sample recipes to show in this preview.',
              RecipeDemoState.error =>
                'Sample preview could not be displayed. Try the preview again.',
              RecipeDemoState.results => '',
            }),
            if (state == RecipeDemoState.error && onRetry != null) ...[
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Retry preview'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A separate read-only route: never enters legacy RecipeDetailPage/Cook Now.
class RecipePresentationDetails extends StatelessWidget {
  final RecipePresentation recipe;
  final bool isDemo;
  const RecipePresentationDetails({
    super.key,
    required this.recipe,
    this.isDemo = true,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Recipe Details')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 375 ? 16 : 18,
            ),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: recipe.image == null
                      ? const _MissingRecipeImage()
                      : Image(
                          image: recipe.image!,
                          fit: BoxFit.cover,
                          semanticLabel:
                              recipe.imageDescription ?? recipe.title,
                          errorBuilder: (_, _, _) =>
                              const _MissingRecipeImage(),
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              if (isDemo) ...[
                Text(
                  'Sample recipe • Presentation demo',
                  style: text.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              Text(recipe.title, style: text.headlineMedium),
              if (recipe.description?.trim().isNotEmpty ?? false) ...[
                const SizedBox(height: AppSpacing.md),
                Text(recipe.description!, style: text.bodyLarge),
              ],
              if (recipe.metadata?.trim().isNotEmpty ?? false) ...[
                const SizedBox(height: AppSpacing.md),
                Text(recipe.metadata!, style: text.bodySmall),
              ],
              const SizedBox(height: AppSpacing.xl),
              _RecipeSection(
                title: 'Ingredients',
                children: [
                  if (recipe.ingredients.isEmpty)
                    const Text('No ingredients supplied.'),
                  for (final ingredient in recipe.ingredients)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Text(
                        ingredient.quantity.isEmpty && ingredient.unit.isEmpty
                            ? ingredient.name
                            : '${ingredient.quantity} ${ingredient.unit} · ${ingredient.name}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _RecipeSection(
                title: 'Preparation',
                children: [
                  if (recipe.preparation.isEmpty)
                    const Text('No preparation notes supplied.'),
                  for (final note in recipe.preparation)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Text(note),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _RecipeSection(
                title: 'How to Make It',
                children: [
                  if (recipe.instructions.isEmpty)
                    const Text('No instructions supplied.'),
                  for (var i = 0; i < recipe.instructions.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${i + 1}.', style: text.titleMedium),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Text(
                              recipe.instructions[i],
                              style: text.bodyLarge,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

class _MissingRecipeImage extends StatelessWidget {
  const _MissingRecipeImage();
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.nude,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          'No recipe image provided',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.textPrimary),
        ),
      ),
    ),
  );
}

class _RecipeSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _RecipeSection({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      initiallyExpanded: true,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}
