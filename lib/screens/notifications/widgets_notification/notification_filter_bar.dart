import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';

class NotificationFilterBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelected;

  const NotificationFilterBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const filters = ['All', 'Low Stock', 'Near Expiry'];

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(
      children: filters.map((filter) {
        final active = selected == filter;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(filter),
            selected: active,
            onSelected: (_) => onSelected(filter),
            selectedColor: AppColors.primary,
            backgroundColor: AppColors.surface,
            side: BorderSide(
              color: active ? AppColors.primary : AppColors.border,
            ),
            labelStyle: TextStyle(
              color: active ? Colors.white : AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }).toList(),
    ),
  );
}
