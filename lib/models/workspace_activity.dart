import 'package:cloud_firestore/cloud_firestore.dart';

enum WorkspaceActivityType {
  inventoryCreated,
  inventoryUpdated,
  inventoryUpdateNoop,
  inventoryStockAdjusted,
  inventoryArchived,
  inventoryRestored,
}

class WorkspaceActivity {
  final String id;
  final String cafeId;
  final String itemId;
  final String actorUid;
  final WorkspaceActivityType type;
  final DateTime createdAt;
  final String? itemName;
  final int? quantity;
  final String? unit;
  final String? direction;
  final int? previousQuantity;
  final int? resultingQuantity;
  final List<String> changedFields;
  final bool? updated;
  final String? reason;

  const WorkspaceActivity({
    required this.id,
    required this.cafeId,
    required this.itemId,
    required this.actorUid,
    required this.type,
    required this.createdAt,
    required this.itemName,
    required this.quantity,
    required this.unit,
    required this.direction,
    required this.previousQuantity,
    required this.resultingQuantity,
    required this.changedFields,
    required this.updated,
    required this.reason,
  });

  factory WorkspaceActivity.fromMap(String id, Map<String, dynamic> data) {
    if (_integer(data['schemaVersion']) != 1) {
      throw const FormatException('Unsupported activity schema.');
    }
    final type = switch (data['type']) {
      'inventory_created' => WorkspaceActivityType.inventoryCreated,
      'inventory_updated' => WorkspaceActivityType.inventoryUpdated,
      'inventory_update_noop' => WorkspaceActivityType.inventoryUpdateNoop,
      'inventory_stock_adjusted' =>
        WorkspaceActivityType.inventoryStockAdjusted,
      'inventory_archived' => WorkspaceActivityType.inventoryArchived,
      'inventory_restored' => WorkspaceActivityType.inventoryRestored,
      _ => throw const FormatException('Unsupported activity type.'),
    };
    final quantity = _optionalInteger(data['quantity']);
    final previous = _optionalInteger(data['previousQuantity']);
    final resulting = _optionalInteger(data['resultingQuantity']);
    final direction = data['direction'];
    final unit = data['unit'];
    final updated = data['updated'];
    final changedFields =
        type == WorkspaceActivityType.inventoryUpdated ||
            type == WorkspaceActivityType.inventoryUpdateNoop
        ? _stringList(data['changedFields'])
        : const <String>[];
    _identity(data['requestHash'], 'request hash');

    switch (type) {
      case WorkspaceActivityType.inventoryCreated:
        if (quantity == null || quantity < 0 || !_supportedUnit(unit)) {
          throw const FormatException('Invalid creation activity.');
        }
        _text(data['itemName'], 'item name');
        break;
      case WorkspaceActivityType.inventoryUpdated:
      case WorkspaceActivityType.inventoryUpdateNoop:
        final shouldBeUpdated = type == WorkspaceActivityType.inventoryUpdated;
        final fromVersion = _positiveInteger(data['fromVersion']);
        final resultVersion = _positiveInteger(data['resultVersion']);
        if (updated is! bool ||
            updated != shouldBeUpdated ||
            resultVersion != fromVersion + (shouldBeUpdated ? 1 : 0)) {
          throw const FormatException('Invalid update activity.');
        }
        break;
      case WorkspaceActivityType.inventoryStockAdjusted:
        if ((direction != 'in' && direction != 'out') ||
            quantity == null ||
            quantity <= 0 ||
            previous == null ||
            previous < 0 ||
            resulting == null ||
            resulting < 0 ||
            !_supportedUnit(unit) ||
            resulting !=
                previous + (direction == 'in' ? quantity : -quantity) ||
            _positiveInteger(data['resultVersion']) !=
                _positiveInteger(data['fromVersion']) + 1) {
          throw const FormatException('Invalid stock activity.');
        }
        break;
      case WorkspaceActivityType.inventoryArchived:
      case WorkspaceActivityType.inventoryRestored:
        final expectedResult = type == WorkspaceActivityType.inventoryArchived
            ? 'archived'
            : 'active';
        final expectedFrom = type == WorkspaceActivityType.inventoryArchived
            ? 'active'
            : 'archived';
        final preserved = _optionalInteger(data['preservedQuantity']);
        if (data['fromState'] != expectedFrom ||
            data['resultState'] != expectedResult ||
            preserved == null ||
            preserved < 0 ||
            _positiveInteger(data['resultVersion']) !=
                _positiveInteger(data['fromVersion']) + 1) {
          throw const FormatException('Invalid lifecycle activity.');
        }
        break;
    }

    return WorkspaceActivity(
      id: _identity(id, 'activity ID'),
      cafeId: _identity(data['cafeId'], 'cafe ID'),
      itemId: _identity(data['itemId'], 'item ID'),
      actorUid: _identity(data['actorUid'], 'actor UID'),
      type: type,
      createdAt: _timestamp(data['createdAt']),
      itemName: data['itemName'] is String ? data['itemName'] as String : null,
      quantity: quantity,
      unit: unit is String ? unit : null,
      direction: direction is String ? direction : null,
      previousQuantity: previous,
      resultingQuantity: resulting,
      changedFields: changedFields,
      updated: updated is bool ? updated : null,
      reason: data['reason'] is String && (data['reason'] as String).isNotEmpty
          ? data['reason'] as String
          : null,
    );
  }

  static int _integer(Object? value) {
    if (value is int) return value;
    throw const FormatException('Invalid integer field.');
  }

  static int? _optionalInteger(Object? value) =>
      value == null ? null : _integer(value);

  static int _positiveInteger(Object? value) {
    final integer = _integer(value);
    if (integer < 1) throw const FormatException('Invalid version.');
    return integer;
  }

  static bool _supportedUnit(Object? value) =>
      value is String && const {'kg', 'g', 'L', 'ml', 'pcs'}.contains(value);

  static String _identity(Object? value, String label) {
    if (value is! String ||
        value.trim().isEmpty ||
        value != value.trim() ||
        value.contains('/')) {
      throw FormatException('Invalid $label.');
    }
    return value;
  }

  static String _text(Object? value, String label) {
    if (value is! String || value.trim().isEmpty || value != value.trim()) {
      throw FormatException('Invalid $label.');
    }
    return value;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List || value.any((field) => field is! String)) {
      throw const FormatException('Invalid changed fields.');
    }
    return List<String>.unmodifiable(value.cast<String>());
  }

  static DateTime _timestamp(Object? value) => switch (value) {
    Timestamp timestamp => timestamp.toDate(),
    DateTime date => date,
    _ => throw const FormatException('Invalid activity timestamp.'),
  };
}
