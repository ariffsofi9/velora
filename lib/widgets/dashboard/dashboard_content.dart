import 'package:flutter/material.dart';

import '../../logic/low_stock_policy.dart';
import 'dashboard_quick_action_card.dart';
import 'dashboard_style.dart';
import 'inventory_overview.dart';
import 'dashboard_header.dart';
import 'inventory_health_card.dart';

/// Presentation only; live values, streams and navigation stay with the page.
class DashboardContent extends StatelessWidget {
  final String? firstName;
  final String? photoUrl;
  final int expired;
  final int totalItems;
  final int nearExpiry;
  final int lowStock;
  final int outOfStock;
  final Widget notificationBell;
  final Widget recentActivity;
  final VoidCallback onAddTap;
  final VoidCallback onInventoryTap;
  final VoidCallback onSuggestionTap;
  final VoidCallback onAlertTap;
  final ValueChanged<StockAttention>? onStockAlertTap;
  final VoidCallback? onStockInTap;
  final VoidCallback? onStockOutTap;
  final bool showInventoryHealth;
  const DashboardContent({
    super.key,
    this.firstName,
    this.photoUrl,
    this.expired = 0,
    required this.totalItems,
    required this.nearExpiry,
    required this.lowStock,
    this.outOfStock = 0,
    required this.notificationBell,
    required this.recentActivity,
    required this.onAddTap,
    required this.onInventoryTap,
    required this.onSuggestionTap,
    required this.onAlertTap,
    this.onStockAlertTap,
    this.onStockInTap,
    this.onStockOutTap,
    this.showInventoryHealth = true,
  });

  Widget _action(String title, IconData icon, VoidCallback onTap) => Expanded(
    child: DashboardQuickActionCard(
      icon: icon,
      title: title,
      color: DashboardStyle.primary,
      onTap: onTap,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth < 375 ? 16.0 : 18.0;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: EdgeInsets.all(padding),
              children: [
                DashboardHeader(
                  notificationBell: notificationBell,
                  firstName: firstName,
                  photoUrl: photoUrl,
                ),
                const SizedBox(height: 20),
                InventoryOverview(
                  total: totalItems,
                  nearExpiry: nearExpiry,
                  lowStock: lowStock,
                  outOfStock: outOfStock,
                  expired: expired,
                  onTap: onInventoryTap,
                  onStockTap: onStockAlertTap,
                ),
                if (showInventoryHealth) ...[
                  const SizedBox(height: 16),
                  InventoryHealthCard(
                    total: totalItems,
                    nearExpiry: nearExpiry,
                    lowStock: lowStock,
                    outOfStock: outOfStock,
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Quick Actions',
                  style: text.titleMedium?.copyWith(
                    color: DashboardStyle.forest,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, size) {
                    final four =
                        size.maxWidth >= 350 &&
                        MediaQuery.textScalerOf(context).scale(12) <= 16;
                    final actions = [
                      _action('Add Item', Icons.add_rounded, onAddTap),
                      _action(
                        onStockInTap == null ? 'Inventory' : 'Stock In',
                        onStockInTap == null
                            ? Icons.inventory_2_outlined
                            : Icons.add_box_outlined,
                        onStockInTap ?? onInventoryTap,
                      ),
                      if (onStockOutTap != null)
                        _action(
                          'Stock Out',
                          Icons.outbox_outlined,
                          onStockOutTap!,
                        ),
                      _action(
                        'AI Suggestions',
                        Icons.auto_awesome_outlined,
                        onSuggestionTap,
                      ),
                      if (onStockOutTap == null)
                        _action(
                          'Alerts',
                          Icons.notifications_outlined,
                          onAlertTap,
                        ),
                    ];
                    Widget row(List<Widget> items) => IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) const SizedBox(width: 8),
                            items[i],
                          ],
                        ],
                      ),
                    );
                    if (four) return row(actions);
                    return Column(
                      children: [
                        for (
                          var index = 0;
                          index < actions.length;
                          index += 2
                        ) ...[
                          if (index > 0) const SizedBox(height: 10),
                          row(actions.skip(index).take(2).toList()),
                        ],
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                recentActivity,
              ],
            ),
          ),
        );
      },
    );
  }
}
