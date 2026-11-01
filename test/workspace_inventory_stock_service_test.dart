import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_inventory_stock_service.dart';

class _Callable implements WorkspaceInventoryStockCallable {
  Map<String, Object>? payload;
  Map<String, dynamic> result = {
    'itemId': 'item-a',
    'direction': 'in',
    'quantity': 3,
    'resultingQuantity': 7,
    'version': 2,
    'adjusted': true,
  };

  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    payload = data;
    return result;
  }
}

void main() {
  test('maps exact stock payload without authority or audit fields', () async {
    final callable = _Callable();
    final adjuster = FirebaseWorkspaceInventoryStockAdjuster(
      callable: callable,
    );
    final result = await adjuster.adjustStock(
      const WorkspaceInventoryStockRequest(
        idempotencyKey: 'stock-request-0001',
        itemId: 'item-a',
        direction: StockDirection.stockIn,
        quantity: 3,
        expectedVersion: 1,
        reason: ' Delivery ',
      ),
    );

    expect(result.resultingQuantity, 7);
    expect(callable.payload, {
      'idempotencyKey': 'stock-request-0001',
      'itemId': 'item-a',
      'direction': 'in',
      'quantity': 3,
      'expectedVersion': 1,
      'reason': 'Delivery',
    });
    for (final forbidden in [
      'cafeId',
      'uid',
      'role',
      'actorUid',
      'resultingQuantity',
      'movementId',
      'activityId',
      'timestamp',
    ]) {
      expect(callable.payload, isNot(contains(forbidden)));
    }
  });

  test('omits an empty optional reason', () async {
    final callable = _Callable();
    final adjuster = FirebaseWorkspaceInventoryStockAdjuster(
      callable: callable,
    );
    await adjuster.adjustStock(
      const WorkspaceInventoryStockRequest(
        idempotencyKey: 'stock-request-0001',
        itemId: 'item-a',
        direction: StockDirection.stockIn,
        quantity: 3,
        expectedVersion: 1,
        reason: '',
      ),
    );
    expect(callable.payload, isNot(contains('reason')));
  });

  test('rejects malformed callable results', () async {
    final callable = _Callable()..result = {'adjusted': true};
    final adjuster = FirebaseWorkspaceInventoryStockAdjuster(
      callable: callable,
    );
    await expectLater(
      adjuster.adjustStock(
        const WorkspaceInventoryStockRequest(
          idempotencyKey: 'stock-request-0001',
          itemId: 'item-a',
          direction: StockDirection.stockIn,
          quantity: 3,
          expectedVersion: 1,
          reason: '',
        ),
      ),
      throwsA(
        isA<WorkspaceInventoryStockException>().having(
          (error) => error.failure,
          'failure',
          WorkspaceInventoryStockFailure.internal,
        ),
      ),
    );
  });
}
