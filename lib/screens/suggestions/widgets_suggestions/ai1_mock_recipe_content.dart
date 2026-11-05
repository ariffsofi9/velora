import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/groq_recipe_response.dart';
import '../../../services/ai1_mock_recipe_client.dart';
import '../../../services/workspace_session.dart';
import 'recipe_suggestions_content.dart';

class Ai1MockRecipeContent extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final Ai1MockRecipeClient? client;
  const Ai1MockRecipeContent({super.key, this.workspaceSession, this.client});
  @override
  State<Ai1MockRecipeContent> createState() => _Ai1MockRecipeContentState();
}

class _Ai1MockRecipeContentState extends State<Ai1MockRecipeContent> {
  Ai1MockRecipeClient? _client;
  StreamSubscription<Object?>? _auth;
  int _epoch = 0;
  bool _loading = false;
  String? _message;
  List<GroqRecipe> _recipes = const [];
  bool get _available => _client?.isAvailable ?? false;
  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    final session = widget.workspaceSession;
    if (!Ai1MockRecipeClient.profileEnabled || session == null) return;
    final client = widget.client ?? Ai1MockRecipeClient(session: session);
    if (client.session.uid != session.uid ||
        client.session.cafeId != session.cafeId ||
        client.session.ownerUid != session.ownerUid ||
        client.session.role != session.role) {
      return;
    }
    _client = client;
    if (!_available) return;
    var uid = session.uid;
    void invalidate() {
      if (!mounted) return;
      setState(() {
        _epoch++;
        _loading = false;
        _recipes = const [];
        _message = 'Workspace access changed. Reopen Recipe Suggestions.';
      });
    }

    _auth = client.authChanges.listen((user) {
      if (user?.uid != uid) {
        uid = user?.uid ?? '';
        invalidate();
      }
    }, onError: (Object _) => invalidate());
  }

  @override
  void didUpdateWidget(covariant Ai1MockRecipeContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceSession != widget.workspaceSession ||
        oldWidget.client != widget.client) {
      _epoch++;
      _auth?.cancel();
      _client = null;
      _recipes = const [];
      _loading = false;
      _message = null;
      _connect();
    }
  }

  @override
  void dispose() {
    _epoch++;
    _auth?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    if (!_available || _loading) return;
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _recipes = const [];
      _message = null;
    });
    try {
      final random = Random.secure();
      final id =
          'mock-${List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join()}';
      final result = await _client!
          .generate(requestId: id)
          .timeout(const Duration(seconds: 40));
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _loading = false;
        _recipes = result.recipes;
        _message = _recipes.isEmpty
            ? 'No mock recipes match the eligible inventory.'
            : null;
      });
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _loading = false;
        _message =
            'Mock recipes could not be loaded. Check workspace access and retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Mock Recipes',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'AI1 synthetic schema-v2 demo. Not real Groq output. No inventory changes.',
              ),
              FilledButton(
                onPressed: _available && !_loading ? _generate : null,
                child: const Text('Generate Mock Recipes'),
              ),
              const OutlinedButton(
                onPressed: null,
                child: Text('Restock Advice'),
              ),
            ],
          ),
        ),
      ),
      if (_loading)
        const Column(
          children: [
            CircularProgressIndicator(),
            Text('Loading mock recipes…'),
          ],
        ),
      if (_message != null) ...[
        Text(_message!),
        OutlinedButton(
          onPressed: _available && !_loading ? _generate : null,
          child: const Text('Retry mock recipes'),
        ),
      ],
      for (final recipe in _recipes)
        Card(
          child: ListTile(
            title: Text(recipe.title),
            subtitle: const Text(
              'Mock fixture • Not real Groq output\nView recipe',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RecipePresentationDetails(
                  isDemo: false,
                  recipe: RecipePresentation(
                    title: recipe.title,
                    description: recipe.whyRecommended,
                    metadata: 'Mock schema-v2 fixture • Not real Groq output',
                    ingredients: [
                      for (final ingredient in recipe.ingredients)
                        RecipeIngredientPresentation(
                          'Ingredient ID: ${ingredient.itemId}',
                          '${ingredient.quantity}',
                          ingredient.unit,
                        ),
                    ],
                    instructions: recipe.steps,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
