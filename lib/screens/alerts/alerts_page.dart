import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../notifications/widgets_notification/notification_filter_bar.dart';

class AlertsPage extends StatefulWidget {
  final FirebaseFirestore? firestore;

  const AlertsPage({super.key, this.firestore});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  static const red = Color(0xFFEF4444);
  static const orange = Color(0xFFF97316);

  String _selectedFilter = 'All';

  bool _isLowStock(Map<String, dynamic> data) {
    final quantity = (data['quantity'] ?? 0) as num;
    return quantity.toInt() <= 5;
  }

  bool _isNearExpiry(Map<String, dynamic> data, DateTime now) {
    final expiry = data['expiryDate'];
    if (expiry is! Timestamp) return false;
    final difference = expiry.toDate().difference(now).inDays;
    return difference >= 0 && difference <= 4;
  }

  bool _matchesFilter({required bool isLowStock, required bool isNearExpiry}) {
    if (!isLowStock && !isNearExpiry) return false;
    if (_selectedFilter == 'Low Stock') return isLowStock;
    if (_selectedFilter == 'Near Expiry') return isNearExpiry;
    return true;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
      stream: (widget.firestore ?? FirebaseFirestore.instance)
          .collection('inventory')
          .snapshots(),
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
        final alerts = snapshot.data!.docs.where((document) {
          final data = document.data() as Map<String, dynamic>;
          return _matchesFilter(
            isLowStock: _isLowStock(data),
            isNearExpiry: _isNearExpiry(data, now),
          );
        }).toList();

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
                              final data =
                                  alerts[index].data() as Map<String, dynamic>;
                              final quantity = (data['quantity'] ?? 0) as num;
                              return _InventoryAlertCard(
                                name: (data['name'] ?? 'Item').toString(),
                                quantity: quantity.toInt(),
                                isLowStock: _isLowStock(data),
                                isNearExpiry: _isNearExpiry(data, now),
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
