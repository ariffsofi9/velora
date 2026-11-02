import 'package:cloud_firestore/cloud_firestore.dart';

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
    };
  }
}
