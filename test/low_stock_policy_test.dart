import 'package:flutter_test/flutter_test.dart';
import 'package:velora/logic/low_stock_policy.dart';
import 'package:velora/models/inventory_item.dart';

InventoryItem _item(int quantity, {bool archived = false}) => InventoryItem(
  id: 'item-$quantity',
  name: 'Item',
  category: 'General',
  quantity: quantity,
  expiryDate: DateTime(2030),
  imageUrl: '',
  createdAt: DateTime(2026),
  lifecycleState: archived
      ? InventoryLifecycleState.archived
      : InventoryLifecycleState.active,
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

  test(
    'stock attention separates zero and ignores archived and invalid stock',
    () {
      expect(LowStockPolicy.attention(_item(0)), StockAttention.outOfStock);
      expect(LowStockPolicy.isLowStock(_item(0)), isTrue);
      expect(LowStockPolicy.attention(_item(1)), StockAttention.lowStock);
      expect(LowStockPolicy.attention(_item(6)), isNull);
      expect(LowStockPolicy.attention(_item(0, archived: true)), isNull);
      expect(LowStockPolicy.attention(_item(-1)), isNull);
      for (final quantity in [-1, 9007199254740992]) {
        expect(
          () => InventoryItem.fromMap('invalid', {
            ..._item(0).toMap(),
            'quantity': quantity,
          }),
          throwsFormatException,
        );
      }
    },
  );
}
