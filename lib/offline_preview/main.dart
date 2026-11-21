import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/app_tokens.dart';
import '../logic/inventory_expiry_policy.dart';
import '../logic/low_stock_policy.dart';
import '../models/inventory_item.dart';
import '../screens/home/widgets_home/bottom_bar.dart';
import '../screens/inventory/utils_inventory/inventory_sort_helper.dart';
import '../screens/inventory/widgets_inventory/inventory_card.dart';
import '../screens/inventory/widgets_inventory/inventory_filter_chips.dart';
import '../screens/inventory/widgets_inventory/inventory_list_controls.dart';
import '../screens/inventory/widgets_inventory/inventory_search_bar.dart';
import '../screens/inventory/widgets_inventory/item_detail_info_card.dart';
import '../widgets/dashboard/dashboard_content.dart';
import '../widgets/responsive_navigation.dart';
import 'fixtures.dart';
import 'walkthrough_pages.dart';

export 'fixtures.dart' show OfflinePreviewFixtures, PreviewScenario;

void main() =>
    runApp(OfflinePreviewApp(fixtures: OfflinePreviewFixtures(DateTime.now())));

class OfflinePreviewApp extends StatelessWidget {
  const OfflinePreviewApp({super.key, required this.fixtures});
  final OfflinePreviewFixtures fixtures;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Velora Offline Preview',
    theme: AppTheme.light,
    home: PreviewEntry(
      onEnter: (role) => _PreviewWorkspace(fixtures: fixtures, role: role),
    ),
  );
}

class _PreviewWorkspace extends StatefulWidget {
  const _PreviewWorkspace({required this.fixtures, required this.role});

  final OfflinePreviewFixtures fixtures;
  final PreviewRole role;

  @override
  State<_PreviewWorkspace> createState() => _PreviewWorkspaceState();
}

class _PreviewWorkspaceState extends State<_PreviewWorkspace> {
  PreviewScenario _scenario = PreviewScenario.cafe;
  int _tab = 0;
  final _search = TextEditingController();
  String _category = InventorySortHelper.allCategories;
  String _status = InventoryFilterChips.filters.first;
  InventorySortOption _sort = InventorySortOption.expiry;

  bool get _isOwner => widget.role == PreviewRole.owner;
  String get _role => _isOwner ? 'Owner' : 'Staff';
  String get _name => _isOwner ? 'Aisyah Rahman' : 'Amir Tan';
  DateTime get _now => widget.fixtures.now;
  List<InventoryItem> get _items => widget.fixtures.inventory(_scenario);

  bool _nearExpiry(InventoryItem item) =>
      InventoryExpiryPolicy.isNearExpiry(item.expiryDate, now: _now);
  bool _expired(InventoryItem item) =>
      InventoryExpiryPolicy.isExpired(item.expiryDate, now: _now);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = usesSideNavigation(context);
    final bar = VeloraBottomBar(
      currentIndex: _tab,
      side: side,
      onTap: _selectDestination,
    );
    return Scaffold(
      appBar: previewBar(switch (_tab) {
        1 => 'Inventory',
        3 => 'AI Recipe Suggestions',
        4 => 'Profile',
        _ => 'Dashboard',
      }),
      body: SafeArea(
        child: Row(
          children: [
            if (side) ...[bar, const VerticalDivider(width: 1)],
            Expanded(
              child: switch (_tab) {
                1 => _inventory(),
                3 => _recipes(),
                4 => _profile(),
                _ => _dashboard(),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: side ? null : bar,
    );
  }

  void _selectDestination(int index) {
    if (index == 2) {
      openPreview(context, const PreviewInventoryForm());
      return;
    }
    setState(() => _tab = index);
  }

  Widget _dashboard() {
    final items = _items;
    return DashboardContent(
      firstName: _name,
      totalItems: items.length,
      lowStock: items.where(LowStockPolicy.isLowStock).length,
      nearExpiry: items.where(_nearExpiry).length,
      expired: items.where(_expired).length,
      notificationBell: IconButton(
        tooltip: 'Open Alerts',
        onPressed: _alerts,
        icon: const Icon(Icons.notifications_outlined),
      ),
      recentActivity: _recentActivity(items),
      onAddTap: () => _selectDestination(2),
      onInventoryTap: () => _selectDestination(1),
      onSuggestionTap: () => _selectDestination(3),
      onAlertTap: _alerts,
      onStockInTap: () => _chooseStockItem(true),
      onStockOutTap: () => _chooseStockItem(false),
      showInventoryHealth: false,
    );
  }

  Widget _inventory() {
    final items = _items;
    final categories = InventorySortHelper.categories(items);
    final categoryMatches = InventorySortHelper.filterByCategory(
      InventorySortHelper.searchItems(items, _search.text),
      _category,
    );
    final filtered = InventorySortHelper.sortItems(switch (_status) {
      'Near Expiry' => categoryMatches.where(_nearExpiry).toList(),
      _ => InventorySortHelper.filterItems(categoryMatches, _status),
    }, _sort);
    return _content([
      Row(
        children: [
          Expanded(
            child: Text(
              'Sample inventory',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Preview Add Item',
            onPressed: () => _selectDestination(2),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      DropdownButton<PreviewScenario>(
        value: _scenario,
        isExpanded: true,
        onChanged: (scenario) {
          if (scenario == null) return;
          setState(() {
            _scenario = scenario;
            _category = InventorySortHelper.allCategories;
          });
        },
        items: [
          for (final scenario in PreviewScenario.values)
            DropdownMenuItem(value: scenario, child: Text(scenario.label)),
        ],
      ),
      if (_scenario == PreviewScenario.loading)
        const _Notice(
          Icons.hourglass_top,
          'Loading inventory',
          'Choose a sample business to return to the list.',
        )
      else if (_scenario == PreviewScenario.error)
        const _Notice(
          Icons.error_outline,
          'Inventory unavailable',
          'This sample shows a read error. Choose another sample to continue.',
        )
      else if (items.isEmpty)
        const _Notice(
          Icons.inventory_2_outlined,
          'No inventory items',
          'Choose a sample business to see its inventory.',
        )
      else ...[
        InventorySearchBar(
          controller: _search,
          onChanged: (_) => setState(() {}),
        ),
        InventoryListControls(
          showCategoryChips: true,
          categories: categories,
          selectedCategory: _category,
          selectedSort: _sort,
          onCategoryChanged: (category) => setState(() => _category = category),
          onSortChanged: (sort) => setState(() => _sort = sort),
        ),
        InventoryFilterChips(
          selectedFilter: _status,
          onSelected: (status) => setState(() => _status = status),
        ),
        if (filtered.isEmpty)
          const _Notice(
            Icons.search_off,
            'No matching items',
            'Try a different search or filter.',
          ),
        for (final item in filtered)
          InventoryCard(item: item, now: _now, onTap: () => _details(item)),
      ],
    ]);
  }

  void _details(InventoryItem item) => openPreview(
    context,
    PreviewPage(
      title: 'Item Details',
      children: [
        Text(item.name, style: Theme.of(context).textTheme.headlineSmall),
        ItemDetailInfoCard(
          rows: [
            ItemDetailInfoRow(label: 'Category', value: item.category),
            ItemDetailInfoRow(
              label: 'In stock',
              value: '${item.quantity} ${item.unit}',
            ),
            ItemDetailInfoRow(
              label: 'Expiry date',
              value: MaterialLocalizations.of(
                context,
              ).formatMediumDate(item.expiryDate),
            ),
          ],
        ),
        FilledButton(
          onPressed: () => _stockForm(item, true),
          child: const Text('Stock In'),
        ),
        OutlinedButton(
          onPressed: () => _stockForm(item, false),
          child: const Text('Stock Out'),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.history),
          onPressed: () => _stockHistory(item),
          label: const Text('Stock History'),
        ),
      ],
    ),
  );

  void _chooseStockItem(bool stockIn) => openPreview(
    context,
    PreviewPage(
      title: stockIn ? 'Select item for Stock In' : 'Select item for Stock Out',
      children: [
        if (_items.isEmpty)
          const _Notice(
            Icons.inventory_2_outlined,
            'No sample items',
            'Select an inventory sample to preview a stock form.',
          ),
        for (final item in _items)
          InventoryCard(
            item: item,
            now: _now,
            onTap: () => _stockForm(item, stockIn),
          ),
      ],
    ),
  );

  void _stockForm(InventoryItem item, bool stockIn) =>
      openPreview(context, PreviewInventoryForm(item: item, stockIn: stockIn));

  void _stockHistory(InventoryItem item) => openPreview(
    context,
    PreviewPage(
      title: 'Stock History',
      children: [
        Text(item.name, style: Theme.of(context).textTheme.titleLarge),
        for (final movement in widget.fixtures.history(_scenario, item))
          _movementCard(item, movement),
      ],
    ),
  );

  Widget _movementCard(
    InventoryItem item,
    PreviewMovement movement, {
    bool showItem = false,
  }) {
    final (label, delta, balance, date) = movement;
    final dateLabel = MaterialLocalizations.of(context).formatMediumDate(date);
    return Card(
      child: ListTile(
        leading: Icon(
          delta < 0 ? Icons.remove_circle_outline : Icons.add_circle_outline,
        ),
        title: Text(showItem ? item.name : label),
        subtitle: Text(
          showItem
              ? '$label · $dateLabel'
              : '$dateLabel\n${delta > 0 ? '+' : ''}$delta ${item.unit} · $balance remaining',
        ),
      ),
    );
  }

  List<Widget> _activity(List<InventoryItem> items) {
    final rows = [
      for (final item in items)
        for (final movement in widget.fixtures.history(_scenario, item))
          (item, movement),
    ]..sort((a, b) => b.$2.$4.compareTo(a.$2.$4));
    return [
      if (rows.isEmpty)
        const _Notice(
          Icons.history,
          'No sample activity',
          'This sample has no stock movements.',
        ),
      for (final (item, movement) in rows)
        _movementCard(item, movement, showItem: true),
    ];
  }

  Widget _recentActivity(List<InventoryItem> items) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Recent Activity',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton(
            onPressed: () => openPreview(
              context,
              PreviewPage(title: 'Activity', children: _activity(items)),
            ),
            child: const Text('See all activity'),
          ),
        ],
      ),
      ..._activity(items).take(3),
    ],
  );

  void _alerts() {
    final alertItems = _items
        .where(
          (item) =>
              _expired(item) ||
              _nearExpiry(item) ||
              LowStockPolicy.isLowStock(item),
        )
        .toList();
    openPreview(
      context,
      PreviewPage(
        title: 'Alerts',
        children: [
          if (alertItems.isEmpty)
            const _Notice(
              Icons.notifications_none,
              'No sample alerts',
              'This sample has no inventory alerts.',
            ),
          for (final item in alertItems)
            InventoryCard(item: item, now: _now, onTap: () => _details(item)),
        ],
      ),
    );
  }

  Widget _recipes() => _content([
    const PreviewUnavailable(
      action: 'Generate Suggestions',
      reason:
          'These are sample recipes. AI generation is unavailable in the offline preview.',
    ),
    OutlinedButton(
      onPressed: _savedRecipes,
      child: const Text('Saved Recipes'),
    ),
    for (final recipe in OfflinePreviewFixtures.recipes) _recipeCard(recipe),
  ]);

  Widget _recipeCard(PreviewRecipe recipe) => Card(
    child: ListTile(
      leading: Icon(recipe.icon, color: AppColors.primary),
      title: Text(recipe.title),
      subtitle: Text('${recipe.minutes} min · ${recipe.category}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openPreview(context, PreviewRecipeDetails(recipe: recipe)),
    ),
  );

  void _savedRecipes() => openPreview(
    context,
    PreviewPage(
      title: 'Saved Recipes',
      children: [
        const Text('Sample shared library'),
        _recipeCard(OfflinePreviewFixtures.recipes.first),
      ],
    ),
  );

  Widget _profile() => _content([
    Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
        title: Text(_name),
        subtitle: Text('Sample $_role'),
      ),
    ),
    Card(
      child: ListTile(
        leading: const Icon(Icons.people_outline),
        title: const Text('Team Management'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPreview(context, PreviewTeam(role: widget.role)),
      ),
    ),
    Card(
      child: ListTile(
        leading: const Icon(Icons.settings_outlined),
        title: const Text('Settings'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPreview(
          context,
          PreviewPage(
            title: 'Settings',
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Appearance'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openPreview(context, const PreviewAppearance()),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Leave sample workspace'),
    ),
  ]);

  Widget _content(List<Widget> children) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        key: PageStorageKey(_tab),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          for (final child in children) ...[
            child,
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.icon, this.title, this.message);

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(message),
    ),
  );
}
