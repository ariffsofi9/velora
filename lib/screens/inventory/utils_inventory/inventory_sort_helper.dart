import '../../../models/inventory_item.dart';
import '../../../logic/low_stock_policy.dart';
import '../../../logic/inventory_expiry_policy.dart';
import 'expiry_helper.dart';

enum InventorySortOption {
  name('Name A–Z'),
  quantity('Quantity Low–High'),
  expiry('Expiry Soonest');

  final String label;
  const InventorySortOption(this.label);
}

class InventorySortHelper {
  static const allCategories = 'All Categories';

  static List<String> categories(List<InventoryItem> items) {
    final values = items.map((item) => item.category).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [allCategories, ...values];
  }

  static List<InventoryItem> sortItems(
    List<InventoryItem> items,
    InventorySortOption option,
  ) {
    final sorted = [...items];

    int byName(InventoryItem a, InventoryItem b) {
      final result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return result != 0 ? result : a.id.compareTo(b.id);
    }

    sorted.sort(switch (option) {
      InventorySortOption.name => byName,
      InventorySortOption.quantity => (a, b) {
        final result = a.quantity.compareTo(b.quantity);
        return result != 0 ? result : byName(a, b);
      },
      InventorySortOption.expiry => (a, b) {
        final result = ExpiryHelper.daysLeft(
          a.expiryDate,
        ).compareTo(ExpiryHelper.daysLeft(b.expiryDate));
        return result != 0 ? result : byName(a, b);
      },
    });

    return sorted;
  }

  static List<InventoryItem> sortByExpiry(List<InventoryItem> items) =>
      sortItems(items, InventorySortOption.expiry);

  static List<InventoryItem> searchItems(
    List<InventoryItem> items,
    String query,
  ) {
    final cleanQuery = query.toLowerCase().trim();

    if (cleanQuery.isEmpty) return items;

    return items
        .where((item) => item.name.toLowerCase().contains(cleanQuery))
        .toList();
  }

  static List<InventoryItem> filterByCategory(
    List<InventoryItem> items,
    String category,
  ) {
    if (category == allCategories) return items;
    final normalized = category.toLowerCase();
    return items
        .where((item) => item.category.toLowerCase() == normalized)
        .toList();
  }

  static List<InventoryItem> filterItems(
    List<InventoryItem> items,
    String filter,
  ) {
    if (filter == 'Low Stock') {
      return items.where(LowStockPolicy.isLowStock).toList();
    }

    if (filter == 'Near Expiry') {
      return items
          .where((item) => InventoryExpiryPolicy.isNearExpiry(item.expiryDate))
          .toList();
    }

    return items;
  }

  static List<InventoryItem> apply({
    required List<InventoryItem> items,
    required String query,
    required String category,
    required String statusFilter,
    required InventorySortOption sort,
  }) {
    var result = searchItems(items, query);
    result = filterByCategory(result, category);
    result = filterItems(result, statusFilter);
    return sortItems(result, sort);
  }
}
