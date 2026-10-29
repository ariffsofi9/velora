import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

class TeamRoleBadge extends StatelessWidget {
  final String role;

  const TeamRoleBadge({super.key, required this.role});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: role == 'Owner'
          ? const Color(0xFFFFF7ED)
          : const Color(0xFFEFF6FF),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      role,
      style: TextStyle(
        color: role == 'Owner'
            ? const Color(0xFFB45309)
            : const Color(0xFF1D4ED8),
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
    ),
  );
}

class TeamBackendNotice extends StatelessWidget {
  final String message;

  const TeamBackendNotice({super.key, required this.message});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.nude.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline_rounded, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: AppColors.textSecondary,
              height: 1.4,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    ),
  );
}
