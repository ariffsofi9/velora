import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/cafe_workspace.dart';
import '../../models/menu_item.dart';
import '../../repositories/workspace_menu_repository.dart';
import 'menu_edit_page.dart';

class MenuPage extends StatefulWidget {
  final MenuRepository? repository;
  const MenuPage({super.key, this.repository});
  @override
  State<MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage> {
  late final MenuRepository _repository;
  StreamSubscription<void>? _session;
  CafeWorkspace? _workspace;
  List<MenuItem> _items = [];
  String? _cursor, _error, _moreError;
  bool _loading = true,
      _more = false,
      _busy = false,
      _confirming = false,
      _includeArchived = false;
  int _generation = 0;
  final _keys = <String, String>{};
  bool get _owner => _workspace?.role == CafeRole.owner;
  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FirebaseMenuRepository();
    _session = _repository.sessionChanges.listen(
      (_) {
        _invalidate();
      },
      onError: (Object _) {
        _invalidate();
      },
    );
    _load();
  }

  void _invalidate() {
    _generation++;
    if (_confirming && mounted) Navigator.of(context).pop(false);
    if (mounted) {
      setState(() {
        _items = [];
        _workspace = null;
        _cursor = null;
        _keys.clear();
        _loading = false;
        _more = false;
        _busy = false;
        _error = const MenuException(MenuFailure.session).message;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _session?.cancel();
    super.dispose();
  }

  String _message(Object error) => error is MenuException
      ? error.message
      : 'Menu is unavailable. Please retry.';
  Future<void> _load({bool more = false}) async {
    if (more && (_more || _loading || _cursor == null)) return;
    final generation = more ? _generation : ++_generation;
    setState(() {
      if (more) {
        _more = true;
        _moreError = null;
      } else {
        _loading = true;
        _error = null;
        _moreError = null;
        _items = [];
        _cursor = null;
      }
    });
    try {
      final workspace = await _repository.resolve();
      if (!mounted || generation != _generation) return;
      final page = await _repository.list(
        includeArchived: _includeArchived,
        cursor: more ? _cursor : null,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _workspace = workspace;
        _items = more
            ? {
                for (final item in [..._items, ...page.items]) item.id: item,
              }.values.toList()
            : page.items;
        _cursor = page.nextCursor;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      if (error is MenuException &&
          [
            MenuFailure.session,
            MenuFailure.permission,
          ].contains(error.failure)) {
        _invalidate();
        if (mounted) setState(() => _error = error.message);
        return;
      }
      setState(() {
        if (more) {
          _moreError = _message(error);
        } else {
          _error = _message(error);
          _workspace = null;
        }
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _more = false;
        });
      }
    }
  }

  Future<void> _edit([MenuItem? item]) async {
    if (!_owner || _busy) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MenuEditPage(repository: _repository, item: item),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _action(MenuItem item, {bool lifecycle = false}) async {
    if (_busy || _loading || (lifecycle && !_owner)) return;
    final generation = _generation;
    final action = lifecycle
        ? (item.isArchived ? 'Restore' : 'Archive')
        : (item.isAvailable ? 'Set Unavailable' : 'Set Available');
    setState(() {
      _busy = true;
      _confirming = true;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$action?'),
          content: Text(item.name),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('menu-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || generation != _generation) return;
      setState(() => _confirming = false);
      final fingerprint = '${item.id}/${item.version}/$action';
      final key = _keys.putIfAbsent(fingerprint, newMenuRequestKey);
      if (lifecycle) {
        await _repository.lifecycle(item, !item.isArchived, key);
      } else {
        await _repository.availability(item, !item.isAvailable, key);
      }
      if (!mounted || generation != _generation) return;
      _keys.remove(fingerprint);
      await _load();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      if (error is MenuException &&
          [
            MenuFailure.session,
            MenuFailure.permission,
          ].contains(error.failure)) {
        _invalidate();
        return;
      }
      if (error is MenuException &&
          [MenuFailure.stale, MenuFailure.conflict].contains(error.failure)) {
        _keys.clear();
        await _load();
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_message(error))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: const Text('Menu Management'),
      backgroundColor: AppColors.background,
      actions: [
        IconButton(
          tooltip: 'Refresh menu',
          onPressed: _loading || _busy ? null : () => _load(),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'Your café menu',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('Menu items and current availability.'),
                  const SizedBox(height: 16),
                  if (_owner) ...[
                    FilledButton.icon(
                      key: const ValueKey('menu-add'),
                      onPressed: _busy ? null : () => _edit(),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Menu Item'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_error == null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilterChip(
                        label: const Text('Include archived'),
                        selected: _includeArchived,
                        onSelected: _busy
                            ? null
                            : (value) {
                                _includeArchived = value;
                                _load();
                              },
                      ),
                    ),
                  if (_error != null) ...[
                    Text(_error!, key: const ValueKey('menu-error')),
                    OutlinedButton(
                      onPressed: () => _load(),
                      child: const Text('Retry'),
                    ),
                  ] else if (_items.isEmpty) ...[
                    const SizedBox(height: 24),
                    const Icon(
                      Icons.restaurant_menu_rounded,
                      size: 48,
                      color: AppColors.primary,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No menu items yet.',
                      textAlign: TextAlign.center,
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    for (final item in _items) ...[
                      Container(
                        key: ValueKey('menu-card-${item.id}'),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          border: Border.all(color: AppColors.border),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(item.category),
                            const SizedBox(height: 8),
                            Text(
                              item.formattedPrice,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(item.isArchived ? 'Archived' : 'Active'),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                item.isArchived
                                    ? 'Unavailable (archived)'
                                    : item.isAvailable
                                    ? 'Available'
                                    : 'Unavailable',
                              ),
                              value: !item.isArchived && item.isAvailable,
                              onChanged: _busy || item.isArchived
                                  ? null
                                  : (_) => _action(item),
                            ),
                            if (_owner)
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: _busy || item.isArchived
                                        ? null
                                        : () => _edit(item),
                                    child: const Text('Edit'),
                                  ),
                                  OutlinedButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _action(item, lifecycle: true),
                                    child: Text(
                                      item.isArchived ? 'Restore' : 'Archive',
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_moreError != null) Text(_moreError!),
                    if (_cursor != null)
                      OutlinedButton(
                        onPressed: _more || _busy
                            ? null
                            : () => _load(more: true),
                        child: Text(
                          _more
                              ? 'Loading…'
                              : _moreError == null
                              ? 'Load More'
                              : 'Retry Load More',
                        ),
                      ),
                  ],
                  if (_busy && !_confirming)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}
