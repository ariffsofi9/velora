import 'package:flutter/material.dart';

import '../../../widgets/dashboard/dashboard_style.dart';

/// Safe bell shell. Notification history stays disabled until it is scoped.
class NotificationBell extends StatelessWidget {
  final VoidCallback? onTap;

  const NotificationBell({super.key, this.onTap});

  void _handleTap(BuildContext context) {
    final callback = onTap;
    if (callback != null) {
      callback();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Notification history is unavailable until secure workspace notifications are enabled.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Alerts',
    child: Semantics(
      button: true,
      label: 'Alerts',
      child: InkWell(
        onTap: () => _handleTap(context),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 48,
          width: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: DashboardStyle.border),
          ),
          child: const Icon(
            Icons.notifications_rounded,
            color: DashboardStyle.primary,
          ),
        ),
      ),
    ),
  );
}
