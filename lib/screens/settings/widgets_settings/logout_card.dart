import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';

class LogoutCard extends StatelessWidget {
  final VoidCallback onLogout;
  const LogoutCard({super.key, required this.onLogout});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: onLogout,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFFFE9E4),
        foregroundColor: AppColors.danger,
      ),
      icon: const Icon(Icons.logout, size: 20),
      label: const Text('Sign Out'),
    ),
  );
}
