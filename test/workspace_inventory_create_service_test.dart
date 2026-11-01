import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_inventory_create_service.dart';

class _Callable implements WorkspaceInventoryCreateCallable {
  Map<String, Object>? payload;
  Map<String, dynamic> result = {'itemId': 'item-a', 'created': true};

  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    payload = data;
    return result;
  }
}

void main() {
  test('maps the exact callable payload with canonical UTC expiry', () async {
    final callable = _Callable();
    final creator = FirebaseWorkspaceInventoryCreator(callable: callable);
    final request = WorkspaceInventoryCreateRequest(
      idempotencyKey: 'request-00000001',
      name: 'Fresh Milk',
      category: 'Dairy',
      quantity: 4,
      unit: 'L',
      expiryDate: DateTime(2030, 1, 2, 18, 30),
    );

    final result = await creator.createItem(request);

    expect(result.itemId, 'item-a');
    expect(result.created, isTrue);
    expect(callable.payload, {
      'idempotencyKey': 'request-00000001',
      'name': 'Fresh Milk',
      'category': 'Dairy',
      'quantity': 4,
      'unit': 'L',
      'expiryDate': '2030-01-02T00:00:00.000Z',
      'imageUrl': '',
    });
    expect(callable.payload, isNot(contains('cafeId')));
    expect(callable.payload, isNot(contains('uid')));
    expect(callable.payload, isNot(contains('role')));
  });

  test('rejects malformed callable results', () async {
    final callable = _Callable()..result = {'created': true};
    final creator = FirebaseWorkspaceInventoryCreator(callable: callable);

    await expectLater(
      creator.createItem(
        WorkspaceInventoryCreateRequest(
          idempotencyKey: 'request-00000001',
          name: 'Milk',
          category: 'Dairy',
          quantity: 1,
          unit: 'L',
          expiryDate: DateTime(2030),
        ),
      ),
      throwsA(
        isA<WorkspaceInventoryCreateException>().having(
          (error) => error.failure,
          'failure',
          WorkspaceInventoryCreateFailure.internal,
        ),
      ),
    );
  });
}
