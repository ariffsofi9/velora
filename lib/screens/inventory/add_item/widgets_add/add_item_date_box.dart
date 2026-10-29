import '../../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

class AddItemDateBox extends StatelessWidget {
  final String expiryText;
  final DateTime? selectedDate;
  final VoidCallback onTap;

  const AddItemDateBox({
    super.key,
    required this.expiryText,
    required this.selectedDate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = selectedDate == null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                expiryText,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isEmpty
                      ? const Color(0xFF9CA3AF)
                      : AppColors.textPrimary,
                ),
              ),
            ),
            const Icon(
              Icons.calendar_month_outlined,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
