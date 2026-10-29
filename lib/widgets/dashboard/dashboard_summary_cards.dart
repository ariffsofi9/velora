import 'package:flutter/material.dart';
import 'dashboard_style.dart';

class InventoryTotalCard extends StatelessWidget {
  final int count;
  final VoidCallback? onTap;
  const InventoryTotalCard({super.key, required this.count, this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: const BoxDecoration(color: Colors.white),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: DashboardStyle.background,
                  child: const Icon(
                    Icons.inventory_2_outlined,
                    color: DashboardStyle.forest,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Inventory',
                        style: text.bodyMedium?.copyWith(
                          color: DashboardStyle.forest,
                        ),
                      ),
                      Text(
                        '$count',
                        key: const ValueKey('total-count'),
                        style: text.displayMedium?.copyWith(
                          color: DashboardStyle.forest,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'items currently in inventory',
                        style: text.bodySmall?.copyWith(
                          color: DashboardStyle.forest,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: DashboardStyle.background,
                    child: const Icon(
                      Icons.chevron_right,
                      color: DashboardStyle.forest,
                      size: 25,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class InventoryStatusCards extends StatelessWidget {
  final int nearExpiry;
  final int lowStock;
  final VoidCallback? onTap;
  const InventoryStatusCards({
    super.key,
    required this.nearExpiry,
    required this.lowStock,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
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
            detail: 'items expiring soon',
            onTap: onTap,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatusCard(
            title: 'Low Stock',
            count: lowStock,
            countKey: const ValueKey('low-stock-count'),
            icon: Icons.warning_amber_rounded,
            color: DashboardStyle.danger,
            detail: 'items running low',
            onTap: onTap,
          ),
        ),
      ],
    ),
  );
}

class _StatusCard extends StatelessWidget {
  final String title;
  final String detail;
  final int count;
  final Key countKey;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  const _StatusCard({
    required this.title,
    required this.count,
    required this.countKey,
    required this.icon,
    required this.color,
    required this.detail,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final compact =
        MediaQuery.textScalerOf(context).scale(12) > 16 ||
        MediaQuery.sizeOf(context).width < 375;
    final badge = CircleAvatar(
      radius: 20,
      backgroundColor: color.withValues(alpha: .12),
      child: Icon(icon, color: color, size: 24),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: text.labelMedium?.copyWith(
            color: DashboardStyle.forest,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                '$count',
                key: countKey,
                style: text.headlineSmall?.copyWith(
                  color: DashboardStyle.forest,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onTap != null)
              const Icon(
                Icons.chevron_right,
                color: DashboardStyle.secondary,
                size: 20,
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          detail,
          style: text.bodySmall?.copyWith(color: DashboardStyle.secondary),
        ),
      ],
    );
    return Material(
      color: DashboardStyle.forest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DashboardStyle.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [badge, const SizedBox(height: 8), content],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    badge,
                    const SizedBox(width: 10),
                    Expanded(child: content),
                  ],
                ),
        ),
      ),
    );
  }
}
