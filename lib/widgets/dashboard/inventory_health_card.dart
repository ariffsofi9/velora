import 'package:flutter/material.dart';
import 'dashboard_style.dart';

class InventoryHealthCard extends StatelessWidget {
  final int total;
  final int nearExpiry;
  final int lowStock;
  final bool unavailable;
  const InventoryHealthCard({
    super.key,
    this.total = 0,
    this.nearExpiry = 0,
    this.lowStock = 0,
    this.unavailable = false,
  });

  @override
  Widget build(BuildContext context) {
    final warning = nearExpiry > 0 || lowStock > 0;
    final title = unavailable
        ? 'Inventory health unavailable'
        : total == 0
        ? 'Your inventory is empty'
        : warning
        ? 'Your inventory needs attention'
        : 'Your inventory looks healthy';
    final message = unavailable
        ? 'Inventory could not be loaded. Please try again later.'
        : total == 0
        ? 'Add your first item to start tracking stock.'
        : warning
        ? 'Review near-expiry and low-stock items.'
        : 'No current expiry or stock warnings.';
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DashboardStyle.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: DashboardStyle.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            unavailable
                ? Icons.cloud_off_outlined
                : warning
                ? Icons.info_outline
                : total == 0
                ? Icons.inventory_2_outlined
                : Icons.check_circle_outline,
            color: DashboardStyle.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleSmall?.copyWith(
                    color: DashboardStyle.forest,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: text.bodySmall?.copyWith(
                    color: DashboardStyle.secondary,
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
