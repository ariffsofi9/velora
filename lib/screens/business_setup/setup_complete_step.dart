import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import 'business_setup_draft.dart';
import 'business_setup_widgets.dart';

class SetupCompleteStep extends StatelessWidget {
  final BusinessSetupDraft draft;
  final VoidCallback onEditBusiness;
  final VoidCallback onEditPreferences;
  const SetupCompleteStep({
    super.key,
    required this.draft,
    required this.onEditBusiness,
    required this.onEditPreferences,
  });

  Widget _row(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            key: ValueKey('summary-$label'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w400),
          ),
        ),
      ],
    ),
  );

  Widget _feature(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.nude.withValues(alpha: .4),
          child: Icon(icon, size: 20, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
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
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Center(
        child: CircleAvatar(
          radius: 30,
          backgroundColor: AppColors.nude,
          child: Icon(Icons.check_rounded, size: 34, color: AppColors.primary),
        ),
      ),
      const SizedBox(height: 20),
      Text(
        'Your setup preview is ready',
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 10),
      Text(
        'Review your business details and inventory preferences.',
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
      ),
      const SizedBox(height: 24),
      const SetupNotice(
        'Preview only — not saved. Secure workspace creation is not available yet, so setup cannot be completed.',
      ),
      const SizedBox(height: 24),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  Text(
                    'Business Setup Summary',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onEditBusiness,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit Setup'),
                  ),
                ],
              ),
              _row(context, 'Business Name', draft.businessName),
              _row(context, 'Business Type', draft.businessType!),
              if (draft.address.isNotEmpty)
                _row(context, 'Business Address', draft.address),
              const Divider(),
              _row(context, 'Inventory Unit', draft.unit),
              _row(
                context,
                'Low Stock Alerts',
                draft.lowStockAlerts ? 'Enabled' : 'Disabled',
              ),
              _row(
                context,
                'Expiry Reminders',
                draft.expiryReminders ? 'Enabled' : 'Disabled',
              ),
              _row(
                context,
                'Reminder Timing',
                draft.expiryReminders
                    ? '${draft.reminderDays} ${draft.reminderDays == 1 ? 'day' : 'days'} before'
                    : 'Disabled',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onEditPreferences,
                  child: const Text('Edit inventory preferences'),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      const SetupLabel('What You Can Do With Velora'),
      _feature(
        context,
        Icons.inventory_2_outlined,
        'Track Ingredients',
        'Keep your ingredients organised.',
      ),
      _feature(
        context,
        Icons.eco_outlined,
        'Reduce Food Waste',
        'Track expiry dates and stock levels.',
      ),
      _feature(
        context,
        Icons.restaurant_menu_outlined,
        'AI Recipe Suggestions',
        'Turn your inventory into recipe ideas.',
      ),
    ],
  );
}
