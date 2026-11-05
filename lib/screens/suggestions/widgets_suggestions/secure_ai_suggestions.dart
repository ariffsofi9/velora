import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../services/secure_ai_service.dart';
import '../../../services/workspace_session.dart';

class SecureAiSuggestions extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final SecureAiService service;
  const SecureAiSuggestions({
    super.key,
    required this.workspaceSession,
    required this.service,
  });
  @override
  State<SecureAiSuggestions> createState() => _SecureAiSuggestionsState();
}

class _SecureAiSuggestionsState extends State<SecureAiSuggestions> {
  bool _loading = false;
  int _revision = 0;
  SecureAiResult? _result;
  String? _message;
  @override
  void didUpdateWidget(covariant SecureAiSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceSession != widget.workspaceSession ||
        oldWidget.service != widget.service) {
      _revision++;
      _loading = false;
      _result = null;
      _message = null;
    }
  }

  @override
  void dispose() {
    _revision++;
    super.dispose();
  }

  Future<void> _generate() async {
    if (_loading) return;
    final revision = ++_revision;
    final session = widget.workspaceSession;
    if (session == null ||
        !session.isActive ||
        !identical(widget.service.currentSession(), session)) {
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
      _result = null;
    });
    try {
      final result = await widget.service.generate();
      if (!mounted || revision != _revision || !session.isActive) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on SecureAiException catch (error) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _loading = false;
        _message = switch (error.failure) {
          SecureAiFailure.signInRequired =>
            'Sign in again to use AI suggestions.',
          SecureAiFailure.emailUnverified =>
            'Verify your email before requesting AI suggestions.',
          SecureAiFailure.accountDisabled =>
            'AI access is unavailable for this account.',
          SecureAiFailure.ticketExpired =>
            'This AI ticket expired. No automatic replacement was issued.',
          SecureAiFailure.replayed =>
            'This AI ticket was already used. Results cannot be retrieved.',
          SecureAiFailure.invalidRequest =>
            'The AI request is invalid. No automatic retry was made.',
          SecureAiFailure.workspaceBusy =>
            'Workspace AI is busy or paused. Inventory remains available.',
          SecureAiFailure.outcomeUnknown =>
            'AI request outcome is unknown. No automatic retry was made.',
          SecureAiFailure.inventoryLimit =>
            'AI supports up to 100 inventory records. Inventory remains available.',
          SecureAiFailure.quota =>
            'AI request limit reached. Inventory remains available.',
          SecureAiFailure.timeout =>
            'AI response timed out. No automatic retry was made.',
          SecureAiFailure.workspaceChanged || SecureAiFailure.denied =>
            'Workspace access changed. Reopen suggestions.',
          SecureAiFailure.invalidResponse =>
            'AI returned an invalid response. No suggestions were displayed.',
          _ => 'AI suggestions are unavailable. Inventory remains available.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final active =
        (widget.workspaceSession?.isActive ?? false) &&
        identical(widget.service.currentSession(), widget.workspaceSession);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Recipes for your café',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              widget.service.isDemo
                  ? 'Mock demo only. No AI provider is called.'
                  : widget.service.available
                  ? 'AI suggestions from your workspace.'
                  : 'AI suggestions are unavailable until secure service integration is approved.',
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: active && widget.service.available && !_loading
                  ? _generate
                  : null,
              child: Text(
                _loading ? 'Loading suggestions…' : 'Generate Recipes',
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_message != null) Text(_message!),
            if (active && _result != null) ...[
              Text(
                _result!.isDemo
                    ? 'Demo suggestions — sample data'
                    : 'AI suggestions',
              ),
              if (_result!.recipes.isEmpty)
                const Text('No suggestions for eligible inventory.'),
              for (final recipe in _result!.recipes) ...[
                Text(
                  recipe.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final ingredient in recipe.ingredients)
                  Text(
                    '${ingredient.itemId}: ${ingredient.quantity} ${ingredient.unit}',
                  ),
                for (final step in recipe.steps) Text(step),
                Text(recipe.whyRecommended),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
