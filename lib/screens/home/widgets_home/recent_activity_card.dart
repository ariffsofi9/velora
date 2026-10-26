import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../../widgets/dashboard/dashboard_style.dart';
import '../../../widgets/dashboard/activity_thumbnail.dart';

class RecentActivityCard extends StatelessWidget {
  final FirebaseFirestore? firestore;
  final Map<String, Map<String, dynamic>> inventoryItems;
  const RecentActivityCard({
    super.key,
    this.firestore,
    this.inventoryItems = const {},
  });

  String _formatType(String type) {
    switch (type) {
      case 'stock_in':
        return 'Stock In';
      case 'stock_out':
        return 'Stock Out';
      case 'add_item':
        return 'Item Added';
      default:
        return 'Activity';
    }
  }

  IconData _icon(String type) {
    switch (type) {
      case 'stock_in':
      case 'add_item':
        return Icons.add_circle_rounded;
      case 'stock_out':
        return Icons.remove_circle_rounded;
      default:
        return Icons.history_rounded;
    }
  }

  Color _color(String type) {
    switch (type) {
      case 'stock_in':
      case 'add_item':
        return DashboardStyle.primary;
      case 'stock_out':
        return DashboardStyle.danger;
      default:
        return DashboardStyle.secondary;
    }
  }

  String _timeAgo(dynamic rawTime) {
    if (rawTime is! Timestamp) return 'Recently';

    final time = rawTime.toDate();
    final diff = DateTime.now().difference(time);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) {
      return '${diff.inHours} ${diff.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    return '${diff.inDays} ${diff.inDays == 1 ? 'day' : 'days'} ago';
  }

  String _message(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    final itemName = (data['itemName'] ?? data['name'] ?? 'Item').toString();
    final quantity = data['quantity'] ?? data['usedQuantity'] ?? '';

    if (type == 'stock_in' || type == 'add_item') {
      return '$itemName added to inventory';
    }

    if (type == 'stock_out') {
      return '$itemName used from inventory${quantity == '' ? '' : ' • $quantity used'}';
    }

    return '$itemName updated';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: DashboardStyle.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent Activity',
            style: text.titleLarge?.copyWith(color: DashboardStyle.forest),
          ),
          const SizedBox(height: 16),
          StreamBuilder<QuerySnapshot>(
            stream: (firestore ?? FirebaseFirestore.instance)
                .collection('inventory_records')
                .orderBy('createdAt', descending: true)
                .limit(4)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text(
                  'Recent activity cannot load right now.',
                  style: TextStyle(color: DashboardStyle.danger),
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
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return const Text(
                  'No stock activity yet.',
                  style: TextStyle(color: DashboardStyle.secondary),
                );
              }
              return Column(
                children: docs.map((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final type = (data['type'] ?? '').toString();
                  final color = _color(type);
                  final item =
                      inventoryItems[data['itemId']?.toString()] ??
                      const <String, dynamic>{};
                  final image = (data['imageUrl'] ?? item['imageUrl'] ?? '')
                      .toString();
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: doc == docs.last
                          ? null
                          : const Border(
                              bottom: BorderSide(color: DashboardStyle.border),
                            ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: color.withAlpha(20),
                          child: Icon(_icon(type), color: color, size: 20),
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
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _message(data),
                                style: text.bodyMedium?.copyWith(
                                  color: DashboardStyle.secondary,
                                ),
                              ),
                              if (MediaQuery.textScalerOf(context).scale(12) >
                                      16 ||
                                  MediaQuery.sizeOf(context).width < 375) ...[
                                const SizedBox(height: 4),
                                Text(
                                  _timeAgo(data['createdAt']),
                                  style: text.bodySmall?.copyWith(
                                    color: DashboardStyle.secondary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (MediaQuery.textScalerOf(context).scale(12) <= 16 &&
                            MediaQuery.sizeOf(context).width >= 375) ...[
                          const SizedBox(width: 8),
                          Text(
                            _timeAgo(data['createdAt']),
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
