import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import 'app_notification.dart';
import 'notification_card.dart';

class NotificationHistoryPage extends StatefulWidget {
  const NotificationHistoryPage({super.key});

  @override
  State<NotificationHistoryPage> createState() =>
      _NotificationHistoryPageState();
}

class _NotificationHistoryPageState extends State<NotificationHistoryPage> {
  final List<AppNotification> _notifications = [
    AppNotification(
      id: '1',
      title: 'Near Expiry Alert',
      message: 'Milk will expire soon. Try to use it first.',
      createdAt: DateTime.now().subtract(const Duration(minutes: 8)),
      priority: NotificationPriority.high,
      isRead: false,
    ),
    AppNotification(
      id: '2',
      title: 'Low Stock Alert',
      message: 'Egg quantity is low. You may need to restock.',
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      priority: NotificationPriority.medium,
      isRead: false,
    ),
    AppNotification(
      id: '3',
      title: 'Inventory Reminder',
      message: 'Check your inventory today to avoid food waste.',
      createdAt: DateTime.now().subtract(const Duration(days: 1)),
      priority: NotificationPriority.low,
      isRead: true,
    ),
  ];

  int get unreadCount {
    return _notifications.where((item) => !item.isRead).length;
  }

  void _toggleRead(String id) {
    setState(() {
      final index = _notifications.indexWhere((item) => item.id == id);
      if (index == -1) return;

      final current = _notifications[index];

      _notifications[index] = current.copyWith(isRead: !current.isRead);
    });
  }

  void _dismissNotification(String id) {
    setState(() {
      _notifications.removeWhere((item) => item.id == id);
    });
  }

  void _markAllAsRead() {
    setState(() {
      for (int i = 0; i < _notifications.length; i++) {
        _notifications[i] = _notifications[i].copyWith(isRead: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Notifications',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actions: [
          if (_notifications.isNotEmpty)
            TextButton(
              onPressed: _markAllAsRead,
              child: const Text(
                'Read all',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _HeaderCard(unreadCount: unreadCount),
          Expanded(
            child: _notifications.isEmpty
                ? const _EmptyNotificationView()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
                    itemCount: _notifications.length,
                    itemBuilder: (context, index) {
                      final notification = _notifications[index];

                      return NotificationCard(
                        notification: notification,
                        onToggleRead: () => _toggleRead(notification.id),
                        onDismiss: () => _dismissNotification(notification.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final int unreadCount;

  const _HeaderCard({required this.unreadCount});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(64),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 24,
            backgroundColor: Colors.white24,
            child: Icon(Icons.notifications_rounded, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Smart Alerts',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  unreadCount == 0
                      ? 'All notifications are read'
                      : '$unreadCount unread notification',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyNotificationView extends StatelessWidget {
  const _EmptyNotificationView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No notifications yet.\nYour smart alerts will appear here.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            height: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
