import '../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../notification_alert_item.dart';
import 'notification_priority_chip.dart';

class NotificationAlertCard extends StatelessWidget {
  final NotificationAlertItem alert;
  final bool isRead;
  final VoidCallback onToggleRead;
  final VoidCallback onDismiss;

  const NotificationAlertCard({
    super.key,
    required this.alert,
    required this.isRead,
    required this.onToggleRead,
    required this.onDismiss,
  });

  Color get mainColor {
    switch (alert.priority) {
      case AlertPriority.high:
        return const Color(0xFFEF4444);
      case AlertPriority.medium:
        return const Color(0xFFF59E0B);
      case AlertPriority.low:
        return const Color(0xFF10B981);
    }
  }

  IconData get icon {
    switch (alert.type) {
      case AlertType.expiry:
        return Icons.access_time_rounded;
      case AlertType.stock:
        return Icons.warning_amber_rounded;
    }
  }

  @override
  Widget build(BuildContext context) => Dismissible(
    key: ValueKey(alert.id),
    direction: DismissDirection.endToStart,
    onDismissed: (_) => onDismiss(),
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.all(20),
      color: AppColors.danger,
      child: const Icon(Icons.delete_outline, color: Colors.white),
    ),
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: mainColor.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: mainColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 5),
                Text(
                  alert.message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    NotificationPriorityChip(priority: alert.priority),
                    TextButton(
                      onPressed: onToggleRead,
                      child: Text(isRead ? 'Mark unread' : 'Mark read'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
