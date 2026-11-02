import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../logic/inventory_expiry_policy.dart';

class ExpiryHelper {
  static int daysLeft(DateTime expiryDate) =>
      InventoryExpiryPolicy.daysUntil(expiryDate);

  static String daysLeftText(DateTime expiryDate) {
    return InventoryExpiryPolicy.label(expiryDate);
  }

  static bool isExpired(DateTime expiryDate) {
    return InventoryExpiryPolicy.isExpired(expiryDate);
  }

  static bool isNearExpiry(DateTime expiryDate) {
    return InventoryExpiryPolicy.isNearExpiry(expiryDate);
  }

  static Color statusColor(DateTime expiryDate) {
    final days = daysLeft(expiryDate);

    if (days < 0) return const Color(0xFFEF4444);
    if (days <= 1) return const Color(0xFFEF4444);
    if (days <= 3) return const Color(0xFFF59E0B);
    if (days <= 7) return AppColors.primary;

    return const Color(0xFF10B981);
  }

  static Color statusBgColor(DateTime expiryDate) {
    final days = daysLeft(expiryDate);

    if (days < 0) return const Color(0xFFFFE4E6);
    if (days <= 1) return const Color(0xFFFFE4E6);
    if (days <= 3) return const Color(0xFFFFF3E0);
    if (days <= 7) return AppColors.nude;

    return const Color(0xFFDCFCE7);
  }
}
