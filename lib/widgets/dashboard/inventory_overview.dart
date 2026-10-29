import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import 'dashboard_style.dart';

class InventoryOverview extends StatelessWidget {
  final int total;
  final int nearExpiry;
  final int lowStock;
  final int expired;
  final VoidCallback onTap;
  const InventoryOverview({
    super.key,
    required this.total,
    required this.nearExpiry,
    required this.lowStock,
    required this.expired,
    required this.onTap,
  });

  Widget _status(
    BuildContext context,
    String label,
    int value,
    IconData icon,
    Color color,
    String key,
  ) => Expanded(
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '$value',
                      key: ValueKey(key),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.border),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Inventory Overview',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$total',
                        key: const ValueKey('total-count'),
                        style: Theme.of(context).textTheme.displaySmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(
                      Icons.inventory_2_outlined,
                      color: DashboardStyle.primary,
                      size: 28,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Total Items',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _status(
              context,
              'Low Stock',
              lowStock,
              Icons.inventory_2_outlined,
              AppColors.danger,
              'low-stock-count',
            ),
            const SizedBox(width: 8),
            _status(
              context,
              'Near Expiry',
              nearExpiry,
              Icons.schedule_outlined,
              AppColors.warning,
              'near-expiry-count',
            ),
            const SizedBox(width: 8),
            _status(
              context,
              'Expired',
              expired,
              Icons.event_busy_outlined,
              AppColors.danger,
              'expired-count',
            ),
          ],
        ),
      ),
    ],
  );
}
