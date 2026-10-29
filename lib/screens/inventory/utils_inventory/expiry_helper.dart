import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';

class ExpiryHelper {
  static int daysLeft(DateTime expiryDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);

    return expiry.difference(today).inDays;
  }

  static String daysLeftText(DateTime expiryDate) {
    final days = daysLeft(expiryDate);

    if (days < 0) return 'Expired ${days.abs()} days ago';
    if (days == 0) return 'Expires today';
    if (days == 1) return '1 day left';

    return '$days days left';
  }

  static bool isExpired(DateTime expiryDate) {
    return daysLeft(expiryDate) < 0;
  }

  static bool isNearExpiry(DateTime expiryDate) {
    final days = daysLeft(expiryDate);
    return days >= 0 && days <= 3;
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
