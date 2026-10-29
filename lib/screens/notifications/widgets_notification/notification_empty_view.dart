import '../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

class NotificationEmptyView extends StatelessWidget {
  const NotificationEmptyView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No active alerts.\nYour inventory looks good.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 14,
          height: 1.5,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}
