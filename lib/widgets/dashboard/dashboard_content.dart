import 'package:flutter/material.dart';

import 'dashboard_quick_action_card.dart';
import 'dashboard_style.dart';
import 'dashboard_summary_cards.dart';

/// Presentation only; live values, streams and navigation stay with the page.
class DashboardContent extends StatelessWidget {
  final int totalItems;
  final int nearExpiry;
  final int lowStock;
  final Widget notificationBell;
  final Widget recentActivity;
  final VoidCallback onAddTap;
  final VoidCallback onInventoryTap;
  final VoidCallback onSuggestionTap;
  final VoidCallback onAlertTap;
  const DashboardContent({
    super.key,
    required this.totalItems,
    required this.nearExpiry,
    required this.lowStock,
    required this.notificationBell,
    required this.recentActivity,
    required this.onAddTap,
    required this.onInventoryTap,
    required this.onSuggestionTap,
    required this.onAlertTap,
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
        final padding = constraints.maxWidth < 375 ? 16.0 : 24.0;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              padding: EdgeInsets.all(padding),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Welcome back \u{1F44B}',
                            style: text.headlineSmall?.copyWith(
                              color: DashboardStyle.forest,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Your inventory at a glance.',
                            style: text.bodyMedium?.copyWith(
                              color: DashboardStyle.secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    notificationBell,
                  ],
                ),
                const SizedBox(height: 24),
                InventoryTotalCard(count: totalItems),
                const SizedBox(height: 16),
                InventoryStatusCards(
                  nearExpiry: nearExpiry,
                  lowStock: lowStock,
                ),
                const SizedBox(height: 24),
                Text(
                  'Quick Actions',
                  style: text.titleLarge?.copyWith(
                    color: DashboardStyle.forest,
                  ),
                ),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _action('Add Item', Icons.add_rounded, onAddTap),
                      const SizedBox(width: 12),
                      _action(
                        'Inventory',
                        Icons.inventory_2_outlined,
                        onInventoryTap,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _action(
                        'AI Suggestions',
                        Icons.auto_awesome_outlined,
                        onSuggestionTap,
                      ),
                      const SizedBox(width: 12),
                      _action(
                        'Alerts',
                        Icons.notifications_outlined,
                        onAlertTap,
                      ),
                    ],
                  ),
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
