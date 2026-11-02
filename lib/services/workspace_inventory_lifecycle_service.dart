import 'package:cloud_functions/cloud_functions.dart';

enum InventoryLifecycleAction { archive, restore }

class WorkspaceInventoryLifecycleRequest {
  final String idempotencyKey;
  final String itemId;
  final InventoryLifecycleAction action;
  final int expectedVersion;

  const WorkspaceInventoryLifecycleRequest({
    required this.idempotencyKey,
    required this.itemId,
    required this.action,
    required this.expectedVersion,
  });

  Map<String, Object> toCallableData() => {
    'idempotencyKey': idempotencyKey,
    'itemId': itemId,
    'action': action.name,
    'expectedVersion': expectedVersion,
  };

  String get fingerprint => '$itemId\u0000${action.name}\u0000$expectedVersion';
}

class WorkspaceInventoryLifecycleResult {
  final String itemId;
  final String lifecycleState;
  final int version;
  final bool changed;
  const WorkspaceInventoryLifecycleResult({
    required this.itemId,
    required this.lifecycleState,
    required this.version,
    required this.changed,
  });
}

enum WorkspaceInventoryLifecycleFailure {
  unauthenticated,
  invalidInput,
  permissionDenied,
  notFound,
  conflict,
  stale,
  unavailable,
  internal,
}

class WorkspaceInventoryLifecycleException implements Exception {
  final WorkspaceInventoryLifecycleFailure failure;
  const WorkspaceInventoryLifecycleException(this.failure);
}

abstract interface class WorkspaceInventoryLifecycleManager {
  Future<WorkspaceInventoryLifecycleResult> setLifecycle(
    WorkspaceInventoryLifecycleRequest request,
  );
}

class FirebaseWorkspaceInventoryLifecycleManager
    implements WorkspaceInventoryLifecycleManager {
  final FirebaseFunctions _functions;
  FirebaseWorkspaceInventoryLifecycleManager({FirebaseFunctions? functions})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  @override
  Future<WorkspaceInventoryLifecycleResult> setLifecycle(
    WorkspaceInventoryLifecycleRequest request,
  ) async {
    try {
      final response = await _functions
          .httpsCallable('setInventoryLifecycle')
          .call<Map<String, dynamic>>(request.toCallableData());
      final data = response.data;
      if (data['itemId'] is! String ||
          data['lifecycleState'] is! String ||
          data['version'] is! int ||
          data['changed'] is! bool) {
        throw const WorkspaceInventoryLifecycleException(
          WorkspaceInventoryLifecycleFailure.internal,
        );
      }
      return WorkspaceInventoryLifecycleResult(
        itemId: data['itemId'] as String,
        lifecycleState: data['lifecycleState'] as String,
        version: data['version'] as int,
        changed: data['changed'] as bool,
      );
    } on FirebaseFunctionsException catch (error) {
      throw WorkspaceInventoryLifecycleException(_mapCode(error.code));
    } on WorkspaceInventoryLifecycleException {
      rethrow;
    } catch (_) {
      throw const WorkspaceInventoryLifecycleException(
        WorkspaceInventoryLifecycleFailure.unavailable,
      );
    }
  }

  static WorkspaceInventoryLifecycleFailure _mapCode(String code) =>
      switch (code) {
        'unauthenticated' => WorkspaceInventoryLifecycleFailure.unauthenticated,
        'invalid-argument' => WorkspaceInventoryLifecycleFailure.invalidInput,
        'permission-denied' || 'failed-precondition' =>
          WorkspaceInventoryLifecycleFailure.permissionDenied,
        'not-found' => WorkspaceInventoryLifecycleFailure.notFound,
        'already-exists' => WorkspaceInventoryLifecycleFailure.conflict,
        'aborted' => WorkspaceInventoryLifecycleFailure.stale,
        'unavailable' ||
        'deadline-exceeded' => WorkspaceInventoryLifecycleFailure.unavailable,
        _ => WorkspaceInventoryLifecycleFailure.internal,
      };
}
