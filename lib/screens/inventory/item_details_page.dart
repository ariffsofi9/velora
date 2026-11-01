import 'widgets_inventory/item_detail_hero.dart';
import '../../core/theme/app_tokens.dart';

import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../services/workspace_inventory_update_service.dart';
import '../../services/workspace_inventory_stock_service.dart';
import '../../services/workspace_session.dart';
import 'edit_item_page.dart';
import 'stock/stock_adjustment_page.dart';
import 'utils_inventory/expiry_helper.dart';
import 'widgets_inventory/item_detail_action_button.dart';
import 'widgets_inventory/item_detail_info_card.dart';

class ItemDetailsPage extends StatelessWidget {
  final InventoryItem item;
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final WorkspaceInventoryUpdater? updater;
  final WorkspaceInventoryStockAdjuster? stockAdjuster;

  const ItemDetailsPage({
    super.key,
    required this.item,
    this.workspaceSession,
    this.repository,
    this.updater,
    this.stockAdjuster,
  });

  bool get hasImage => item.imageUrl.trim().isNotEmpty;

  IconData _icon(String category) {
    final value = category.toLowerCase();

    if (value.contains('dairy')) return Icons.local_drink_rounded;
    if (value.contains('meat')) return Icons.restaurant_rounded;
    if (value.contains('vegetable')) return Icons.eco_rounded;
    if (value.contains('fruit')) return Icons.apple_rounded;
    if (value.contains('grain')) return Icons.rice_bowl_rounded;

    return Icons.inventory_2_rounded;
  }

  Color _iconBg(String category) {
    final value = category.toLowerCase();

    if (value.contains('dairy')) return AppColors.nude;
    if (value.contains('meat')) return AppColors.nude;
    if (value.contains('vegetable')) return AppColors.nude;
    if (value.contains('fruit')) return AppColors.nude;
    if (value.contains('grain')) return AppColors.nude;

    return AppColors.nude;
  }

  Color _iconColor(String category) {
    final value = category.toLowerCase();

    if (value.contains('dairy')) return AppColors.primary;
    if (value.contains('meat')) return AppColors.primary;
    if (value.contains('vegetable')) return AppColors.primary;
    if (value.contains('fruit')) return AppColors.primary;
    if (value.contains('grain')) return AppColors.primary;

    return AppColors.primary;
  }

  String _dateText(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> _goToEdit(BuildContext context) async {
    if (workspaceSession == null || item.id.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Editing requires a verified workspace item.'),
        ),
      );
      return;
    }
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EditItemPage(
          item: item,
          workspaceSession: workspaceSession,
          repository: repository,
          updater: updater,
        ),
      ),
    );
    if (updated == true && context.mounted) Navigator.pop(context, true);
  }

  Future<void> _goToStock(
    BuildContext context,
    StockAdjustmentType type,
  ) async {
    if (workspaceSession == null || item.id.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stock adjustments require a verified workspace item.'),
        ),
      );
      return;
    }
    final adjusted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => type == StockAdjustmentType.stockIn
            ? StockInPage(
                item: item,
                workspaceSession: workspaceSession,
                repository: repository,
                adjuster: stockAdjuster,
              )
            : StockOutPage(
                item: item,
                workspaceSession: workspaceSession,
                repository: repository,
                adjuster: stockAdjuster,
              ),
      ),
    );
    if (adjusted == true && context.mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isSmall = width < 370;

    final expiryText = ExpiryHelper.daysLeftText(item.expiryDate);
    final expiryColor = ExpiryHelper.statusColor(item.expiryDate);
    final expiryBg = ExpiryHelper.statusBgColor(item.expiryDate);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Item Details',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              isSmall ? 16 : 22,
              8,
              isSmall ? 16 : 22,
              130,
            ),
            children: [
              ItemDetailHero(
                item: item,
                hasImage: hasImage,
                icon: _icon(item.category),
                iconBg: _iconBg(item.category),
                iconColor: _iconColor(item.category),
                expiryText: expiryText,
                expiryColor: expiryColor,
                expiryBg: expiryBg,
                isSmall: isSmall,
              ),
              const SizedBox(height: 18),
              ItemDetailInfoCard(
                rows: [
                  ItemDetailInfoRow(
                    label: 'Quantity',
                    value: item.quantity.toString(),
                  ),
                  ItemDetailInfoRow(label: 'Category', value: item.category),
                  ItemDetailInfoRow(
                    label: 'Expiry Date',
                    value: _dateText(item.expiryDate),
                  ),
                  ItemDetailInfoRow(
                    label: 'Stored On',
                    value: _dateText(item.createdAt),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ItemDetailTipsCard(
                expiryText: expiryText,
                expiryColor: expiryColor,
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.only(top: 8, bottom: 14),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isSmall ? 16 : 22),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ItemDetailActionButton(
                      label: 'Stock In',
                      icon: Icons.add_circle_outline,
                      color: AppColors.primary,
                      onTap: () =>
                          _goToStock(context, StockAdjustmentType.stockIn),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ItemDetailActionButton(
                      label: 'Stock Out',
                      icon: Icons.remove_circle_outline,
                      color: AppColors.warning,
                      onTap: () =>
                          _goToStock(context, StockAdjustmentType.stockOut),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ItemDetailActionButton(
                      label: 'Edit Item',
                      icon: Icons.edit_outlined,
                      color: AppColors.primary,
                      onTap: () => _goToEdit(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
