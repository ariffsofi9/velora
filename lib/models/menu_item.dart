class MenuItem {
  final String id, cafeId, name, category, createdBy, updatedBy;
  final int priceMinor, version;
  final bool isAvailable, isArchived;
  final DateTime createdAt, updatedAt;
  const MenuItem({
    required this.id,
    required this.cafeId,
    required this.name,
    required this.category,
    required this.priceMinor,
    required this.version,
    required this.isAvailable,
    required this.isArchived,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    required this.updatedBy,
  });

  static bool validId(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 128 &&
      value.trim() == value &&
      value != '.' &&
      value != '..' &&
      !RegExp(r'[\\/\x00-\x1f\x7f-\x9f]').hasMatch(value);
  static bool validText(Object? value, int max) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.trim() == value &&
      value.length <= max &&
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);
  static bool validPrice(Object? value) =>
      value is int && value >= 0 && value <= 1000000;
  static bool validVersion(Object? value) =>
      value is int && value >= 1 && value <= 9007199254740991;
  factory MenuItem.fromMap(Map<String, dynamic> data) {
    DateTime date(Object? value) {
      final parsed = value is String ? DateTime.tryParse(value) : null;
      if (parsed == null ||
          !parsed.isUtc ||
          parsed.toIso8601String() != value) {
        throw const FormatException('Invalid menu data.');
      }
      return parsed;
    }

    if (!validId(data['id']) ||
        !validId(data['cafeId']) ||
        !validText(data['name'], 100) ||
        !validText(data['category'], 60) ||
        !validPrice(data['priceMinor']) ||
        !validVersion(data['version']) ||
        data['currency'] != 'MYR' ||
        data['isAvailable'] is! bool ||
        data['isArchived'] is! bool ||
        !validId(data['createdBy']) ||
        !validId(data['updatedBy'])) {
      throw const FormatException('Invalid menu data.');
    }
    return MenuItem(
      id: data['id'],
      cafeId: data['cafeId'],
      name: data['name'],
      category: data['category'],
      priceMinor: data['priceMinor'],
      version: data['version'],
      isAvailable: data['isAvailable'],
      isArchived: data['isArchived'],
      createdAt: date(data['createdAt']),
      updatedAt: date(data['updatedAt']),
      createdBy: data['createdBy'],
      updatedBy: data['updatedBy'],
    );
  }
  String get formattedPrice =>
      'RM ${priceMinor ~/ 100}.${(priceMinor % 100).toString().padLeft(2, '0')}';
}

class MenuDraft {
  final String name, category;
  final int priceMinor;
  final bool isAvailable;
  const MenuDraft(this.name, this.category, this.priceMinor, this.isAvailable);
  Map<String, Object> toData() {
    final cleanName = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    final cleanCategory = category.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (!MenuItem.validText(name.trim(), 100) ||
        !MenuItem.validText(category.trim(), 60) ||
        !MenuItem.validPrice(priceMinor)) {
      throw const FormatException('Invalid menu fields.');
    }
    return {
      'name': cleanName,
      'category': cleanCategory,
      'priceMinor': priceMinor,
      'isAvailable': isAvailable,
    };
  }

  static int parsePrice(String input) {
    final value = input.trim();
    if (!RegExp(r'^\d{1,5}(\.\d{1,2})?$').hasMatch(value)) {
      throw const FormatException(
        'Enter an RM price with at most two decimal places.',
      );
    }
    final parts = value.split('.');
    final minor =
        int.parse(parts[0]) * 100 +
        int.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
    if (!MenuItem.validPrice(minor)) {
      throw const FormatException(
        'Price must be between RM 0.00 and RM 10000.00.',
      );
    }
    return minor;
  }
}
