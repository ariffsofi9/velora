import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import '../../logic/low_stock_policy.dart';
import 'dashboard_style.dart';

class InventoryOverview extends StatelessWidget {
  final int total;
  final int nearExpiry;
  final int lowStock;
  final int outOfStock;
  final int expired;
  final VoidCallback onTap;
  final ValueChanged<StockAttention>? onStockTap;
  const InventoryOverview({
    super.key,
    required this.total,
    required this.nearExpiry,
    required this.lowStock,
    required this.outOfStock,
    required this.expired,
    required this.onTap,
    this.onStockTap,
  });

  Widget _status(
    BuildContext context,
    String label,
    int value,
    IconData icon,
    Color color,
    String key, {
    StockAttention? stockAttention,
  }) => Expanded(
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: .22)),
      ),
      child: InkWell(
        onTap: stockAttention != null && onStockTap != null
            ? () => onStockTap!(stockAttention)
            : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                children: [
                  Icon(icon, color: color, size: 20),
                  Text(
                    '$value',
                    key: ValueKey(key),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
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
        color: AppColors.surface,
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
                      Icons.bar_chart_rounded,
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
      LayoutBuilder(
        builder: (context, constraints) {
          final statuses = [
            _status(
              context,
              StockAttention.lowStock.label,
              lowStock,
              Icons.inventory_2_outlined,
              AppColors.danger,
              'low-stock-count',
              stockAttention: StockAttention.lowStock,
            ),
            _status(
              context,
              StockAttention.outOfStock.label,
              outOfStock,
              Icons.remove_circle_outline,
              AppColors.danger,
              'out-of-stock-count',
              stockAttention: StockAttention.outOfStock,
            ),
            _status(
              context,
              'Near Expiry',
              nearExpiry,
              Icons.schedule_outlined,
              AppColors.warning,
              'near-expiry-count',
            ),
            _status(
              context,
              'Expired',
              expired,
              Icons.event_busy_outlined,
              AppColors.danger,
              'expired-count',
            ),
          ];
          Widget row(List<Widget> tiles) => IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < tiles.length; index++) ...[
                  if (index > 0) const SizedBox(width: 8),
                  tiles[index],
                ],
              ],
            ),
          );
          if (constraints.maxWidth >= 345 &&
              MediaQuery.textScalerOf(context).scale(12) <= 16) {
            return row(statuses);
          }
          return Column(
            children: [
              row(statuses.sublist(0, 2)),
              const SizedBox(height: 8),
              row(statuses.sublist(2)),
            ],
          );
        },
      ),
    ],
  );
}
