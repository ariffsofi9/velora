import 'package:flutter/material.dart';

import '../../../models/workspace_activity.dart';
import '../../../repositories/workspace_activity_repository.dart';
import '../../../services/workspace_session.dart';
import '../../../widgets/dashboard/dashboard_style.dart';
import '../../../widgets/dashboard/activity_thumbnail.dart';

class RecentActivityCard extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final WorkspaceActivityRepository? activityRepository;
  final Map<String, Map<String, dynamic>> inventoryItems;
  final VoidCallback? onViewAll;
  const RecentActivityCard({
    super.key,
    this.workspaceSession,
    this.activityRepository,
    this.inventoryItems = const {},
    this.onViewAll,
  });

  @override
  State<RecentActivityCard> createState() => _RecentActivityCardState();
}

class _RecentActivityCardState extends State<RecentActivityCard> {
  Future<WorkspaceActivityPage>? _page;

  bool get _valid =>
      widget.workspaceSession != null &&
      widget.workspaceSession!.isActive &&
      identical(widget.activityRepository?.session, widget.workspaceSession);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RecentActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.activityRepository, widget.activityRepository)) {
      _load();
    }
  }

  void _load() {
    _page = _valid ? widget.activityRepository!.getActivities() : null;
  }

  String _formatType(WorkspaceActivity activity) => switch (activity.type) {
    WorkspaceActivityType.inventoryCreated => 'Item Created',
    WorkspaceActivityType.inventoryUpdated => 'Item Updated',
    WorkspaceActivityType.inventoryUpdateNoop => 'Update Checked',
    WorkspaceActivityType.inventoryStockAdjusted =>
      activity.direction == 'in' ? 'Stock In' : 'Stock Out',
    WorkspaceActivityType.inventoryArchived => 'Item Archived',
    WorkspaceActivityType.inventoryRestored => 'Item Restored',
  };

  IconData _icon(WorkspaceActivity activity) => switch (activity.type) {
    WorkspaceActivityType.inventoryCreated => Icons.add_circle_rounded,
    WorkspaceActivityType.inventoryStockAdjusted =>
      activity.direction == 'in'
          ? Icons.add_circle_rounded
          : Icons.remove_circle_rounded,
    _ => Icons.history_rounded,
  };

  Color _color(WorkspaceActivity activity) =>
      activity.type == WorkspaceActivityType.inventoryStockAdjusted &&
          activity.direction == 'out'
      ? DashboardStyle.danger
      : DashboardStyle.primary;

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) {
      return '${diff.inHours} ${diff.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    return '${diff.inDays} ${diff.inDays == 1 ? 'day' : 'days'} ago';
  }

  String _message(WorkspaceActivity activity) {
    final item =
        activity.itemName ??
        widget.inventoryItems[activity.itemId]?['name'] as String? ??
        'Inventory item';
    return switch (activity.type) {
      WorkspaceActivityType.inventoryCreated => '$item added to inventory',
      WorkspaceActivityType.inventoryUpdated => '$item metadata updated',
      WorkspaceActivityType.inventoryUpdateNoop => '$item was already current',
      WorkspaceActivityType.inventoryStockAdjusted =>
        '$item \u2022 ${activity.direction == 'in' ? '+' : '-'}${activity.quantity} ${activity.unit}',
      WorkspaceActivityType.inventoryArchived => '$item archived',
      WorkspaceActivityType.inventoryRestored => '$item restored',
    };
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: DashboardStyle.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recent Activity',
                  style: text.titleMedium?.copyWith(
                    color: DashboardStyle.forest,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (widget.onViewAll != null)
                TextButton(
                  key: const ValueKey('open-activity'),
                  onPressed: widget.onViewAll,
                  child: const Text('View All'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.workspaceSession == null)
            const Text(
              'Open Activity to view your workspace inventory history.',
              style: TextStyle(color: DashboardStyle.secondary),
            )
          else
            FutureBuilder<WorkspaceActivityPage>(
              key: ObjectKey(_page),
              future: _page,
              builder: (context, snapshot) {
                if (!_valid || snapshot.hasError) {
                  return Column(
                    children: [
                      const Text(
                        'Recent activity cannot load right now.',
                        style: TextStyle(color: DashboardStyle.danger),
                      ),
                      if (_valid)
                        TextButton(
                          onPressed: () => setState(_load),
                          child: const Text('Retry'),
                        ),
                    ],
                  );
                }
                if (!snapshot.hasData) {
                  return const SizedBox(
                    height: 90,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: DashboardStyle.primary,
                      ),
                    ),
                  );
                }
                final docs = [...snapshot.data!.activities]
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                final visible = docs
                    .take(WorkspaceActivityRepository.pageSize)
                    .toList();
                if (docs.isEmpty) {
                  return const Text(
                    'No stock activity yet.',
                    style: TextStyle(color: DashboardStyle.secondary),
                  );
                }
                return Column(
                  children: visible.map((doc) {
                    final type = doc;
                    final color = _color(type);
                    final image =
                        (widget.inventoryItems[doc.itemId]?['imageUrl'] ?? '')
                            .toString();
                    return Container(
                      key: ValueKey('recent-${doc.id}'),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        border: doc == visible.last
                            ? null
                            : const Border(
                                bottom: BorderSide(
                                  color: DashboardStyle.border,
                                ),
                              ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: color.withAlpha(20),
                            child: Icon(_icon(type), color: color, size: 18),
                          ),
                          const SizedBox(width: 8),
                          ActivityThumbnail(imageUrl: image),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _formatType(type),
                                  style: text.titleSmall?.copyWith(
                                    color: DashboardStyle.forest,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _message(doc),
                                  style: text.bodySmall?.copyWith(
                                    color: DashboardStyle.secondary,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                                if (MediaQuery.textScalerOf(context).scale(12) >
                                        16 ||
                                    MediaQuery.sizeOf(context).width < 375) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    _timeAgo(doc.createdAt),
                                    style: text.bodySmall?.copyWith(
                                      color: DashboardStyle.secondary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (MediaQuery.textScalerOf(context).scale(12) <=
                                  16 &&
                              MediaQuery.sizeOf(context).width >= 375) ...[
                            const SizedBox(width: 8),
                            Text(
                              _timeAgo(doc.createdAt),
                              style: text.bodySmall?.copyWith(
                                color: DashboardStyle.secondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
        ],
      ),
    );
  }
}
