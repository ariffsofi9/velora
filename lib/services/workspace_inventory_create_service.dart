import 'workspace_session.dart';
import 'package:cloud_functions/cloud_functions.dart';

class WorkspaceInventoryCreateRequest {
  final String idempotencyKey;
  final String name;
  final String category;
  final int quantity;
  final String unit;
  final DateTime expiryDate;
  final String imageUrl;

  const WorkspaceInventoryCreateRequest({
    required this.idempotencyKey,
    required this.name,
    required this.category,
    required this.quantity,
    required this.unit,
    required this.expiryDate,
    this.imageUrl = '',
  });

  Map<String, Object> toCallableData() => {
    'idempotencyKey': idempotencyKey,
    'name': name,
    'category': category,
    'quantity': quantity,
    'unit': unit,
    'expiryDate': canonicalUtcDate(expiryDate),
    'imageUrl': imageUrl,
  };

  static String canonicalUtcDate(DateTime value) {
    final date = DateTime.utc(value.year, value.month, value.day);
    return date.toIso8601String();
  }

  String get fingerprint => [
    name,
    category,
    quantity,
    unit,
    canonicalUtcDate(expiryDate),
    imageUrl,
  ].join('\u0000');
}

class WorkspaceInventoryCreateResult {
  final String itemId;
  final bool created;

  const WorkspaceInventoryCreateResult({
    required this.itemId,
    required this.created,
  });
}

enum WorkspaceInventoryCreateFailure {
  unauthenticated,
  invalidInput,
  permissionDenied,
  conflict,
  unavailable,
  internal,
}

class WorkspaceInventoryCreateException implements Exception {
  final WorkspaceInventoryCreateFailure failure;
  const WorkspaceInventoryCreateException(this.failure);
}

abstract interface class WorkspaceInventoryCreator {
  Future<WorkspaceInventoryCreateResult> createItem(
    WorkspaceInventoryCreateRequest request,
  );
}

abstract interface class WorkspaceInventoryCreateCallable {
  Future<Map<String, dynamic>> call(Map<String, Object> data);
}

class FirebaseWorkspaceInventoryCreateCallable
    implements WorkspaceInventoryCreateCallable {
  final FirebaseFunctions? _functions;

  FirebaseWorkspaceInventoryCreateCallable({FirebaseFunctions? functions})
    : _functions = functions;

  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    final callable =
        (_functions ?? FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
            .httpsCallable('createInventoryItem');
    final response = await callable.call<Map<String, dynamic>>(data);
    return response.data;
  }
}

class FirebaseWorkspaceInventoryCreator implements WorkspaceInventoryCreator {
  final WorkspaceSession? session;
  final WorkspaceInventoryCreateCallable _callable;

  FirebaseWorkspaceInventoryCreator({
    this.session,
    FirebaseFunctions? functions,
    WorkspaceInventoryCreateCallable? callable,
  }) : _callable =
           callable ??
           FirebaseWorkspaceInventoryCreateCallable(functions: functions);

  @override
  Future<WorkspaceInventoryCreateResult> createItem(
    WorkspaceInventoryCreateRequest request,
  ) async {
    try {
      final captured = captureMutationSession(request, session);
      final payload = {...request.toCallableData(), ...captured.mutationData};
      final data = await _callable.call(payload);
      captured.requireActive();
      if (data['itemId'] is! String || data['created'] is! bool) {
        throw const WorkspaceInventoryCreateException(
          WorkspaceInventoryCreateFailure.internal,
        );
      }
      return WorkspaceInventoryCreateResult(
        itemId: data['itemId'] as String,
        created: data['created'] as bool,
      );
    } on FirebaseFunctionsException catch (error) {
      throw WorkspaceInventoryCreateException(_mapCode(error.code));
    } on WorkspaceInventoryCreateException {
      rethrow;
    } catch (_) {
      throw const WorkspaceInventoryCreateException(
        WorkspaceInventoryCreateFailure.unavailable,
      );
    }
  }

  static WorkspaceInventoryCreateFailure _mapCode(String code) =>
      switch (code) {
        'unauthenticated' => WorkspaceInventoryCreateFailure.unauthenticated,
        'invalid-argument' => WorkspaceInventoryCreateFailure.invalidInput,
        'permission-denied' || 'failed-precondition' =>
          WorkspaceInventoryCreateFailure.permissionDenied,
        'already-exists' => WorkspaceInventoryCreateFailure.conflict,
        'aborted' => WorkspaceInventoryCreateFailure.conflict,
        'unavailable' ||
        'deadline-exceeded' => WorkspaceInventoryCreateFailure.unavailable,
        _ => WorkspaceInventoryCreateFailure.internal,
      };
}
