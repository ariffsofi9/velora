import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/workspace_activity.dart';
import '../../repositories/workspace_activity_repository.dart';
import '../../services/workspace_session.dart';

enum _ActivityFilter { all, inventory }

class ActivityPage extends StatefulWidget {
  final WorkspaceSession workspaceSession;
  final WorkspaceActivityReader? activityReader;
  final ({String id, String name})? item;

  const ActivityPage({
    super.key,
    required this.workspaceSession,
    this.activityReader,
    this.item,
  });

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  late WorkspaceActivityReader _reader;
  final List<WorkspaceActivity> _activities = [];
  WorkspaceActivityCursor? _cursor;
  WorkspaceActivityFailure? _failure;
  WorkspaceActivityFailure? _loadMoreFailure;
  bool _loading = false;
  bool _loadingMore = false;
  _ActivityFilter _filter = _ActivityFilter.all;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _configureReader();
    _loadFirstPage();
  }

  @override
  void didUpdateWidget(covariant ActivityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.activityReader, widget.activityReader) ||
        oldWidget.item?.id != widget.item?.id) {
      _generation++;
      _configureReader();
      _activities.clear();
      _cursor = null;
      _failure = null;
      _loadMoreFailure = null;
      _loading = false;
      _loadingMore = false;
      _loadFirstPage();
    }
  }

  void _configureReader() {
    _reader =
        widget.activityReader ??
        WorkspaceActivityRepository(session: widget.workspaceSession);
  }

  Future<void> _loadFirstPage() => _loadPage();
  Future<void> _loadMore() => _loadPage(append: true);

  Future<void> _loadPage({bool append = false}) async {
    final cursor = append ? _cursor : null;
    if (_loading || _loadingMore || (append && cursor == null)) return;
    final generation = _generation;
    final session = widget.workspaceSession;
    final itemId = widget.item?.id;
    setState(() {
      _loading = !append;
      _loadingMore = append;
      _loadMoreFailure = null;
      if (!append) _failure = null;
    });
    try {
      if (!session.isActive) {
        throw const WorkspaceActivityException(
          WorkspaceActivityFailure.permissionDenied,
        );
      }
      if (itemId != null &&
          (itemId.isEmpty ||
              itemId.trim() != itemId ||
              itemId.contains('/') ||
              itemId.length > 128)) {
        throw const WorkspaceActivityException(
          WorkspaceActivityFailure.invalidData,
        );
      }
      final page = await _reader.getActivities(cursor: cursor);
      if (!mounted || generation != _generation) return;
      if (!session.isActive) {
        throw const WorkspaceActivityException(
          WorkspaceActivityFailure.permissionDenied,
        );
      }
      if (page.activities.any(
        (activity) => activity.cafeId != session.cafeId,
      )) {
        throw const WorkspaceActivityException(
          WorkspaceActivityFailure.invalidData,
        );
      }
      setState(() {
        if (!append) _activities.clear();
        final ids = _activities.map((activity) => activity.id).toSet();
        _activities.addAll(
          page.activities.where(
            (activity) =>
                (itemId == null || activity.itemId == itemId) &&
                ids.add(activity.id),
          ),
        );
        _cursor = page.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final failure = !session.isActive
          ? WorkspaceActivityFailure.permissionDenied
          : error is WorkspaceActivityException
          ? error.failure
          : WorkspaceActivityFailure.unavailable;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (failure == WorkspaceActivityFailure.permissionDenied) {
          _activities.clear();
          _cursor = null;
          _failure = failure;
        } else if (append) {
          _loadMoreFailure = failure;
        } else {
          _failure = failure;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: Text(
        widget.workspaceSession.isActive && widget.item != null
            ? 'Activity for ${widget.item!.name}'
            : 'Activity',
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              if (widget.workspaceSession.isActive && widget.item == null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      _filterChip(_ActivityFilter.all, 'All Activities'),
                      _filterChip(_ActivityFilter.inventory, 'Inventory'),
                    ],
                  ),
                ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _filterChip(_ActivityFilter filter, String label) => ChoiceChip(
    label: Text(label),
    selected: _filter == filter,
    onSelected: (selected) {
      if (selected && _filter != filter) setState(() => _filter = filter);
    },
  );

  Widget _body() {
    if (!widget.workspaceSession.isActive) {
      return _ActivityState(
        key: const ValueKey('activity-error'),
        icon: Icons.error_outline_rounded,
        title: _failureTitle(WorkspaceActivityFailure.permissionDenied),
        message: _failureMessage(WorkspaceActivityFailure.permissionDenied),
      );
    }
    if (_loading && _activities.isEmpty) {
      return const Center(
        key: ValueKey('activity-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_failure != null && _activities.isEmpty) {
      return _ActivityState(
        key: const ValueKey('activity-error'),
        icon: Icons.error_outline_rounded,
        title: _failureTitle(_failure!),
        message: _failureMessage(_failure!),
        actionLabel: 'Retry',
        onAction: _loadFirstPage,
      );
    }
    final itemOnly = widget.item != null;
    final inventoryOnly = !itemOnly && _filter == _ActivityFilter.inventory;
    final visible = inventoryOnly
        ? _activities.where((activity) => activity.type.isInventory)
        : _activities;
    if (visible.isEmpty && _cursor == null) {
      return _ActivityState(
        key: const ValueKey('activity-empty'),
        icon: Icons.history_rounded,
        title: itemOnly
            ? 'No activity for this item'
            : inventoryOnly
            ? 'No inventory activity yet'
            : 'No activity yet',
        message: itemOnly
            ? 'Recorded changes for this item will appear here.'
            : inventoryOnly
            ? 'Inventory actions for this workspace will appear here.'
            : 'Activity for this workspace will appear here.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          visible.isEmpty
              ? 'No matching activity in the pages loaded so far.'
              : 'Newest activity first',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        for (final activity in visible) ...[
          _ActivityCard(
            key: ValueKey('activity-${activity.id}'),
            activity: activity,
            currentUid: widget.workspaceSession.uid,
          ),
          const SizedBox(height: 10),
        ],
        if (_loadMoreFailure != null) ...[
          Text(
            _failureMessage(_loadMoreFailure!),
            key: const ValueKey('activity-load-more-error'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.danger),
          ),
          const SizedBox(height: 8),
        ],
        if (_cursor != null)
          OutlinedButton(
            key: const ValueKey('activity-load-more'),
            onPressed: _loadingMore ? null : _loadMore,
            child: _loadingMore
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_loadMoreFailure == null ? 'Load More' : 'Retry'),
          )
        else
          const Text(
            'End of activity',
            key: ValueKey('activity-end'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
      ],
    );
  }

  String _failureTitle(WorkspaceActivityFailure failure) => switch (failure) {
    WorkspaceActivityFailure.permissionDenied => 'Activity unavailable',
    WorkspaceActivityFailure.unavailable => 'Unable to load activity',
    WorkspaceActivityFailure.invalidData => 'Activity data is invalid',
  };

  String _failureMessage(WorkspaceActivityFailure failure) => switch (failure) {
    WorkspaceActivityFailure.permissionDenied =>
      'You no longer have permission to view this activity.',
    WorkspaceActivityFailure.unavailable =>
      'Check your connection and try again.',
    WorkspaceActivityFailure.invalidData =>
      'An activity record could not be read safely.',
  };
}

class _ActivityCard extends StatelessWidget {
  final WorkspaceActivity activity;
  final String currentUid;
  const _ActivityCard({
    super.key,
    required this.activity,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    final stockOut = activity.direction == 'out';
    final color = stockOut ? AppColors.warning : AppColors.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon(), color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(_details()),
                const SizedBox(height: 6),
                Text(
                  '${activity.actorUid == currentUid ? 'You' : 'Team member'} • ${_date(activity.createdAt)}',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon() => switch (activity.type) {
    WorkspaceActivityType.inventoryCreated => Icons.add_box_outlined,
    WorkspaceActivityType.inventoryUpdated ||
    WorkspaceActivityType.inventoryUpdateNoop => Icons.edit_outlined,
    WorkspaceActivityType.inventoryStockAdjusted =>
      activity.direction == 'out'
          ? Icons.remove_circle_outline
          : Icons.add_circle_outline,
    WorkspaceActivityType.inventoryArchived => Icons.archive_outlined,
    WorkspaceActivityType.inventoryRestored => Icons.unarchive_outlined,
  };

  String _title() => switch (activity.type) {
    WorkspaceActivityType.inventoryCreated => 'Item Created',
    WorkspaceActivityType.inventoryUpdated => 'Item Updated',
    WorkspaceActivityType.inventoryUpdateNoop => 'Update Checked',
    WorkspaceActivityType.inventoryStockAdjusted =>
      activity.direction == 'in' ? 'Stock In' : 'Stock Out',
    WorkspaceActivityType.inventoryArchived => 'Item Archived',
    WorkspaceActivityType.inventoryRestored => 'Item Restored',
  };

  String _details() {
    final item = activity.itemName ?? 'Inventory item';
    return switch (activity.type) {
      WorkspaceActivityType.inventoryCreated =>
        '$item • ${activity.quantity} ${activity.unit}',
      WorkspaceActivityType.inventoryUpdated =>
        activity.changedFields.isEmpty
            ? '$item metadata updated'
            : '$item updated: ${activity.changedFields.join(', ')}',
      WorkspaceActivityType.inventoryUpdateNoop => '$item was already current',
      WorkspaceActivityType.inventoryStockAdjusted =>
        '$item • ${activity.direction == 'in' ? '+' : '−'}${activity.quantity} ${activity.unit}'
            '${activity.previousQuantity == null ? '' : ' • ${activity.previousQuantity} → ${activity.resultingQuantity}'}',
      WorkspaceActivityType.inventoryArchived =>
        '$item moved to Archived Items',
      WorkspaceActivityType.inventoryRestored =>
        '$item returned to active inventory',
    };
  }

  String _date(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '• ${two(local.hour)}:${two(local.minute)}';
  }
}

class _ActivityState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _ActivityState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
          if (onAction != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}
