import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/screens/inventory/utils_inventory/inventory_sort_helper.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_list_controls.dart';

InventoryItem _item({
  required String id,
  required String name,
  required String category,
  required int quantity,
  required int expiryDays,
}) => InventoryItem(
  id: id,
  name: name,
  category: category,
  quantity: quantity,
  expiryDate: DateTime.now().add(Duration(days: expiryDays)),
  imageUrl: '',
  createdAt: DateTime.now(),
);

void main() {
  final items = [
    _item(
      id: 'milk',
      name: 'Fresh Milk',
      category: 'Dairy',
      quantity: 8,
      expiryDays: 2,
    ),
    _item(
      id: 'cheese',
      name: 'Soft Cheese',
      category: 'Dairy',
      quantity: 2,
      expiryDays: 8,
    ),
    _item(
      id: 'apple',
      name: 'Green Apple',
      category: 'Fruit',
      quantity: 4,
      expiryDays: 5,
    ),
  ];

  test('search is trimmed case-insensitive partial-name matching', () {
    expect(
      InventorySortHelper.searchItems(items, '  MIL  ').map((item) => item.id),
      ['milk'],
    );
    expect(InventorySortHelper.searchItems(items, 'dairy'), isEmpty);
  });

  test('categories are data-derived, unique and alphabetized', () {
    expect(InventorySortHelper.categories(items), [
      'All Categories',
      'Dairy',
      'Fruit',
    ]);
  });

  test(
    'combined search category status and quantity sort are deterministic',
    () {
      final result = InventorySortHelper.apply(
        items: items,
        query: 'e',
        category: 'Dairy',
        statusFilter: 'Low Stock',
        sort: InventorySortOption.quantity,
      );

      expect(result.map((item) => item.id), ['cheese']);
    },
  );

  test('all supported sort orders return expected order', () {
    expect(
      InventorySortHelper.sortItems(
        items,
        InventorySortOption.name,
      ).map((item) => item.id),
      ['milk', 'apple', 'cheese'],
    );
    expect(
      InventorySortHelper.sortItems(
        items,
        InventorySortOption.quantity,
      ).map((item) => item.id),
      ['cheese', 'apple', 'milk'],
    );
    expect(
      InventorySortHelper.sortItems(
        items,
        InventorySortOption.expiry,
      ).map((item) => item.id),
      ['milk', 'apple', 'cheese'],
    );
  });

  testWidgets(
    'category chips and sort selection retain the shared filter contract',
    (tester) async {
      var category = InventorySortHelper.allCategories;
      var sort = InventorySortOption.expiry;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                final filtered = InventorySortHelper.apply(
                  items: items,
                  query: '',
                  category: category,
                  statusFilter: 'All Items',
                  sort: sort,
                );
                return Column(
                  children: [
                    InventoryListControls(
                      categories: InventorySortHelper.categories(items),
                      selectedCategory: category,
                      selectedSort: sort,
                      onCategoryChanged: (value) =>
                          setState(() => category = value),
                      onSortChanged: (value) => setState(() => sort = value),
                      showCategoryChips: true,
                    ),
                    Text(filtered.map((item) => item.id).join(',')),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Dairy'));
      await tester.pumpAndSettle();
      expect(find.text('milk,cheese'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Dairy'))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('inventory-sort-order')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(InventorySortOption.quantity.label).last);
      await tester.pumpAndSettle();
      expect(find.text('cheese,milk'), findsOneWidget);
    },
  );
}
