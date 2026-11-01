import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/inventory_item.dart';
import '../../logic/low_stock_policy.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../services/workspace_session.dart';
import '../notifications/widgets_notification/notification_filter_bar.dart';

class AlertsPage extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryRepository? repository;

  const AlertsPage({super.key, this.workspaceSession, this.repository});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  static const red = Color(0xFFEF4444);
  static const orange = Color(0xFFF97316);

  Stream<List<InventoryItem>>? _itemsStream;
  String _selectedFilter = 'All';

  @override
  void initState() {
    super.initState();
    var repository = widget.repository;
    final session = widget.workspaceSession;
    if (repository == null && session != null) {
      repository = WorkspaceInventoryRepository(session: session);
    }
    _itemsStream = repository?.watchItems();
  }

  bool _isLowStock(InventoryItem item) => LowStockPolicy.isLowStock(item);

  bool _isNearExpiry(InventoryItem item, DateTime now) {
    if (item.expiryDate.millisecondsSinceEpoch == 0) return false;
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      item.expiryDate.year,
      item.expiryDate.month,
      item.expiryDate.day,
    );
    final difference = expiry.difference(today).inDays;
    return difference >= 0 && difference <= 4;
  }

  bool _matchesFilter({required bool isLowStock, required bool isNearExpiry}) {
    if (!isLowStock && !isNearExpiry) return false;
    if (_selectedFilter == 'Low Stock') return isLowStock;
    if (_selectedFilter == 'Near Expiry') return isNearExpiry;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final itemsStream = _itemsStream;
    if (itemsStream == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Alerts are unavailable because workspace access was not verified.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ),
        ),
      );
    }

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
      body: StreamBuilder<List<InventoryItem>>(
        stream: itemsStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: () => setState(() {}),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry alerts'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          final now = DateTime.now();
          final alerts = snapshot.data!
              .where((item) {
                return _matchesFilter(
                  isLowStock: _isLowStock(item),
                  isNearExpiry: _isNearExpiry(item, now),
                );
              })
              .toList(growable: false);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: SizedBox(
                height: double.infinity,
                child: Column(
                  children: [
                    NotificationFilterBar(
                      selected: _selectedFilter,
                      onSelected: (value) {
                        setState(() => _selectedFilter = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: alerts.isEmpty
                          ? const _EmptyAlerts()
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                              itemCount: alerts.length,
                              itemBuilder: (context, index) {
                                final item = alerts[index];
                                return _InventoryAlertCard(
                                  name: item.name,
                                  quantity: item.quantity,
                                  isLowStock: _isLowStock(item),
                                  isNearExpiry: _isNearExpiry(item, now),
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
      ),
    );
  }
}

class _InventoryAlertCard extends StatelessWidget {
  final String name;
  final int quantity;
  final bool isLowStock;
  final bool isNearExpiry;

  const _InventoryAlertCard({
    required this.name,
    required this.quantity,
    required this.isLowStock,
    required this.isNearExpiry,
  });

  @override
  Widget build(BuildContext context) {
    final message = isLowStock && isNearExpiry
        ? 'Low stock and expiring soon'
        : isLowStock
        ? 'Low stock: $quantity left'
        : 'Expiring soon';
    final color = isLowStock ? _AlertsPageState.red : _AlertsPageState.orange;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isLowStock
                  ? Icons.warning_amber_rounded
                  : Icons.access_time_rounded,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
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

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) => const Center(
    child: Text(
      'No active alerts.\nYour inventory looks good.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
    ),
  );
}
