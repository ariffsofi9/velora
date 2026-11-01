import 'package:flutter_test/flutter_test.dart';
import 'package:velora/logic/low_stock_policy.dart';
import 'package:velora/models/inventory_item.dart';

InventoryItem _item(int quantity) => InventoryItem(
  id: 'item-$quantity',
  name: 'Item',
  category: 'General',
  quantity: quantity,
  expiryDate: DateTime(2030),
  imageUrl: '',
  createdAt: DateTime(2026),
);

void main() {
  test('fallback low-stock boundary is shared at quantity 5', () {
    expect(LowStockPolicy.fallbackThreshold, 5);
    expect(LowStockPolicy.isLowStock(_item(4)), isTrue);
    expect(LowStockPolicy.isLowStock(_item(5)), isTrue);
    expect(LowStockPolicy.isLowStock(_item(6)), isFalse);
  });

  test('empty inventory produces no low-stock items', () {
    final items = <InventoryItem>[];

    expect(items.where(LowStockPolicy.isLowStock), isEmpty);
  });
}
