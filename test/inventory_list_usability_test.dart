import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/screens/inventory/utils_inventory/inventory_sort_helper.dart';

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
}
