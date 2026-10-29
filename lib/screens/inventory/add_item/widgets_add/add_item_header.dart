import 'package:flutter/material.dart';
import '../../../../core/theme/app_tokens.dart';

class AddItemHeader extends StatelessWidget {
  const AddItemHeader({super.key});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        onPressed: () => Navigator.pop(context),
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          'Add New Item',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}
