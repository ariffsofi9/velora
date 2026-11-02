import 'package:cloud_firestore/cloud_firestore.dart';

enum InventoryMovementType { initialStock, stockIn, stockOut }

class InventoryMovement {
  final String id;
  final String cafeId;
  final String itemId;
  final String actorUid;
  final InventoryMovementType type;
  final String? direction;
  final int quantity;
  final int? delta;
  final int? previousQuantity;
  final int? resultingQuantity;
  final String unit;
  final String? reason;
  final DateTime createdAt;
  final int? fromVersion;
  final int? resultVersion;
  final String requestHash;

  const InventoryMovement({
    required this.id,
    required this.cafeId,
    required this.itemId,
    required this.actorUid,
    required this.type,
    required this.direction,
    required this.quantity,
    required this.delta,
    required this.previousQuantity,
    required this.resultingQuantity,
    required this.unit,
    required this.reason,
    required this.createdAt,
    required this.fromVersion,
    required this.resultVersion,
    required this.requestHash,
  });

  factory InventoryMovement.fromMap(String id, Map<String, dynamic> data) {
    if (_integer(data, 'schemaVersion', required: true) != 1) {
      throw const FormatException('Unsupported inventory movement schema.');
    }
    final type = switch (data['type']) {
      'initial_stock' => InventoryMovementType.initialStock,
      'stock_in' => InventoryMovementType.stockIn,
      'stock_out' => InventoryMovementType.stockOut,
      _ => throw const FormatException('Unsupported inventory movement type.'),
    };
    final quantity = _integer(data, 'quantity', required: true)!;
    if (quantity < 0 ||
        (type != InventoryMovementType.initialStock && quantity == 0)) {
      throw const FormatException('Invalid inventory movement quantity.');
    }

    final direction = data['direction'];
    final delta = _integer(data, 'delta');
    final previous = _integer(data, 'previousQuantity');
    final resulting = _integer(data, 'resultingQuantity');
    final fromVersion = _positiveVersion(data, 'fromVersion');
    final resultVersion = _positiveVersion(data, 'resultVersion');
    if (type != InventoryMovementType.initialStock) {
      final expectedDirection = type == InventoryMovementType.stockIn
          ? 'in'
          : 'out';
      final expectedDelta = type == InventoryMovementType.stockIn
          ? quantity
          : -quantity;
      if (direction != expectedDirection ||
          delta != expectedDelta ||
          previous == null ||
          previous < 0 ||
          resulting == null ||
          resulting < 0 ||
          resulting != previous + expectedDelta ||
          fromVersion == null ||
          resultVersion != fromVersion + 1) {
        throw const FormatException('Inconsistent stock movement data.');
      }
    }

    return InventoryMovement(
      id: _identity(id, 'movement ID'),
      cafeId: _identity(data['cafeId'], 'cafe ID'),
      itemId: _identity(data['itemId'], 'item ID'),
      actorUid: _identity(data['actorUid'], 'actor UID'),
      type: type,
      direction: direction is String ? direction : null,
      quantity: quantity,
      delta: delta,
      previousQuantity: previous,
      resultingQuantity: resulting,
      unit: _identity(data['unit'], 'unit'),
      reason: data['reason'] is String && (data['reason'] as String).isNotEmpty
          ? data['reason'] as String
          : null,
      createdAt: _timestamp(data['createdAt']),
      fromVersion: fromVersion,
      resultVersion: resultVersion,
      requestHash: _identity(data['requestHash'], 'request hash'),
    );
  }

  static int? _integer(
    Map<String, dynamic> data,
    String field, {
    bool required = false,
  }) {
    final value = data[field];
    if (value == null && !required) return null;
    if (value is int) return value;
    throw FormatException('Invalid $field.');
  }

  static int? _positiveVersion(Map<String, dynamic> data, String field) {
    final value = _integer(data, field);
    if (value == null) return null;
    if (value < 1) throw FormatException('Invalid $field.');
    return value;
  }

  static String _identity(Object? value, String label) {
    if (value is! String || value.trim().isEmpty || value.contains('/')) {
      throw FormatException('Invalid $label.');
    }
    return value;
  }

  /// Missing, pending, or malformed timestamps are rejected. History never
  /// substitutes a fabricated date because that would corrupt ordering.
  static DateTime _timestamp(Object? value) => switch (value) {
    Timestamp timestamp => timestamp.toDate(),
    DateTime date => date,
    _ => throw const FormatException('Invalid movement timestamp.'),
  };
}
