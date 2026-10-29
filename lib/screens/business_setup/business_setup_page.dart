import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import 'business_information_step.dart';
import 'business_setup_draft.dart';
import 'business_setup_widgets.dart';
import 'inventory_preferences_step.dart';
import 'setup_complete_step.dart';

/// Standalone local preview. No provisioning, persistence or workspace activation.
class BusinessSetupPage extends StatefulWidget {
  const BusinessSetupPage({super.key});
  @override
  State<BusinessSetupPage> createState() => _BusinessSetupPageState();
}

class _BusinessSetupPageState extends State<BusinessSetupPage> {
  final _draft = BusinessSetupDraft();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  int _step = 0;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _goToStep(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _next() {
    if (_step == 0) {
      if (!_form.currentState!.validate()) return;
      _draft.businessName = _name.text.trim();
      _draft.address = _address.text.trim();
    }
    _goToStep(_step + 1);
  }

  Widget _stepBody() => switch (_step) {
    0 => BusinessInformationStep(
      formKey: _form,
      name: _name,
      address: _address,
      draft: _draft,
      onTypeChanged: (value) => setState(() => _draft.businessType = value),
    ),
    1 => InventoryPreferencesStep(
      draft: _draft,
      onUnitChanged: (value) => setState(() => _draft.unit = value),
      onAlertsChanged: (value) => setState(() => _draft.lowStockAlerts = value),
      onRemindersChanged: (value) =>
          setState(() => _draft.expiryReminders = value),
      onTimingChanged: (value) => setState(() => _draft.reminderDays = value),
    ),
    _ => SetupCompleteStep(
      draft: _draft,
      onEditBusiness: () => _goToStep(0),
      onEditPreferences: () => _goToStep(1),
    ),
  };

  Widget _footer() => switch (_step) {
    0 => FilledButton(
      key: const ValueKey('setup-next'),
      onPressed: _next,
      child: const Text('Next'),
    ),
    1 => Row(
      children: [
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('setup-back'),
            onPressed: () => _goToStep(0),
            child: const Text('Back'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            key: const ValueKey('setup-next'),
            onPressed: _next,
            child: const Text('Next'),
          ),
        ),
      ],
    ),
    _ => const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: ValueKey('setup-dashboard'),
          onPressed: null,
          child: Text('Go to Dashboard'),
        ),
        SizedBox(height: 10),
        Text(
          'Available after secure workspace setup is connected.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w400,
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    ),
  };

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _step == 0,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _step > 0) _goToStep(_step - 1);
    },
    child: Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: _step == 2
          ? SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: _footer(),
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, size) => SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.all(size.maxWidth < 360 ? 20 : 24),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 480,
                  minHeight: (size.maxHeight - (size.maxWidth < 360 ? 40 : 48))
                      .clamp(0, double.infinity),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: _step > 0 || Navigator.canPop(context)
                                  ? IconButton(
                                      tooltip: 'Back',
                                      icon: const Icon(Icons.arrow_back),
                                      onPressed: () {
                                        if (_step > 0) {
                                          _goToStep(_step - 1);
                                        } else {
                                          Navigator.pop(context);
                                        }
                                      },
                                    )
                                  : null,
                            ),
                            Expanded(child: SetupProgress(step: _step)),
                            const SizedBox(width: 48),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _stepBody(),
                      ],
                    ),
                    if (_step < 2)
                      Padding(
                        padding: const EdgeInsets.only(top: 28),
                        child: SizedBox(
                          width: double.infinity,
                          child: _footer(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
