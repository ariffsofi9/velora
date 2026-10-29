import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/activity_model.dart';

class RecentActivityCard extends StatelessWidget {
  const RecentActivityCard({super.key});

  static const Color purple = AppColors.primary;
  static const Color textDark = AppColors.textPrimary;
  static const Color textGrey = AppColors.textSecondary;

  IconData _getIcon(String type) {
    switch (type) {
      case 'stock_in':
        return Icons.add_circle_outline_rounded;
      case 'stock_out':
        return Icons.remove_circle_outline_rounded;
      case 'recipe_generated':
        return Icons.auto_awesome_rounded;
      case 'recipe_skipped':
        return Icons.block_rounded;
      case 'item_updated':
        return Icons.edit_rounded;
      case 'item_deleted':
        return Icons.delete_outline_rounded;
      case 'low_stock':
        return Icons.warning_amber_rounded;
      default:
        return Icons.history_rounded;
    }
  }

  Color _getColor(String type) {
    switch (type) {
      case 'stock_in':
        return const Color(0xFF10B981);
      case 'stock_out':
        return const Color(0xFFF59E0B);
      case 'recipe_generated':
        return purple;
      case 'recipe_skipped':
        return const Color(0xFFEF4444);
      case 'item_updated':
        return AppColors.primary;
      case 'item_deleted':
        return const Color(0xFFEF4444);
      case 'low_stock':
        return const Color(0xFFF97316);
      default:
        return textGrey;
    }
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays} day ago';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('activities')
            .orderBy('createdAt', descending: true)
            .limit(5)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const SizedBox(
              height: 90,
              child: Center(child: CircularProgressIndicator()),
            );
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return _emptyState();
          }

          final activities = snapshot.data!.docs
              .map((doc) => ActivityModel.fromFirestore(doc))
              .toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const SizedBox(height: 14),
              ...activities.map((activity) {
                return _activityTile(activity);
              }),
            ],
          );
        },
      ),
    );
  }

  Widget _header() {
    return const Row(
      children: [
        Icon(Icons.history_rounded, color: purple, size: 22),
        SizedBox(width: 8),
        Text(
          'Recent Activity',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: textDark,
          ),
        ),
      ],
    );
  }

  Widget _activityTile(ActivityModel activity) {
    final color = _getColor(activity.type);

    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 38,
            width: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(_getIcon(activity.type), color: color, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: textDark,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  activity.subtitle.isEmpty
                      ? _timeAgo(activity.createdAt)
                      : '${activity.subtitle} • ${_timeAgo(activity.createdAt)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: textGrey,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Text(
            'No activity yet. Your latest inventory actions will appear here.',
            style: TextStyle(color: textGrey, fontSize: 13.5, height: 1.4),
          ),
        ),
      ],
    );
  }
}
