import '../../../models/inventory_item.dart';
import '../../../logic/low_stock_policy.dart';
import '../../../logic/inventory_expiry_policy.dart';
import 'expiry_helper.dart';

class InventorySortHelper {
  static List<InventoryItem> sortByExpiry(List<InventoryItem> items) {
    final sorted = [...items];

    sorted.sort((a, b) {
      final aDays = ExpiryHelper.daysLeft(a.expiryDate);
      final bDays = ExpiryHelper.daysLeft(b.expiryDate);
      return aDays.compareTo(bDays);
    });

    return sorted;
  }

  static List<InventoryItem> searchItems(
    List<InventoryItem> items,
    String query,
  ) {
    final cleanQuery = query.toLowerCase().trim();

    if (cleanQuery.isEmpty) return items;

    return items.where((item) {
      return item.name.toLowerCase().startsWith(cleanQuery) ||
          item.category.toLowerCase().startsWith(cleanQuery);
    }).toList();
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
}
