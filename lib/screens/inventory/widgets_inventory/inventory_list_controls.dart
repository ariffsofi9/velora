import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../utils_inventory/inventory_sort_helper.dart';

class InventoryListControls extends StatelessWidget {
  final List<String> categories;
  final String selectedCategory;
  final InventorySortOption selectedSort;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<InventorySortOption> onSortChanged;

  const InventoryListControls({
    super.key,
    required this.categories,
    required this.selectedCategory,
    required this.selectedSort,
    required this.onCategoryChanged,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final category = _field(
          label: 'Category',
          child: DropdownButtonFormField<String>(
            key: const ValueKey('inventory-category-filter'),
            initialValue: selectedCategory,
            isExpanded: true,
            items: categories
                .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value != null) onCategoryChanged(value);
            },
          ),
        );
        final sort = _field(
          label: 'Sort by',
          child: DropdownButtonFormField<InventorySortOption>(
            key: const ValueKey('inventory-sort-order'),
            initialValue: selectedSort,
            isExpanded: true,
            items: InventorySortOption.values
                .map(
                  (value) =>
                      DropdownMenuItem(value: value, child: Text(value.label)),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value != null) onSortChanged(value);
            },
          ),
        );

        if (constraints.maxWidth < 520) {
          return Column(children: [category, const SizedBox(height: 12), sort]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: category),
            const SizedBox(width: 12),
            Expanded(child: sort),
          ],
        );
      },
    );
  }

  Widget _field({required String label, required Widget child}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 6),
      child,
    ],
  );
}
