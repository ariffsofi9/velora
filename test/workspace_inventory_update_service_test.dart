import 'package:flutter/foundation.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_session.dart';
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

final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

AndroidPilotPolicy _pilotPolicy(bool invalid) => AndroidPilotPolicy.parse(
  invalid
      ? {'VELORA_ANDROID_READ_ONLY_PILOT': 'false'}
      : {
          'VELORA_ANDROID_READ_ONLY_PILOT': 'true',
          'VELORA_FIREBASE_PROJECT': AndroidPilotPolicy.approvedProject,
          'VELORA_ANDROID_PILOT_BINDINGS': '[["owner","cafe"]]',
        },
  isWeb: false,
  platform: TargetPlatform.android,
);

void main() {
  for (final invalid in [false, true]) {
    test(
      'independent update invalid=$invalid rejects before preparation/SDK lookup',
      () async {
        final policy = _pilotPolicy(invalid), callable = _Callable();
        final service = FirebaseWorkspaceInventoryUpdater(
          pilotPolicy: policy,
          callable: callable,
        );
        expect(service.pilotPolicy, same(policy));
        await expectLater(
          service.updateItem(
            WorkspaceInventoryUpdateRequest(
              idempotencyKey: 'update-request-01',
              itemId: 'item',
              expectedVersion: 1,
              name: 'Milk',
              category: 'Dairy',
              unit: 'L',
              expiryDate: DateTime(2030),
              imageUrl: '',
            ),
          ),
          throwsA(isA<InventoryUpdatePilotPolicyException>()),
        );
        expect(callable.payload, isNull);
        await expectLater(
          FirebaseWorkspaceInventoryUpdateCallable(
            pilotPolicy: policy,
          ).call({}),
          throwsA(isA<InventoryUpdatePilotPolicyException>()),
        );
      },
    );
  }

  test('maps only supported metadata with canonical UTC expiry', () async {
    final callable = _Callable();
    final updater = FirebaseWorkspaceInventoryUpdater(
      pilotPolicy: _normalPolicy,
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
      'expectedCafeId': 'cafe-a',
      'expectedMembershipGeneration': 0,
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
    final updater = FirebaseWorkspaceInventoryUpdater(
      pilotPolicy: _normalPolicy,
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
