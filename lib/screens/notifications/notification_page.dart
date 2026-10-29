import '../../core/theme/app_tokens.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'notification_alert_item.dart';
import 'notification_service.dart';
import 'widgets_notification/notification_alert_card.dart';
import 'widgets_notification/notification_empty_view.dart';
import 'widgets_notification/notification_filter_bar.dart';
import 'widgets_notification/notification_header_card.dart';

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  final NotificationService _service = NotificationService();

  bool _isSyncing = false;
  String _selectedFilter = 'All';

  Future<void> _syncInventoryAlerts(List<QueryDocumentSnapshot> docs) async {
    if (_isSyncing) return;

    _isSyncing = true;

    final alerts = _service.buildAlertsFromInventory(docs);
    await _service.syncMissingNotifications(alerts);

    _isSyncing = false;
  }

  List<NotificationAlertItem> _activeAlerts(QuerySnapshot snapshot) {
    return snapshot.docs
        .map(NotificationAlertItem.fromDoc)
        .where((item) => !item.isDismissed)
        .toList();
  }

  List<NotificationAlertItem> _filteredAlerts(
    List<NotificationAlertItem> alerts,
  ) {
    switch (_selectedFilter) {
      case 'Low Stock':
        return alerts.where((item) => item.type == AlertType.stock).toList();
      case 'Near Expiry':
        return alerts.where((item) => item.type == AlertType.expiry).toList();
      default:
        return alerts;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Alerts',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('inventory').snapshots(),
        builder: (context, inventorySnapshot) {
          if (inventorySnapshot.hasError) {
            return _AlertErrorView(onRetry: () => setState(() {}));
          }

          if (!inventorySnapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            _syncInventoryAlerts(inventorySnapshot.data!.docs);
          });

          return StreamBuilder<QuerySnapshot>(
            stream: _service.notificationStream(),
            builder: (context, notificationSnapshot) {
              if (notificationSnapshot.hasError) {
                return _AlertErrorView(onRetry: () => setState(() {}));
              }

              if (!notificationSnapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                );
              }

              final alerts = _activeAlerts(notificationSnapshot.data!);
              final visibleAlerts = _filteredAlerts(alerts);
              final unreadCount = alerts.where((item) => !item.isRead).length;

              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: SizedBox(
                    height: double.infinity,
                    child: Column(
                      children: [
                        NotificationHeaderCard(
                          total: alerts.length,
                          unread: unreadCount,
                          onReadAll: () => _service.markAllAsRead(alerts),
                        ),
                        NotificationFilterBar(
                          selected: _selectedFilter,
                          onSelected: (value) {
                            setState(() => _selectedFilter = value);
                          },
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: visibleAlerts.isEmpty
                              ? const NotificationEmptyView()
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    8,
                                    20,
                                    24,
                                  ),
                                  itemCount: visibleAlerts.length,
                                  itemBuilder: (context, index) {
                                    final alert = visibleAlerts[index];

                                    return NotificationAlertCard(
                                      alert: alert,
                                      isRead: alert.isRead,
                                      onToggleRead: () =>
                                          _service.toggleRead(alert),
                                      onDismiss: () => _service.dismiss(alert),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AlertErrorView extends StatelessWidget {
  final VoidCallback onRetry;

  const _AlertErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            color: AppColors.textSecondary,
            size: 36,
          ),
          const SizedBox(height: 12),
          const Text(
            'Alerts are unavailable right now.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
