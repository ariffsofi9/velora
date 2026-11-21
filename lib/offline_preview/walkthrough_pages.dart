import 'package:flutter/material.dart';

import '../core/theme/app_tokens.dart';
import '../models/inventory_item.dart';
import '../screens/inventory/widgets_inventory/item_detail_info_card.dart';
import 'fixtures.dart';

const previewWordmark = 'assets/images/velora_reference_wordmark.png';

void openPreview(BuildContext context, Widget page) {
  Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));
}

AppBar previewBar(String title) => AppBar(
  toolbarHeight: 76,
  title: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('OFFLINE PREVIEW', style: TextStyle(fontSize: 11)),
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    ],
  ),
);

class PreviewPage extends StatelessWidget {
  const PreviewPage({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: previewBar(title),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            children: [
              for (final child in children) ...[
                child,
                const SizedBox(height: AppSpacing.lg),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class PreviewUnavailable extends StatelessWidget {
  const PreviewUnavailable({
    super.key,
    required this.action,
    required this.reason,
  });

  final String action;
  final String reason;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FilledButton(onPressed: null, child: Text(action)),
      const SizedBox(height: AppSpacing.sm),
      Text(reason, style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}

class PreviewEntry extends StatelessWidget {
  const PreviewEntry({super.key, required this.onEnter});

  final Widget Function(PreviewRole role) onEnter;

  @override
  Widget build(BuildContext context) => PreviewPage(
    title: 'Velora',
    children: [
      const SizedBox(height: 56),
      Center(
        child: Image.asset(
          previewWordmark,
          width: 235,
          semanticLabel: 'Velora leaf and wordmark',
        ),
      ),
      const Text(
        'AI Smart Inventory for F&B Businesses',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: () => openPreview(context, _Welcome(onEnter: onEnter)),
        child: const Text('Start walkthrough'),
      ),
    ],
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onEnter});

  final Widget Function(PreviewRole role) onEnter;

  @override
  Widget build(BuildContext context) => PreviewPage(
    title: 'Welcome to Velora',
    children: [
      Center(
        child: Image.asset(
          previewWordmark,
          width: 190,
          semanticLabel: 'Velora',
        ),
      ),
      FilledButton(
        onPressed: () => openPreview(context, _AccountPage(onEnter: onEnter)),
        child: const Text('Login'),
      ),
      OutlinedButton(
        onPressed: () => openPreview(
          context,
          _AccountPage(register: true, onEnter: onEnter),
        ),
        child: const Text('Register'),
      ),
      _SampleEntry(onEnter: onEnter),
    ],
  );
}

class _SampleEntry extends StatelessWidget {
  const _SampleEntry({required this.onEnter});

  final Widget Function(PreviewRole role) onEnter;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Explore a sample workspace with fixture data.'),
      const SizedBox(height: AppSpacing.sm),
      for (final role in PreviewRole.values)
        OutlinedButton(
          onPressed: () => openPreview(context, onEnter(role)),
          child: Text(
            'View as sample ${role == PreviewRole.owner ? 'Owner' : 'Staff'}',
          ),
        ),
    ],
  );
}

class _AccountPage extends StatelessWidget {
  const _AccountPage({this.register = false, required this.onEnter});

  final bool register;
  final Widget Function(PreviewRole role) onEnter;

  @override
  Widget build(BuildContext context) => PreviewPage(
    title: register ? 'Create an Account' : 'Welcome Back',
    children: [
      if (register) const _SampleField('Full Name', 'Sample Owner'),
      const _SampleField('Email', 'owner@example.invalid'),
      const _SampleField('Password', 'Unavailable in preview'),
      if (register)
        const _SampleField('Confirm Password', 'Unavailable in preview'),
      PreviewUnavailable(
        action: register ? 'Create Account' : 'Log In',
        reason:
            'Authentication is unavailable in the offline preview. Do not enter credentials.',
      ),
      if (register)
        OutlinedButton(
          onPressed: () =>
              openPreview(context, _BusinessSetup(onEnter: onEnter)),
          child: const Text('Preview business setup'),
        )
      else
        _SampleEntry(onEnter: onEnter),
    ],
  );
}

class _BusinessSetup extends StatefulWidget {
  const _BusinessSetup({required this.onEnter});

  final Widget Function(PreviewRole role) onEnter;

  @override
  State<_BusinessSetup> createState() => _BusinessSetupState();
}

class _BusinessSetupState extends State<_BusinessSetup> {
  int _step = 1;
  String _business = 'Café';
  String _unit = 'kg';
  bool _lowStock = true;
  bool _reminders = true;
  String _timing = '3 days before';

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _step == 1,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _step > 1) setState(() => _step--);
    },
    child: PreviewPage(
      title: 'Business Setup · Step $_step of 3',
      children: [
        if (_step == 1) ...[
          Text(
            'Set Up Your Business',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const _SampleField('Business Name', 'Velora Sample Kitchen'),
          _choices(
            'Business Type',
            ['Restaurant', 'Café', 'Bakery'],
            _business,
            (value) => setState(() => _business = value),
          ),
          const _SampleField('Business Address (optional)', 'Sample address'),
        ],
        if (_step == 2) ...[
          Text(
            'Set Up Your Inventory',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          _choices(
            'Inventory Tracking Unit',
            ['kg', 'g', 'L', 'ml', 'pcs'],
            _unit,
            (value) => setState(() => _unit = value),
          ),
          SwitchListTile(
            title: const Text('Low Stock Alerts'),
            value: _lowStock,
            onChanged: (value) => setState(() => _lowStock = value),
          ),
          SwitchListTile(
            title: const Text('Expiry Date Reminders'),
            value: _reminders,
            onChanged: (value) => setState(() => _reminders = value),
          ),
          if (_reminders)
            _choices(
              'Reminder Timing',
              ['1 day before', '3 days before', '7 days before'],
              _timing,
              (value) => setState(() => _timing = value),
            ),
        ],
        if (_step == 3) ...[
          Text(
            'Business Setup Summary',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          ItemDetailInfoCard(
            rows: [
              const ItemDetailInfoRow(
                label: 'Business Name',
                value: 'Velora Sample Kitchen',
              ),
              ItemDetailInfoRow(label: 'Business Type', value: _business),
              ItemDetailInfoRow(label: 'Inventory Unit', value: _unit),
              ItemDetailInfoRow(
                label: 'Low Stock Alerts',
                value: _lowStock ? 'Enabled' : 'Disabled',
              ),
              ItemDetailInfoRow(
                label: 'Expiry Reminders',
                value: _reminders ? _timing : 'Disabled',
              ),
            ],
          ),
          const PreviewUnavailable(
            action: 'Create Workspace',
            reason: 'No workspace is created in this preview.',
          ),
          _SampleEntry(onEnter: widget.onEnter),
        ],
        if (_step < 3)
          FilledButton(
            onPressed: () => setState(() => _step++),
            child: const Text('Next'),
          ),
        if (_step > 1)
          TextButton(
            onPressed: () => setState(() => _step--),
            child: const Text('Previous step'),
          ),
      ],
    ),
  );

  Widget _choices(
    String label,
    List<String> values,
    String selected,
    ValueChanged<String> onSelected,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: AppSpacing.sm),
      Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          for (final value in values)
            ChoiceChip(
              label: Text(value),
              selected: selected == value,
              labelStyle: TextStyle(
                color: selected == value
                    ? AppColors.surface
                    : AppColors.textPrimary,
              ),
              showCheckmark: false,
              onSelected: (_) => onSelected(value),
            ),
        ],
      ),
    ],
  );
}

class _SampleField extends StatelessWidget {
  const _SampleField(this.label, this.hint);

  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) => TextField(
    enabled: false,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      floatingLabelBehavior: FloatingLabelBehavior.always,
    ),
  );
}

class PreviewInventoryForm extends StatelessWidget {
  const PreviewInventoryForm({super.key, this.item, this.stockIn = true});

  final InventoryItem? item;
  final bool stockIn;

  @override
  Widget build(BuildContext context) {
    final stockItem = item;
    final title = stockItem == null
        ? 'Add Item'
        : stockIn
        ? 'Stock In'
        : 'Stock Out';
    return PreviewPage(
      title: title,
      children: [
        if (stockItem != null) ...[
          Text(stockItem.name, style: Theme.of(context).textTheme.titleLarge),
          Text('Current stock: ${stockItem.quantity} ${stockItem.unit}'),
        ] else ...[
          const _SampleField('Item Name', 'Sample ingredient'),
          const _SampleField('Category', 'Grains'),
        ],
        _SampleField(
          stockItem == null
              ? 'Quantity'
              : stockIn
              ? 'Quantity to add'
              : 'Quantity to remove',
          '1',
        ),
        _SampleField('Unit', stockItem?.unit ?? 'kg'),
        if (stockItem == null)
          const _SampleField('Expiry Date (optional)', 'Select date'),
        if (stockItem != null && !stockIn)
          const _SampleField('Reason', 'Used for cooking'),
        if (stockItem != null)
          const _SampleField('Notes (optional)', 'Sample note'),
        PreviewUnavailable(
          action: stockItem == null ? 'Save Item' : 'Confirm $title',
          reason: 'Inventory changes are unavailable in the offline preview.',
        ),
      ],
    );
  }
}

class PreviewRecipeDetails extends StatelessWidget {
  const PreviewRecipeDetails({super.key, required this.recipe});

  final PreviewRecipe recipe;

  @override
  Widget build(BuildContext context) => PreviewPage(
    title: 'Recipe Details',
    children: [
      Icon(recipe.icon, size: 72, color: AppColors.primary),
      Text(recipe.title, style: Theme.of(context).textTheme.headlineSmall),
      Text('${recipe.minutes} min · ${recipe.category}'),
      Text('Ingredients', style: Theme.of(context).textTheme.titleMedium),
      for (final ingredient in recipe.ingredients)
        Card(
          child: ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: Text(ingredient),
          ),
        ),
      Text('Preparation', style: Theme.of(context).textTheme.titleMedium),
      Text(recipe.preparation),
      const PreviewUnavailable(
        action: 'Save Recipe',
        reason: 'Recipe saving is unavailable in the offline preview.',
      ),
      const PreviewUnavailable(
        action: 'Cook This Recipe',
        reason: 'This walkthrough does not change stock.',
      ),
    ],
  );
}

class PreviewTeam extends StatelessWidget {
  const PreviewTeam({super.key, required this.role});

  final PreviewRole role;

  @override
  Widget build(BuildContext context) => PreviewPage(
    title: 'Team Management',
    children: [
      if (role == PreviewRole.owner)
        const PreviewUnavailable(
          action: 'Add Staff',
          reason: 'Invitations are unavailable in the offline preview.',
        ),
      for (final (name, title) in OfflinePreviewFixtures.team)
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
            title: Text(name),
            subtitle: Text(title),
          ),
        ),
    ],
  );
}

class PreviewAppearance extends StatelessWidget {
  const PreviewAppearance({super.key});

  @override
  Widget build(BuildContext context) => PreviewPage(
    title: 'Appearance',
    children: [
      Text('Theme', style: Theme.of(context).textTheme.titleMedium),
      const Wrap(
        spacing: AppSpacing.sm,
        children: [
          Chip(label: Text('Light')),
          ChoiceChip(label: Text('Dark'), selected: false),
          ChoiceChip(label: Text('System'), selected: false),
        ],
      ),
      Text('Primary Color', style: Theme.of(context).textTheme.titleMedium),
      const Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.primary,
            child: Icon(Icons.check, color: AppColors.surface),
          ),
          SizedBox(width: AppSpacing.sm),
          CircleAvatar(backgroundColor: AppColors.secondary),
          SizedBox(width: AppSpacing.sm),
          CircleAvatar(
            backgroundColor: AppColors.surface,
            child: Icon(Icons.circle_outlined),
          ),
        ],
      ),
      const Text(
        'The walkthrough uses the approved light palette and your system text size.',
      ),
    ],
  );
}
