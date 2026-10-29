import '../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../settings/widgets_settings/settings_section_card.dart';

class PreferencesSettingsCard extends StatelessWidget {
  final bool darkModePrep;
  final VoidCallback onOpenAppearance;

  const PreferencesSettingsCard({
    super.key,
    required this.darkModePrep,
    required this.onOpenAppearance,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      title: 'Appearance',
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          onTap: onOpenAppearance,
          leading: Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              color: AppColors.nude,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.palette_outlined, color: AppColors.primary),
          ),
          title: const Text(
            'App Appearance',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            darkModePrep
                ? 'Dark preview saved · App remains Light'
                : 'Light preview · Theme controls',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}
