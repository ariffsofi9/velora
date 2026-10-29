import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

class AppearancePage extends StatefulWidget {
  final bool initialDarkModePreference;
  final ValueChanged<bool> onPreferenceChanged;

  const AppearancePage({
    super.key,
    required this.initialDarkModePreference,
    required this.onPreferenceChanged,
  });

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  late bool _darkPreview;

  @override
  void initState() {
    super.initState();
    _darkPreview = widget.initialDarkModePreference;
  }

  void _selectPreview(bool dark) {
    setState(() => _darkPreview = dark);
    widget.onPreferenceChanged(dark);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: const Text(
        'Appearance',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              const _SectionTitle('Theme Preview'),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 360;
                  final cards = [
                    _ThemeChoice(
                      key: const ValueKey('appearance-light'),
                      label: 'Light',
                      icon: Icons.light_mode_outlined,
                      selected: !_darkPreview,
                      onTap: () => _selectPreview(false),
                    ),
                    _ThemeChoice(
                      key: const ValueKey('appearance-dark'),
                      label: 'Dark',
                      icon: Icons.dark_mode_outlined,
                      selected: _darkPreview,
                      onTap: () => _selectPreview(true),
                    ),
                    const _ThemeChoice(
                      label: 'System',
                      icon: Icons.desktop_windows_outlined,
                      selected: false,
                      onTap: null,
                    ),
                  ];
                  if (narrow) {
                    return Column(
                      children: cards
                          .map(
                            (card) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: card,
                            ),
                          )
                          .toList(),
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: cards
                        .map(
                          (card) => Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: card,
                            ),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
              const SizedBox(height: 12),
              _PreviewNotice(darkPreview: _darkPreview),
              const SizedBox(height: 24),
              const _SectionTitle('Brand Colors'),
              const SizedBox(height: 10),
              const _ColorPreview(),
              const SizedBox(height: 24),
              const _SectionTitle('Font Size'),
              const SizedBox(height: 10),
              const _UnsupportedOptions(
                labels: ['Small', 'Medium', 'Large'],
                selected: 'Medium',
              ),
              const SizedBox(height: 24),
              const _SectionTitle('Accessibility'),
              const SizedBox(height: 10),
              const _DisabledSetting(
                icon: Icons.motion_photos_off_outlined,
                title: 'Reduced Motion',
                subtitle: 'Not supported in the current app theme',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: AppColors.textPrimary,
      fontSize: 17,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _ThemeChoice extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  const _ThemeChoice({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.nude : AppColors.surface,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 92),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: onTap == null
                  ? AppColors.textSecondary
                  : AppColors.primary,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: onTap == null
                    ? AppColors.textSecondary
                    : AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (onTap == null)
              const Text(
                'Unavailable',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _PreviewNotice extends StatelessWidget {
  final bool darkPreview;

  const _PreviewNotice({required this.darkPreview});

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
            '${darkPreview ? 'Dark' : 'Light'} preview preference is saved locally. Velora remains in Light mode until theme switching is implemented.',
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

class _ColorPreview extends StatelessWidget {
  const _ColorPreview();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: const Wrap(
      spacing: 20,
      runSpacing: 12,
      children: [
        _ColorSwatch(label: 'Primary', color: AppColors.primary),
        _ColorSwatch(label: 'Secondary', color: AppColors.nude),
      ],
    ),
  );
}

class _ColorSwatch extends StatelessWidget {
  final String label;
  final Color color;

  const _ColorSwatch({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 104,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _UnsupportedOptions extends StatelessWidget {
  final List<String> labels;
  final String selected;

  const _UnsupportedOptions({required this.labels, required this.selected});

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: labels.map((label) {
      final active = label == selected;
      return Container(
        constraints: const BoxConstraints(minWidth: 84, minHeight: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? AppColors.nude : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }).toList(),
  );
}

class _DisabledSetting extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _DisabledSetting({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      children: [
        Icon(icon, color: AppColors.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const Switch(value: false, onChanged: null),
      ],
    ),
  );
}
