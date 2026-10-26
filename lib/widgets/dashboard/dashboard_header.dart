import 'package:flutter/material.dart';
import 'dashboard_style.dart';

class DashboardHeader extends StatelessWidget {
  final Widget notificationBell;
  final String? firstName;
  const DashboardHeader({
    super.key,
    required this.notificationBell,
    this.firstName,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = firstName?.trim().split(RegExp(r'\s+')).first ?? '';
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(DateTime.now());
    return Stack(
      children: [
        Positioned(
          right: -30,
          bottom: -68,
          child: IgnorePointer(
            child: Opacity(
              opacity: .13,
              child: Image.asset(
                'assets/images/auth/leaf_small_1.png',
                width: 185,
                height: 230,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Image.asset(
                  'assets/images/auth/logo_mark.png',
                  width: 46,
                  height: 46,
                  fit: BoxFit.contain,
                  semanticLabel: 'Velora leaf logo',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Velora',
                    style: text.headlineMedium?.copyWith(
                      fontFamily: 'Georgia',
                      color: DashboardStyle.forest,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                notificationBell,
              ],
            ),
            const SizedBox(height: 12),
            Text(
              date.toUpperCase(),
              style: text.labelMedium?.copyWith(
                color: DashboardStyle.secondary,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              name.isEmpty
                  ? 'Welcome back \u{1F44B}'
                  : 'Welcome back, $name \u{1F44B}',
              style: text.headlineMedium?.copyWith(
                fontFamily: 'Georgia',
                color: DashboardStyle.forest,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Your inventory at a glance.',
              style: text.bodyMedium?.copyWith(color: DashboardStyle.secondary),
            ),
          ],
        ),
      ],
    );
  }
}
