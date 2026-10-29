import '../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import 'settings_section_card.dart';

class AppInfoCard extends StatelessWidget {
  const AppInfoCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsSectionCard(
      title: 'App Information',
      children: [
        _InfoRow(icon: Icons.apps_rounded, title: 'App Name', value: 'Velora'),
        _InfoRow(
          icon: Icons.verified_rounded,
          title: 'Version',
          value: '1.0.0',
        ),
        _InfoRow(
          icon: Icons.lightbulb_outline_rounded,
          title: 'Purpose',
          value: 'AI Smart Inventory',
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        height: 42,
        width: 42,
        decoration: BoxDecoration(
          color: const Color(0xFFECFDF5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: const Color(0xFF10B981)),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      trailing: Text(
        value,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
