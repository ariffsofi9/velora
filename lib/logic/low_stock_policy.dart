import '../models/inventory_item.dart';

/// Shared fallback policy until a trusted item-specific threshold exists.
abstract final class LowStockPolicy {
  static const int fallbackThreshold = 5;

  static bool isLowStock(InventoryItem item) =>
      item.quantity <= fallbackThreshold;
}
