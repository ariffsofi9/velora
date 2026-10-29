import 'widgets_inventory/item_detail_hero.dart';
import '../../core/theme/app_tokens.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import '../../services/activity_service.dart';
import 'edit_item_page.dart';
import 'utils_inventory/expiry_helper.dart';
import 'widgets_inventory/item_detail_action_button.dart';
import 'widgets_inventory/item_detail_info_card.dart';
import 'widgets_inventory/mark_as_used_dialog.dart';

class ItemDetailsPage extends StatelessWidget {
  final InventoryItem item;

  const ItemDetailsPage({super.key, required this.item});

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

  Future<void> _deleteItem(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Item?'),
        content: Text('Are you sure you want to delete ${item.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFEF4444)),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await FirebaseFirestore.instance
        .collection('inventory')
        .doc(item.id)
        .delete();

    await ActivityService.addActivity(
      type: 'item_deleted',
      title: 'Deleted ${item.name}',
      subtitle: 'Item removed from inventory',
    );

    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _markAsUsed(BuildContext context) async {
    final usedAmount = await showDialog<int>(
      context: context,
      builder: (_) => MarkAsUsedDialog(currentQuantity: item.quantity),
    );

    if (usedAmount == null) return;

    final newQuantity = item.quantity - usedAmount;

    await FirebaseFirestore.instance
        .collection('inventory')
        .doc(item.id)
        .update({'quantity': newQuantity});

    await FirebaseFirestore.instance.collection('inventory_records').add({
      'itemId': item.id,
      'itemName': item.name,
      'type': 'stock_out',
      'quantity': usedAmount,
      'remainingQuantity': newQuantity,
      'createdAt': Timestamp.now(),
    });

    await ActivityService.addActivity(
      type: 'stock_out',
      title: '${item.name} marked as used',
      subtitle: 'Used $usedAmount, remaining $newQuantity',
    );

    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${item.name} updated successfully'),
        behavior: SnackBarBehavior.floating,
      ),
    );

    Navigator.pop(context);
  }

  void _goToEdit(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditItemPage(item: item)),
    );
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
                      label: 'Edit Item',
                      icon: Icons.edit_outlined,
                      color: AppColors.primary,
                      onTap: () => _goToEdit(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ItemDetailActionButton(
                      label: 'Mark as Used',
                      icon: Icons.check_circle_outline,
                      color: AppColors.success,
                      onTap: () => _markAsUsed(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ItemDetailActionButton(
                      label: 'Delete Item',
                      icon: Icons.delete_outline,
                      color: AppColors.danger,
                      onTap: () => _deleteItem(context),
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
