import '../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

class InventoryFilterChips extends StatelessWidget {
  final String selectedFilter;
  final ValueChanged<String> onSelected;

  const InventoryFilterChips({
    super.key,
    required this.selectedFilter,
    required this.onSelected,
  });

  static const filters = ['All Items', 'Low Stock', 'Near Expiry'];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: filters.map((filter) {
        final isSelected = selectedFilter == filter;

        return ChoiceChip(
          label: Text(filter),
          selected: isSelected,
          onSelected: (_) => onSelected(filter),
          selectedColor: AppColors.primary,
          backgroundColor: Colors.white,
          labelStyle: TextStyle(
            color: isSelected ? Colors.white : AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
          side: BorderSide(
            color: isSelected ? AppColors.primary : AppColors.border,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        );
      }).toList(),
    );
  }
}
