import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/saved_recipe.dart';
import '../../repositories/workspace_saved_recipe_repository.dart'
    hide SavedRecipesPage;

const _expired = 'Workspace access changed. Reopen Saved Recipes.';

/// Standalone offline/injected view. Caller owns the repository and its lifetime.
class SavedRecipesPage extends StatefulWidget {
  final WorkspaceSavedRecipeRepository repository;
  const SavedRecipesPage({super.key, required this.repository});
  @override
  State<SavedRecipesPage> createState() => _SavedRecipesPageState();
}

abstract class _ReadState<W extends StatefulWidget> extends State<W> {
  WorkspaceSavedRecipeRepository get repository;
  WorkspaceSavedRecipeRepository? captured;
  SavedRecipeSession? session;
  StreamSubscription<void>? _subscription;
  int revision = 0, binding = 0;
  bool expired = false;
  void clearData();
  bool get current {
    try {
      return mounted &&
          !expired &&
          identical(captured, repository) &&
          session?.valid == true &&
          session!.matches(repository.currentSession());
    } catch (_) {
      return false;
    }
  }

  void refresh() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void invalidate({bool notify = true}) {
    expired = true;
    revision++;
    clearData();
    if (notify) refresh();
  }

  bool ensureCurrent() {
    if (current) return true;
    invalidate();
    return false;
  }

  void bind() {
    unawaited(_subscription?.cancel());
    final epoch = ++binding;
    revision++;
    expired = false;
    clearData();
    captured = repository;
    try {
      session = repository.currentSession();
    } catch (_) {
      session = null;
    }
    _subscription = repository.sessionChanges.listen(
      (_) {
        if (binding == epoch && mounted) invalidate();
      },
      onError: (Object _) {
        if (binding == epoch && mounted) invalidate();
      },
      onDone: () {
        if (binding == epoch && mounted) invalidate();
      },
    );
    if (!current) expired = true;
  }

  bool accepts(int requestRevision) => current && requestRevision == revision;
  bool rejectAccess(Object error) {
    if (!current ||
        (error is SavedRecipeException &&
            [
              SavedRecipeFailure.session,
              SavedRecipeFailure.permission,
              SavedRecipeFailure.stale,
            ].contains(error.failure))) {
      invalidate();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    binding++;
    invalidate(notify: false);
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

class _SavedRecipesPageState extends _ReadState<SavedRecipesPage> {
  @override
  WorkspaceSavedRecipeRepository get repository => widget.repository;
  String _mode = 'active';
  List<SavedRecipeSummary> _items = [];
  SessionSavedRecipeCursor? _cursor;
  bool _loading = false;
  String? _error;
  final _details = <ValueNotifier<bool>>{};
  void _closeDetails() {
    for (final signal in _details.toList()) {
      void close() {
        if (_details.contains(signal)) signal.value = false;
      }

      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) => close());
      } else {
        close();
      }
    }
  }

  @override
  void clearData() {
    _items = [];
    _cursor = null;
    _loading = false;
    _error = null;
    _closeDetails();
  }

  @override
  void initState() {
    super.initState();
    bind();
    _load();
  }

  @override
  void didUpdateWidget(covariant SavedRecipesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, repository)) {
      invalidate(notify: false);
      bind();
      _mode = 'active';
      _load();
    }
  }

  Future<void> _load({bool more = false}) async {
    if (!ensureCurrent() || _loading || (more && _cursor == null)) return;
    final source = repository, mode = _mode, cursor = more ? _cursor : null;
    final requestRevision = ++revision;
    _loading = true;
    _error = null;
    refresh();
    try {
      final page = await source.list(mode: mode, limit: 20, cursor: cursor);
      if (!accepts(requestRevision) ||
          !identical(source, repository) ||
          mode != _mode) {
        return;
      }
      _items = more ? [..._items, ...page.items] : page.items;
      _cursor = page.nextCursor;
      _loading = false;
      refresh();
    } catch (error) {
      if (!mounted || requestRevision != revision) return;
      if (rejectAccess(error)) return;
      _loading = false;
      _error = 'Saved recipes could not be loaded. Please try again.';
      refresh();
    }
  }

  void _filter(String mode) {
    if (!ensureCurrent() || mode == _mode) return;
    revision++;
    clearData();
    _mode = mode;
    _load();
  }

  Future<void> _open(SavedRecipeSummary item) async {
    if (!ensureCurrent() || !_items.contains(item) || _details.isNotEmpty) {
      return;
    }
    final source = repository, epoch = binding, mode = _mode;
    bool parentCurrent() =>
        current &&
        binding == epoch &&
        identical(source, repository) &&
        mode == _mode;
    final access = ValueNotifier(true);
    _details.add(access);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _SavedRecipeDetailsPage(
            repository: source,
            recipeId: item.recipeId,
            access: access,
            parentCurrent: parentCurrent,
          ),
        ),
      );
    } finally {
      _details.remove(access);
      access.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(title: const Text('Saved Recipes')),
    body: !current
        ? const _Message(_expired)
        : Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  const Text('Cafe-shared library'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in ['active', 'archived', 'all'])
                        ChoiceChip(
                          key: ValueKey('saved-filter-$mode'),
                          label: Text(
                            '${mode[0].toUpperCase()}${mode.substring(1)}',
                          ),
                          selected: mode == _mode,
                          onSelected: (_) => _filter(mode),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_loading && _items.isEmpty)
                    const _Loading('Loading saved recipes…')
                  else if (_items.isEmpty && _error == null)
                    _Message(switch (_mode) {
                      'active' => 'No active saved recipes.',
                      'archived' => 'No archived saved recipes.',
                      _ => 'No saved recipes yet.',
                    }),
                  for (final item in _items)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(item.isArchived ? 'Archived' : 'Active'),
                            _Provenance(item.provenance),
                            Text('Updated (UTC): ${item.updatedAt}'),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: () => _open(item),
                              child: Text('View recipe: ${item.title}'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_error != null) ...[
                    Text(_error!),
                    OutlinedButton(
                      key: const ValueKey('saved-read-retry'),
                      onPressed: _loading
                          ? null
                          : () => _load(more: _items.isNotEmpty),
                      child: const Text('Retry'),
                    ),
                  ],
                  if (_loading && _items.isNotEmpty)
                    const _Loading('Loading more recipes…')
                  else if (_cursor != null && _error == null)
                    OutlinedButton(
                      key: const ValueKey('saved-load-more'),
                      onPressed: () => _load(more: true),
                      child: const Text('Load more'),
                    ),
                ],
              ),
            ),
          ),
  );
}

class _SavedRecipeDetailsPage extends StatefulWidget {
  final WorkspaceSavedRecipeRepository repository;
  final String recipeId;
  final ValueNotifier<bool> access;
  final bool Function() parentCurrent;
  const _SavedRecipeDetailsPage({
    required this.repository,
    required this.recipeId,
    required this.access,
    required this.parentCurrent,
  });
  @override
  State<_SavedRecipeDetailsPage> createState() => _SavedRecipeDetailsState();
}

class _SavedRecipeDetailsState extends _ReadState<_SavedRecipeDetailsPage> {
  @override
  WorkspaceSavedRecipeRepository get repository => widget.repository;
  @override
  bool get current =>
      super.current && widget.access.value && widget.parentCurrent();
  SavedRecipe? _item;
  bool _loading = false;
  String? _error;
  @override
  void clearData() {
    _item = null;
    _loading = false;
    _error = null;
  }

  void _parentChanged() {
    if (!widget.access.value) invalidate();
  }

  @override
  void initState() {
    super.initState();
    widget.access.addListener(_parentChanged);
    bind();
    _load();
  }

  @override
  void dispose() {
    widget.access.removeListener(_parentChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!ensureCurrent() || _loading) return;
    final requestRevision = ++revision;
    _loading = true;
    _error = null;
    refresh();
    try {
      final item = await repository.get(widget.recipeId);
      if (!accepts(requestRevision)) return;
      _item = item;
      _loading = false;
      refresh();
    } catch (error) {
      if (!mounted || requestRevision != revision) return;
      if (rejectAccess(error)) return;
      _loading = false;
      _error =
          error is SavedRecipeException &&
              error.failure == SavedRecipeFailure.notFound
          ? 'This saved recipe is no longer available.'
          : 'Recipe details could not be loaded. Please try again.';
      refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Saved Recipe Details')),
      body: !current
          ? const _Message(_expired)
          : _loading
          ? const _Loading('Loading recipe details…')
          : item == null
          ? _Message(
              _error ?? 'Recipe details are unavailable.',
              action: OutlinedButton(
                key: const ValueKey('saved-detail-retry'),
                onPressed: _load,
                child: const Text('Retry'),
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      item.recipe.title,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    Text(item.isArchived ? 'Archived' : 'Active'),
                    _Provenance(item.provenance),
                    const SizedBox(height: 16),
                    Text(item.recipe.whyRecommended),
                    const SizedBox(height: 16),
                    Text(
                      'Ingredients',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    for (var i = 0; i < item.recipe.ingredients.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '${i + 1}. Ingredient ID: ${item.recipe.ingredients[i].itemId}\n${item.recipe.ingredients[i].quantity} ${item.recipe.ingredients[i].unit}',
                        ),
                      ),
                    Text(
                      'Preparation steps',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    for (var i = 0; i < item.recipe.steps.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('${i + 1}. ${item.recipe.steps[i]}'),
                      ),
                    const Divider(),
                    Text('Version: ${item.version}'),
                    for (final field in [
                      'createdBy',
                      'createdAt',
                      'updatedBy',
                      'updatedAt',
                      'archivedBy',
                      'archivedAt',
                    ])
                      Text(
                        '${switch (field) {
                          'createdBy' => 'Created by',
                          'createdAt' => 'Created (UTC)',
                          'updatedBy' => 'Updated by',
                          'updatedAt' => 'Updated (UTC)',
                          'archivedBy' => 'Archived by',
                          _ => 'Archived (UTC)',
                        }}: ${item.data[field] ?? 'Not applicable'}',
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Provenance extends StatelessWidget {
  final SavedRecipeProvenance provenance;
  const _Provenance(this.provenance);
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Workspace-submitted recipe; AI origin not verified.'),
      if (['sample', 'mock'].contains(provenance.attribution.kind))
        Text(
          '${provenance.attribution.kind == 'sample' ? 'Sample' : 'Mock'} recipe',
        ),
      Text('Source: ${provenance.source}'),
      Text('Evidence: ${provenance.evidence}'),
      Text('Submitted attribution: ${provenance.attribution.kind}'),
      if (provenance.attribution.provider != null)
        Text('Claimed provider: ${provenance.attribution.provider}'),
      if (provenance.attribution.ticketId != null)
        Text('Claimed ticket: ${provenance.attribution.ticketId}'),
    ],
  );
}

class _Message extends StatelessWidget {
  final String message;
  final Widget? action;
  const _Message(this.message, {this.action});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Text(message), ?action],
      ),
    ),
  );
}

class _Loading extends StatelessWidget {
  final String message;
  const _Loading(this.message);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(message),
      ],
    ),
  );
}
