import 'workspace_session.dart';
import 'package:cloud_functions/cloud_functions.dart';

class WorkspaceInventoryUpdateRequest {
  final String idempotencyKey;
  final String itemId;
  final int expectedVersion;
  final String name;
  final String category;
  final String unit;
  final DateTime expiryDate;
  final String imageUrl;

  const WorkspaceInventoryUpdateRequest({
    required this.idempotencyKey,
    required this.itemId,
    required this.expectedVersion,
    required this.name,
    required this.category,
    required this.unit,
    required this.expiryDate,
    required this.imageUrl,
  });

  Map<String, Object> toCallableData() => {
    'idempotencyKey': idempotencyKey,
    'itemId': itemId,
    'expectedVersion': expectedVersion,
    'name': name,
    'category': category,
    'unit': unit,
    'expiryDate': canonicalUtcDate(expiryDate),
    'imageUrl': imageUrl,
  };

  static String canonicalUtcDate(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day).toIso8601String();

  String get fingerprint => [
    itemId,
    expectedVersion,
    name,
    category,
    unit,
    canonicalUtcDate(expiryDate),
    imageUrl,
  ].join('\u0000');
}

class WorkspaceInventoryUpdateResult {
  final String itemId;
  final bool updated;
  final int version;

  const WorkspaceInventoryUpdateResult({
    required this.itemId,
    required this.updated,
    required this.version,
  });
}

enum WorkspaceInventoryUpdateFailure {
  unauthenticated,
  invalidInput,
  permissionDenied,
  notFound,
  conflict,
  stale,
  unavailable,
  internal,
}

class WorkspaceInventoryUpdateException implements Exception {
  final WorkspaceInventoryUpdateFailure failure;
  const WorkspaceInventoryUpdateException(this.failure);
}

abstract interface class WorkspaceInventoryUpdater {
  Future<WorkspaceInventoryUpdateResult> updateItem(
    WorkspaceInventoryUpdateRequest request,
  );
}

abstract interface class WorkspaceInventoryUpdateCallable {
  Future<Map<String, dynamic>> call(Map<String, Object> data);
}

class FirebaseWorkspaceInventoryUpdateCallable
    implements WorkspaceInventoryUpdateCallable {
  final FirebaseFunctions? _functions;

  FirebaseWorkspaceInventoryUpdateCallable({FirebaseFunctions? functions})
    : _functions = functions;

  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    final callable =
        (_functions ?? FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
            .httpsCallable('updateInventoryItem');
    final response = await callable.call<Map<String, dynamic>>(data);
    return response.data;
  }
}

class FirebaseWorkspaceInventoryUpdater implements WorkspaceInventoryUpdater {
  final WorkspaceSession? session;
  final WorkspaceInventoryUpdateCallable _callable;

  FirebaseWorkspaceInventoryUpdater({
    this.session,
    FirebaseFunctions? functions,
    WorkspaceInventoryUpdateCallable? callable,
  }) : _callable =
           callable ??
           FirebaseWorkspaceInventoryUpdateCallable(functions: functions);

  @override
  Future<WorkspaceInventoryUpdateResult> updateItem(
    WorkspaceInventoryUpdateRequest request,
  ) async {
    try {
      final captured = captureMutationSession(request, session);
      final payload = {...request.toCallableData(), ...captured.mutationData};
      final data = await _callable.call(payload);
      captured.requireActive();
      if (data['itemId'] is! String ||
          data['updated'] is! bool ||
          data['version'] is! int) {
        throw const WorkspaceInventoryUpdateException(
          WorkspaceInventoryUpdateFailure.internal,
        );
      }
      return WorkspaceInventoryUpdateResult(
        itemId: data['itemId'] as String,
        updated: data['updated'] as bool,
        version: data['version'] as int,
      );
    } on FirebaseFunctionsException catch (error) {
      throw WorkspaceInventoryUpdateException(_mapCode(error.code));
    } on WorkspaceInventoryUpdateException {
      rethrow;
    } catch (_) {
      throw const WorkspaceInventoryUpdateException(
        WorkspaceInventoryUpdateFailure.unavailable,
      );
    }
  }

  static WorkspaceInventoryUpdateFailure _mapCode(String code) =>
      switch (code) {
        'unauthenticated' => WorkspaceInventoryUpdateFailure.unauthenticated,
        'invalid-argument' => WorkspaceInventoryUpdateFailure.invalidInput,
        'permission-denied' || 'failed-precondition' =>
          WorkspaceInventoryUpdateFailure.permissionDenied,
        'not-found' => WorkspaceInventoryUpdateFailure.notFound,
        'already-exists' => WorkspaceInventoryUpdateFailure.conflict,
        'aborted' => WorkspaceInventoryUpdateFailure.stale,
        'unavailable' ||
        'deadline-exceeded' => WorkspaceInventoryUpdateFailure.unavailable,
        _ => WorkspaceInventoryUpdateFailure.internal,
      };
}
