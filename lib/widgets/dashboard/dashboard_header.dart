import 'package:flutter/material.dart';
import 'dashboard_style.dart';

class DashboardHeader extends StatelessWidget {
  final Widget notificationBell;
  final String? firstName;
  final String? photoUrl;
  const DashboardHeader({
    super.key,
    required this.notificationBell,
    this.firstName,
    this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = firstName?.trim().split(RegExp(r'\s+')).first ?? '';
    final uri = Uri.tryParse(photoUrl?.trim() ?? '');
    final photo = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? NetworkImage(uri.toString())
        : null;
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(DateTime.now());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: photo == null ? 'Profile' : 'Profile photo',
          child: CircleAvatar(
            radius: 20,
            backgroundColor: DashboardStyle.primary.withValues(alpha: .10),
            foregroundImage: photo,
            onForegroundImageError: photo == null ? null : (error, stack) {},
            child: Icon(
              Icons.person_outline,
              color: DashboardStyle.primary,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? 'Welcome back' : _greeting(),
                style: (name.isEmpty ? text.titleLarge : text.bodySmall)
                    ?.copyWith(
                      color: name.isEmpty
                          ? DashboardStyle.forest
                          : DashboardStyle.secondary,
                      fontWeight: name.isEmpty
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
              ),
              if (name.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  name,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                date.toUpperCase(),
                style: text.labelSmall?.copyWith(
                  color: DashboardStyle.secondary,
                  letterSpacing: .8,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your inventory at a glance.',
                style: text.bodySmall?.copyWith(
                  color: DashboardStyle.secondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        notificationBell,
      ],
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    return hour < 12
        ? 'Good morning,'
        : hour < 18
        ? 'Good afternoon,'
        : 'Good evening,';
  }
}
