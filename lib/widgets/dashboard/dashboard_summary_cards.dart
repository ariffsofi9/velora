import 'package:flutter/material.dart';

import 'dashboard_style.dart';

class InventoryTotalCard extends StatelessWidget {
  final int count;
  const InventoryTotalCard({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: DashboardStyle.forest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.inventory_2_outlined, color: Colors.white, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total Inventory',
                  style: text.bodyMedium?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  '$count',
                  key: const ValueKey('total-count'),
                  style: text.headlineLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Items currently in inventory',
                  style: text.bodySmall?.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class InventoryStatusCards extends StatelessWidget {
  final int nearExpiry;
  final int lowStock;
  const InventoryStatusCards({
    super.key,
    required this.nearExpiry,
    required this.lowStock,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _StatusCard(
              title: 'Near Expiry',
              count: nearExpiry,
              countKey: const ValueKey('near-expiry-count'),
              icon: Icons.schedule_outlined,
              color: DashboardStyle.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatusCard(
              title: 'Low Stock',
              count: lowStock,
              countKey: const ValueKey('low-stock-count'),
              icon: Icons.warning_amber_rounded,
              color: DashboardStyle.danger,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title;
  final int count;
  final Key countKey;
  final IconData icon;
  final Color color;
  const _StatusCard({
    required this.title,
    required this.count,
    required this.countKey,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: DashboardStyle.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 12),
          Text(
            '$count',
            key: countKey,
            style: text.headlineSmall?.copyWith(
              color: DashboardStyle.forest,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: text.bodyMedium?.copyWith(color: DashboardStyle.secondary),
          ),
        ],
      ),
    );
  }
}
