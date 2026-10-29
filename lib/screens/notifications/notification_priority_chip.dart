import 'package:flutter/material.dart';

import 'app_notification.dart';

class NotificationPriorityChip extends StatelessWidget {
  final NotificationPriority priority;

  const NotificationPriorityChip({super.key, required this.priority});

  Color get color {
    switch (priority) {
      case NotificationPriority.high:
        return const Color(0xFFEF4444);
      case NotificationPriority.medium:
        return const Color(0xFFF59E0B);
      case NotificationPriority.low:
        return const Color(0xFF10B981);
    }
  }

  String get label {
    switch (priority) {
      case NotificationPriority.high:
        return 'High';
      case NotificationPriority.medium:
        return 'Medium';
      case NotificationPriority.low:
        return 'Low';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(31),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
