import '../models/inventory_item.dart';

enum StockAttention {
  lowStock('Low Stock'),
  outOfStock('Out of Stock');

  const StockAttention(this.label);
  final String label;
}

/// Shared fallback policy until a trusted item-specific threshold exists.
abstract final class LowStockPolicy {
  static const int fallbackThreshold = 5;

  static StockAttention? attention(InventoryItem item) {
    if (item.isArchived) return null;
    return switch (item.quantity) {
      0 => StockAttention.outOfStock,
      > 0 && <= fallbackThreshold => StockAttention.lowStock,
      _ => null,
    };
  }

  /// The existing low-stock filter includes all items needing replenishment.
  static bool isLowStock(InventoryItem item) => attention(item) != null;
}
