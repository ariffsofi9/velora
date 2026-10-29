import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';

class SetupProgress extends StatelessWidget {
  final int step;
  const SetupProgress({super.key, required this.step});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step ${step + 1} of 3',
    child: ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) Container(width: 32, height: 1, color: AppColors.border),
            CircleAvatar(
              radius:
                  14 + (MediaQuery.textScalerOf(context).scale(12) - 12) / 3,
              backgroundColor: i <= step
                  ? AppColors.primary
                  : AppColors.nude.withValues(alpha: .35),
              child: i < step
                  ? const Icon(Icons.check, size: 15, color: Colors.white)
                  : Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: i <= step ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
            ),
          ],
        ],
      ),
    ),
  );
}

class SetupHeading extends StatelessWidget {
  final String title;
  final String subtitle;
  const SetupHeading({super.key, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary,
        ),
      ),
    ],
  );
}

class SetupLabel extends StatelessWidget {
  final String text;
  const SetupLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

/// Text-only, equal-width choices. Heights grow naturally with larger text.
class SetupChoices extends StatelessWidget {
  final String group;
  final List<String> options;
  final String? selected;
  final int columns;
  final ValueChanged<String>? onSelected;
  final Map<String, String> labels;
  const SetupChoices({
    super.key,
    required this.group,
    required this.options,
    required this.selected,
    required this.columns,
    required this.onSelected,
    this.labels = const {},
  });

  Widget _choice(BuildContext context, String value) {
    final active = selected == value;
    final enabled = onSelected != null;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        enabled: enabled,
        child: Material(
          color: active && enabled
              ? AppColors.primary
              : AppColors.nude.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: InkWell(
            key: ValueKey('$group-$value'),
            borderRadius: BorderRadius.circular(AppRadius.control),
            onTap: enabled ? () => onSelected!(value) : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 12,
                ),
                child: Center(
                  child: Text(
                    labels[value] ?? value,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: !enabled
                          ? AppColors.textSecondary
                          : active
                          ? Colors.white
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var start = 0; start < options.length; start += columns) ...[
        if (start > 0) const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (
                var i = start;
                i < start + columns && i < options.length;
                i++
              ) ...[
                if (i > start) const SizedBox(width: 8),
                _choice(context, options[i]),
              ],
            ],
          ),
        ),
      ],
    ],
  );
}

class SetupNotice extends StatelessWidget {
  final String text;
  const SetupNotice(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.nude.withValues(alpha: .3),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w400),
          ),
        ),
      ],
    ),
  );
}
