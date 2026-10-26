import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

abstract final class DashboardStyle {
  static const background = Color(0xFFFAF9F6);
  static const primary = Color(0xFF183F30);
  static const forest = Color(0xFF102F29);
  static const border = Color(0xFFE1E7DF);
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
