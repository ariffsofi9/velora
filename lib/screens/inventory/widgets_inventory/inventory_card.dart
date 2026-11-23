import '../../../core/theme/app_tokens.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../models/inventory_item.dart';
import '../../../logic/low_stock_policy.dart';
import '../../../logic/inventory_expiry_policy.dart';

class InventoryCard extends StatelessWidget {
  final InventoryItem item;
  final VoidCallback onTap;
  final VoidCallback? onHistory;
  final DateTime? now;

  const InventoryCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onHistory,
    this.now,
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

  Widget _imageOrIcon(bool isSmall) {
    final size = isSmall ? 58.0 : 66.0;

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: hasImage
            ? kIsWeb
                  ? Icon(
                      _icon(item.category),
                      color: AppColors.textPrimary,
                      size: isSmall ? 28 : 31,
                    )
                  : Image.file(
                      File(item.imageUrl),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => Icon(
                        _icon(item.category),
                        color: AppColors.textPrimary,
                        size: isSmall ? 28 : 31,
                      ),
                    )
            : Icon(
                _icon(item.category),
                color: AppColors.textPrimary,
                size: isSmall ? 28 : 31,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final expiryText = InventoryExpiryPolicy.label(item.expiryDate, now: now);
    final days = InventoryExpiryPolicy.daysUntil(item.expiryDate, now: now);
    final (expiryColor, expirySurface) = switch (days) {
      < 0 => (AppColors.danger, AppColors.dangerSurface),
      <= InventoryExpiryPolicy.nearExpiryDays => (
        AppColors.warning,
        AppColors.warningSurface,
      ),
      _ => (AppColors.success, AppColors.successSurface),
    };
    final attention = LowStockPolicy.attention(item);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _imageOrIcon(MediaQuery.sizeOf(context).width < 370),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${item.category} \u2022 ${item.quantity} ${item.unit} in stock',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _tag(expiryText, expiryColor, expirySurface),
                        if (attention != null)
                          _tag(
                            attention.label,
                            AppColors.danger,
                            AppColors.dangerSurface,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (onHistory != null)
                IconButton(
                  tooltip: 'Stock history for ${item.name}',
                  onPressed: onHistory,
                  icon: const Icon(Icons.history_rounded),
                )
              else
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(String text, Color color, Color background) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}
