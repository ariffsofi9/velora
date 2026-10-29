import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import 'business_setup_draft.dart';
import 'business_setup_widgets.dart';

class BusinessInformationStep extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController name;
  final TextEditingController address;
  final BusinessSetupDraft draft;
  final ValueChanged<String> onTypeChanged;
  const BusinessInformationStep({
    super.key,
    required this.formKey,
    required this.name,
    required this.address,
    required this.draft,
    required this.onTypeChanged,
  });

  @override
  Widget build(BuildContext context) => Form(
    key: formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SetupHeading(
          title: 'Set Up Your Business',
          subtitle: 'Tell us about your F&B business',
        ),
        const SizedBox(height: 28),
        const SetupLabel('Business Name'),
        TextFormField(
          key: const ValueKey('business-name'),
          controller: name,
          style: const TextStyle(fontWeight: FontWeight.w400),
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Tasty Bites'),
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Please enter your business name.'
              : null,
        ),
        const SizedBox(height: 24),
        const SetupLabel('Business Type'),
        FormField<String>(
          initialValue: draft.businessType,
          validator: (value) => BusinessSetupDraft.businessTypes.contains(value)
              ? null
              : 'Please select a business type.',
          builder: (field) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SetupChoices(
                group: 'type',
                options: BusinessSetupDraft.businessTypes,
                selected: draft.businessType,
                columns: 3,
                onSelected: (value) {
                  field.didChange(value);
                  onTypeChanged(value);
                },
              ),
              if (field.hasError)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      field.errorText!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.danger),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const SetupLabel('Business Address (Optional)'),
        TextFormField(
          key: const ValueKey('business-address'),
          controller: address,
          style: const TextStyle(fontWeight: FontWeight.w400),
          decoration: const InputDecoration(
            hintText: 'Enter address',
            prefixIcon: Icon(Icons.location_on_outlined),
          ),
        ),
      ],
    ),
  );
}
