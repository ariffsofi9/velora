import 'package:cloud_firestore/cloud_firestore.dart';

enum InventoryLifecycleState { active, archived }

class InventoryItem {
  final String id;
  final String name;
  final String category;
  final int quantity;
  final String unit;
  final DateTime expiryDate;
  final String imageUrl;
  final DateTime createdAt;
  final int version;
  final InventoryLifecycleState lifecycleState;
  final DateTime? archivedAt;
  final String? archivedBy;

  InventoryItem({
    required this.id,
    required this.name,
    required this.category,
    required this.quantity,
    this.unit = 'pcs',
    required this.expiryDate,
    required this.imageUrl,
    required this.createdAt,
    this.version = 1,
    this.lifecycleState = InventoryLifecycleState.active,
    this.archivedAt,
    this.archivedBy,
  });

  factory InventoryItem.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data();
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid inventory item data.');
    }
    return InventoryItem.fromMap(doc.id, data);
  }

  factory InventoryItem.fromMap(String id, Map<String, dynamic> data) {
    _validateId(id);
    _validateSchema(data);
    final imageUrl = data['imageUrl'];
    if (imageUrl != null && imageUrl is! String) {
      throw const FormatException('Invalid inventory item image URL.');
    }
    final lifecycleState = _lifecycle(data);
    final archivedAt = _optionalDate(data['archivedAt']);
    final archivedBy = _optionalIdentity(data['archivedBy']);
    if (lifecycleState == InventoryLifecycleState.archived &&
        (archivedAt == null || archivedBy == null)) {
      throw const FormatException('Archived inventory metadata is incomplete.');
    }
    if (lifecycleState == InventoryLifecycleState.active &&
        (archivedAt != null || archivedBy != null)) {
      throw const FormatException('Active inventory has archive metadata.');
    }

    return InventoryItem(
      id: id,
      name: _requiredText(data['name'], maxLength: 100),
      category: _requiredText(data['category'], maxLength: 60),
      quantity: _quantity(data['quantity']),
      unit: _unit(data),
      expiryDate: _requiredExpiryDate(data['expiryDate']),
      imageUrl: imageUrl as String? ?? '',
      createdAt: _requiredDate(data['createdAt']),
      version: _version(data),
      lifecycleState: lifecycleState,
      archivedAt: archivedAt,
      archivedBy: archivedBy,
    );
  }

  static void _validateId(String id) {
    if (id.isEmpty || id.trim() != id || id.contains('/') || id.length > 128) {
      throw const FormatException('Invalid inventory item identifier.');
    }
  }

  static void _validateSchema(Map<String, dynamic> data) {
    if (!data.containsKey('schemaVersion')) return;
    if (data['schemaVersion'] != 1) {
      throw const FormatException('Unsupported inventory item schema.');
    }
  }

  static String _requiredText(Object? value, {required int maxLength}) {
    if (value is! String ||
        value.isEmpty ||
        value.trim() != value ||
        value.length > maxLength ||
        value.codeUnits.any((code) => code < 32 || code == 127)) {
      throw const FormatException('Invalid required inventory text.');
    }
    return value;
  }

  static int _quantity(Object? value) {
    if (value is int && value >= 0) return value;
    throw const FormatException('Invalid inventory item quantity.');
  }

  static int _version(Map<String, dynamic> data) {
    if (!data.containsKey('version')) return 1;
    final value = data['version'];
    if (value is int && value >= 1) return value;
    throw const FormatException('Invalid inventory item version.');
  }

  static DateTime _requiredDate(Object? value) => switch (value) {
    Timestamp timestamp => timestamp.toDate(),
    DateTime date => date,
    _ => throw const FormatException('Invalid inventory item timestamp.'),
  };

  static DateTime? _optionalDate(Object? value) => switch (value) {
    null => null,
    Timestamp timestamp => timestamp.toDate(),
    DateTime date => date,
    _ => throw const FormatException('Invalid archive timestamp.'),
  };

  static String? _optionalIdentity(Object? value) {
    if (value == null) return null;
    if (value is String &&
        value.isNotEmpty &&
        value.trim() == value &&
        !value.contains('/')) {
      return value;
    }
    throw const FormatException('Invalid archive actor.');
  }

  static InventoryLifecycleState _lifecycle(Map<String, dynamic> data) {
    if (!data.containsKey('lifecycleState')) {
      return InventoryLifecycleState.active;
    }
    return switch (data['lifecycleState']) {
      'active' => InventoryLifecycleState.active,
      'archived' => InventoryLifecycleState.archived,
      _ => throw const FormatException('Invalid inventory lifecycle.'),
    };
  }

  bool get isArchived => lifecycleState == InventoryLifecycleState.archived;

  // Trusted callables persist expiry as UTC midnight. Preserve those UTC date
  // components instead of allowing the viewer's timezone to shift the date.
  static DateTime _requiredExpiryDate(Object? value) => switch (value) {
    Timestamp timestamp => timestamp.toDate().toUtc(),
    DateTime date => date,
    _ => throw const FormatException('Invalid inventory item expiry date.'),
  };

  static String _unit(Map<String, dynamic> data) {
    if (!data.containsKey('unit')) return 'pcs';
    final value = data['unit'];
    const supported = {'kg', 'g', 'L', 'ml', 'pcs'};
    if (value is String && supported.contains(value)) return value;
    throw const FormatException('Invalid inventory item unit.');
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'category': category,
      'quantity': quantity,
      'unit': unit,
      'expiryDate': expiryDate,
      'imageUrl': imageUrl,
      'createdAt': createdAt,
      'version': version,
      'lifecycleState': lifecycleState.name,
      if (archivedAt != null) 'archivedAt': archivedAt,
      if (archivedBy != null) 'archivedBy': archivedBy,
    };
  }
}
