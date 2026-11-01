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
    return InventoryItem.fromMap(doc.id, doc.data() as Map<String, dynamic>);
  }

  factory InventoryItem.fromMap(String id, Map<String, dynamic> data) =>
      InventoryItem(
        id: id,
        name: data['name'] as String? ?? '',
        category: data['category'] as String? ?? '',
        quantity: data['quantity'] as int? ?? 0,
        unit: _unit(data['unit']),
        expiryDate: _date(data['expiryDate']),
        imageUrl: data['imageUrl'] as String? ?? '',
        createdAt: _date(data['createdAt']),
        version: _version(data),
      );

  static int _version(Map<String, dynamic> data) {
    if (!data.containsKey('version')) return 1;
    final value = data['version'];
    if (value is int && value >= 1) return value;
    throw const FormatException('Invalid inventory item version.');
  }

  static DateTime _date(Object? value) => switch (value) {
    Timestamp timestamp => timestamp.toDate(),
    DateTime date => date,
    _ => DateTime.fromMillisecondsSinceEpoch(0),
  };

  static String _unit(Object? value) {
    const supported = {'kg', 'g', 'L', 'ml', 'pcs'};
    return value is String && supported.contains(value) ? value : 'pcs';
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
