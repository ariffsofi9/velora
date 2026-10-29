import 'package:flutter/material.dart';

abstract final class AppColors {
  static const nude = Color(0xFFEADFCC);
  static const sand = nude;
  static const primary = Color(0xFF886F47);
  static const primaryDark = primary;
  static const background = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF171717);
  static const textSecondary = Color(0xFF666666);
  static const border = nude;
  static const lavender = Color(0xFFEADFCC);
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
  static const control = 10.0;
  static const card = 14.0;
}
