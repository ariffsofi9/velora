import 'package:cloud_functions/cloud_functions.dart';

enum StockDirection { stockIn, stockOut }

class WorkspaceInventoryStockRequest {
  final String idempotencyKey;
  final String itemId;
  final StockDirection direction;
  final int quantity;
  final int expectedVersion;
  final String reason;

  const WorkspaceInventoryStockRequest({
    required this.idempotencyKey,
    required this.itemId,
    required this.direction,
    required this.quantity,
    required this.expectedVersion,
    this.reason = '',
  });

  String get directionValue =>
      direction == StockDirection.stockIn ? 'in' : 'out';

  Map<String, Object> toCallableData() => {
    'idempotencyKey': idempotencyKey,
    'itemId': itemId,
    'direction': directionValue,
    'quantity': quantity,
    'expectedVersion': expectedVersion,
    if (reason.trim().isNotEmpty) 'reason': reason.trim(),
  };

  String get fingerprint => [
    itemId,
    directionValue,
    quantity,
    expectedVersion,
    reason.trim(),
  ].join('\u0000');
}

class WorkspaceInventoryStockResult {
  final String itemId;
  final StockDirection direction;
  final int quantity;
  final int resultingQuantity;
  final int version;
  final bool adjusted;

  const WorkspaceInventoryStockResult({
    required this.itemId,
    required this.direction,
    required this.quantity,
    required this.resultingQuantity,
    required this.version,
    required this.adjusted,
  });
}

enum WorkspaceInventoryStockFailure {
  unauthenticated,
  invalidInput,
  permissionDenied,
  notFound,
  conflict,
  stale,
  insufficientStock,
  outOfRange,
  unavailable,
  internal,
}

class WorkspaceInventoryStockException implements Exception {
  final WorkspaceInventoryStockFailure failure;
  const WorkspaceInventoryStockException(this.failure);
}

abstract interface class WorkspaceInventoryStockAdjuster {
  Future<WorkspaceInventoryStockResult> adjustStock(
    WorkspaceInventoryStockRequest request,
  );
}

abstract interface class WorkspaceInventoryStockCallable {
  Future<Map<String, dynamic>> call(Map<String, Object> data);
}

class FirebaseWorkspaceInventoryStockCallable
    implements WorkspaceInventoryStockCallable {
  final FirebaseFunctions? _functions;

  FirebaseWorkspaceInventoryStockCallable({FirebaseFunctions? functions})
    : _functions = functions;

  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    final callable =
        (_functions ?? FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
            .httpsCallable('adjustInventoryStock');
    final response = await callable.call<Map<String, dynamic>>(data);
    return response.data;
  }
}

class FirebaseWorkspaceInventoryStockAdjuster
    implements WorkspaceInventoryStockAdjuster {
  final WorkspaceInventoryStockCallable _callable;

  FirebaseWorkspaceInventoryStockAdjuster({
    FirebaseFunctions? functions,
    WorkspaceInventoryStockCallable? callable,
  }) : _callable =
           callable ??
           FirebaseWorkspaceInventoryStockCallable(functions: functions);

  @override
  Future<WorkspaceInventoryStockResult> adjustStock(
    WorkspaceInventoryStockRequest request,
  ) async {
    try {
      final data = await _callable.call(request.toCallableData());
      final direction = switch (data['direction']) {
        'in' => StockDirection.stockIn,
        'out' => StockDirection.stockOut,
        _ => null,
      };
      if (data['itemId'] is! String ||
          direction == null ||
          data['quantity'] is! int ||
          data['resultingQuantity'] is! int ||
          data['version'] is! int ||
          data['adjusted'] is! bool) {
        throw const WorkspaceInventoryStockException(
          WorkspaceInventoryStockFailure.internal,
        );
      }
      return WorkspaceInventoryStockResult(
        itemId: data['itemId'] as String,
        direction: direction,
        quantity: data['quantity'] as int,
        resultingQuantity: data['resultingQuantity'] as int,
        version: data['version'] as int,
        adjusted: data['adjusted'] as bool,
      );
    } on FirebaseFunctionsException catch (error) {
      throw WorkspaceInventoryStockException(_mapCode(error.code));
    } on WorkspaceInventoryStockException {
      rethrow;
    } catch (_) {
      throw const WorkspaceInventoryStockException(
        WorkspaceInventoryStockFailure.unavailable,
      );
    }
  }

  static WorkspaceInventoryStockFailure _mapCode(String code) => switch (code) {
    'unauthenticated' => WorkspaceInventoryStockFailure.unauthenticated,
    'invalid-argument' => WorkspaceInventoryStockFailure.invalidInput,
    'permission-denied' => WorkspaceInventoryStockFailure.permissionDenied,
    'not-found' => WorkspaceInventoryStockFailure.notFound,
    'already-exists' => WorkspaceInventoryStockFailure.conflict,
    'aborted' => WorkspaceInventoryStockFailure.stale,
    'failed-precondition' => WorkspaceInventoryStockFailure.insufficientStock,
    'out-of-range' => WorkspaceInventoryStockFailure.outOfRange,
    'unavailable' ||
    'deadline-exceeded' => WorkspaceInventoryStockFailure.unavailable,
    _ => WorkspaceInventoryStockFailure.internal,
  };
}
