import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import 'business_setup_draft.dart';
import 'business_setup_widgets.dart';

class InventoryPreferencesStep extends StatelessWidget {
  final BusinessSetupDraft draft;
  final ValueChanged<String> onUnitChanged;
  final ValueChanged<bool> onAlertsChanged;
  final ValueChanged<bool> onRemindersChanged;
  final ValueChanged<int> onTimingChanged;
  const InventoryPreferencesStep({
    super.key,
    required this.draft,
    required this.onUnitChanged,
    required this.onAlertsChanged,
    required this.onRemindersChanged,
    required this.onTimingChanged,
  });

  Widget _toggle(
    BuildContext context,
    String title,
    String subtitle,
    String key,
    bool value,
    ValueChanged<bool> change,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 5),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Semantics(
          label: title,
          child: Switch(key: ValueKey(key), value: value, onChanged: change),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SetupHeading(
        title: 'Set Up Your Inventory',
        subtitle: 'Customize how Velora manages your ingredients.',
      ),
      const SizedBox(height: 28),
      const SetupLabel('Default Inventory Unit'),
      Text(
        'Used as the default when adding ingredients. You can choose a different unit for each ingredient.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w400,
        ),
      ),
      const SizedBox(height: 12),
      SetupChoices(
        group: 'unit',
        options: BusinessSetupDraft.units,
        selected: draft.unit,
        columns: 5,
        onSelected: onUnitChanged,
      ),
      const SizedBox(height: 14),
      _toggle(
        context,
        'Low Stock Alerts',
        'Get notified when ingredients are running low.',
        'low-stock-alerts',
        draft.lowStockAlerts,
        onAlertsChanged,
      ),
      _toggle(
        context,
        'Expiry Date Reminders',
        'Get reminded before ingredients expire.',
        'expiry-reminders',
        draft.expiryReminders,
        onRemindersChanged,
      ),
      const SizedBox(height: 12),
      const SetupLabel('Reminder Timing'),
      Text(
        'Choose when you want to be notified.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w400,
        ),
      ),
      const SizedBox(height: 12),
      SetupChoices(
        group: 'timing',
        options: const ['1', '3', '7'],
        selected: '${draft.reminderDays}',
        columns: 3,
        labels: const {
          '1': '1 day\nbefore',
          '3': '3 days\nbefore',
          '7': '7 days\nbefore',
        },
        onSelected: draft.expiryReminders
            ? (value) => onTimingChanged(int.parse(value))
            : null,
      ),
    ],
  );
}
