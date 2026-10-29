import '../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

class InventoryHeaderSummary extends StatelessWidget {
  final int totalItems;
  final int visibleItems;
  final bool isSmallPhone;

  const InventoryHeaderSummary({
    super.key,
    required this.totalItems,
    required this.visibleItems,
    required this.isSmallPhone,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = totalItems == visibleItems
        ? '$totalItems items in your inventory'
        : '$visibleItems of $totalItems items shown';

    return Text(
      subtitle,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
    );
  }
}
