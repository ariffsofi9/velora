import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

abstract final class DashboardStyle {
  static const background = Color(0xFFFAF9F6);
  static const primary = Color(0xFF55745B);
  static const forest = Color(0xFF203B30);
  static const border = Color(0xFFE1E7DF);
  static const secondary = AppColors.textSecondary;
  static const warning = AppColors.warning;
  static const danger = Color(0xFF9C4B45);

  static BoxDecoration get card => BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(AppRadius.card),
    border: Border.all(color: border),
  );
}
