import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_inventory_update_service.dart';

class _Callable implements WorkspaceInventoryUpdateCallable {
  Map<String, Object>? payload;
  Map<String, dynamic> result = {
    'itemId': 'item-a',
    'updated': true,
    'version': 2,
  };

  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    payload = data;
    return result;
  }
}

void main() {
  test('maps only supported metadata with canonical UTC expiry', () async {
    final callable = _Callable();
    final updater = FirebaseWorkspaceInventoryUpdater(callable: callable);
    final result = await updater.updateItem(
      WorkspaceInventoryUpdateRequest(
        idempotencyKey: 'update-request-0001',
        itemId: 'item-a',
        expectedVersion: 1,
        name: 'Fresh Milk',
        category: 'Dairy',
        unit: 'L',
        expiryDate: DateTime(2030, 1, 2, 18, 30),
        imageUrl: 'https://example.test/milk.png',
      ),
    );

    expect(result.version, 2);
    expect(callable.payload, {
      'idempotencyKey': 'update-request-0001',
      'itemId': 'item-a',
      'expectedVersion': 1,
      'name': 'Fresh Milk',
      'category': 'Dairy',
      'unit': 'L',
      'expiryDate': '2030-01-02T00:00:00.000Z',
      'imageUrl': 'https://example.test/milk.png',
    });
    for (final forbidden in [
      'quantity',
      'cafeId',
      'uid',
      'role',
      'actorUid',
      'updatedAt',
    ]) {
      expect(callable.payload, isNot(contains(forbidden)));
    }
  });

  test('rejects malformed callable results', () async {
    final callable = _Callable()..result = {'updated': true, 'version': 2};
    final updater = FirebaseWorkspaceInventoryUpdater(callable: callable);

    await expectLater(
      updater.updateItem(
        WorkspaceInventoryUpdateRequest(
          idempotencyKey: 'update-request-0001',
          itemId: 'item-a',
          expectedVersion: 1,
          name: 'Milk',
          category: 'Dairy',
          unit: 'L',
          expiryDate: DateTime(2030),
          imageUrl: '',
        ),
      ),
      throwsA(
        isA<WorkspaceInventoryUpdateException>().having(
          (error) => error.failure,
          'failure',
          WorkspaceInventoryUpdateFailure.internal,
        ),
      ),
    );
  });
}
