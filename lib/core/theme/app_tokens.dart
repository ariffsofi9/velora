import 'package:flutter/material.dart';

abstract final class AppColors {
  static const primary = Color(0xFF91AB8C);
  static const primaryDark = Color(0xFF526F52);
  static const background = Color(0xFFF8F7F2);
  static const surface = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF252B25);
  static const textSecondary = Color(0xFF697268);
  static const border = Color(0xFFE3E7DF);
  static const lavender = Color(0xFFC8C5E8);
  static const success = Color(0xFF15803D);
  static const warning = Color(0xFFB45309);
  static const danger = Color(0xFFB91C1C);
}

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const minTouchTarget = 48.0;
}

abstract final class AppRadius {
  static const control = 16.0;
  static const card = 20.0;
}
