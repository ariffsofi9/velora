import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

abstract final class DashboardStyle {
  static const background = AppColors.background;
  static const primary = AppColors.primary;
  static const forest = AppColors.textPrimary;
  static const border = AppColors.border;
  static const secondary = AppColors.textSecondary;
  static const warning = Color(0xFFE99A18);
  static const danger = Color(0xFFE5534B);

  static BoxDecoration get card => BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(AppRadius.card),
    border: Border.all(color: border),
    boxShadow: [
      BoxShadow(
        color: forest.withValues(alpha: .025),
        blurRadius: 12,
        offset: const Offset(0, 3),
      ),
    ],
  );
}
