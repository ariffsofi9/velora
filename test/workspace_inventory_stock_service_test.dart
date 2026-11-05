import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_inventory_stock_service.dart';
import 'package:cloud_functions/cloud_functions.dart';

class _Callable implements WorkspaceInventoryStockCallable {
  Map<String, Object>? payload;
  FirebaseFunctionsException? error;
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
    if (error != null) throw error!;
    return result;
  }
}

void main() {
  for (final (label, details) in <(String, Object?)>[
    ('empty map', <String, Object?>{}),
    ('string', 'insufficient-stock'),
    ('list', ['insufficient-stock']),
    ('number', 1),
    ('null reason', {'reason': null}),
    ('wrong-type reason', {'reason': 1}),
    (
      'nested reason',
      {
        'reason': {'reason': 'insufficient-stock'},
      },
    ),
  ]) {
    test('malformed callable details give generic feedback: $label', () async {
      final callable = _Callable()
        ..error = FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'insufficient-stock',
          details: details,
        );
      final adjuster = FirebaseWorkspaceInventoryStockAdjuster(
        callable: callable,
        session: WorkspaceSession.fromVerified(
          const CafeWorkspace(
            cafeId: 'cafe-a',
            uid: 'owner',
            ownerUid: 'owner',
            role: CafeRole.owner,
          ),
        ),
      );
      await expectLater(
        adjuster.adjustStock(
          WorkspaceInventoryStockRequest(
            idempotencyKey: 'malformed-details-01',
            itemId: 'item-a',
            direction: StockDirection.stockOut,
            quantity: 1,
            expectedVersion: 1,
          ),
        ),
        throwsA(
          isA<WorkspaceInventoryStockException>().having(
            (error) => error.failure,
            'failure',
            WorkspaceInventoryStockFailure.unavailable,
          ),
        ),
      );
    });
  }
  for (final (code, expected) in [
    ('permission-denied', WorkspaceInventoryStockFailure.permissionDenied),
    ('aborted', WorkspaceInventoryStockFailure.stale),
    ('unavailable', WorkspaceInventoryStockFailure.unavailable),
  ]) {
    test(
      'insufficient-stock details cannot override error code $code',
      () async {
        final callable = _Callable()
          ..error = FirebaseFunctionsException(
            code: code,
            message: 'private backend detail',
            details: {'reason': 'insufficient-stock'},
          );
        final adjuster = FirebaseWorkspaceInventoryStockAdjuster(
          callable: callable,
          session: WorkspaceSession.fromVerified(
            const CafeWorkspace(
              cafeId: 'cafe-a',
              uid: 'owner',
              ownerUid: 'owner',
              role: CafeRole.owner,
            ),
          ),
        );
        await expectLater(
          adjuster.adjustStock(
            WorkspaceInventoryStockRequest(
              idempotencyKey: 'wrong-code-reason-01',
              itemId: 'item-a',
              direction: StockDirection.stockOut,
              quantity: 1,
              expectedVersion: 1,
            ),
          ),
          throwsA(
            isA<WorkspaceInventoryStockException>().having(
              (error) => error.failure,
              'failure',
              expected,
            ),
          ),
        );
      },
    );
  }
  for (final reason in ['insufficient-stock', 'archived', null]) {
    test(
      'failed-precondition classification uses safe reason: $reason',
      () async {
        final callable = _Callable()
          ..error = FirebaseFunctionsException(
            code: 'failed-precondition',
            message: 'Untrusted backend message',
            details: reason == null ? null : {'reason': reason},
          );
        final adjuster = FirebaseWorkspaceInventoryStockAdjuster(
          callable: callable,
          session: WorkspaceSession.fromVerified(
            const CafeWorkspace(
              cafeId: 'cafe-a',
              uid: 'owner',
              ownerUid: 'owner',
              role: CafeRole.owner,
            ),
          ),
        );
        await expectLater(
          adjuster.adjustStock(
            const WorkspaceInventoryStockRequest(
              idempotencyKey: 'error-mapping-key-01',
              itemId: 'item-a',
              direction: StockDirection.stockOut,
              quantity: 1,
              expectedVersion: 1,
            ),
          ),
          throwsA(
            isA<WorkspaceInventoryStockException>().having(
              (error) => error.failure,
              'failure',
              reason == 'insufficient-stock'
                  ? WorkspaceInventoryStockFailure.insufficientStock
                  : WorkspaceInventoryStockFailure.unavailable,
            ),
          ),
        );
      },
    );
  }
  test('maps exact stock payload without authority or audit fields', () async {
    final callable = _Callable();
    final adjuster = FirebaseWorkspaceInventoryStockAdjuster(
      session: WorkspaceSession.fromVerified(
        const CafeWorkspace(
          cafeId: 'cafe-a',
          uid: 'owner',
          ownerUid: 'owner',
          role: CafeRole.owner,
        ),
      ),
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
      'expectedCafeId': 'cafe-a',
      'expectedMembershipGeneration': 0,
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
      session: WorkspaceSession.fromVerified(
        const CafeWorkspace(
          cafeId: 'cafe-a',
          uid: 'owner',
          ownerUid: 'owner',
          role: CafeRole.owner,
        ),
      ),
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
      session: WorkspaceSession.fromVerified(
        const CafeWorkspace(
          cafeId: 'cafe-a',
          uid: 'owner',
          ownerUid: 'owner',
          role: CafeRole.owner,
        ),
      ),
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
