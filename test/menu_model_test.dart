import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/menu_item.dart';

Map<String, dynamic> menuData({
  String id = 'menu-a',
  String cafe = 'cafe-a',
  int version = 1,
  bool archived = false,
}) => {
  'id': id,
  'cafeId': cafe,
  'name': 'Latte',
  'category': 'Coffee',
  'priceMinor': 1250,
  'currency': 'MYR',
  'version': version,
  'isAvailable': true,
  'isArchived': archived,
  'createdBy': 'owner-a',
  'updatedBy': 'owner-a',
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': '2026-01-01T00:00:00.000Z',
};
void main() {
  test('model parses actual callable contract and formats exact sen', () {
    final item = MenuItem.fromMap(menuData());
    expect(item.formattedPrice, 'RM 12.50');
    expect(item.createdAt.isUtc, true);
    expect(item.isArchived, false);
  });
  test('money parser avoids floating point and rejects unsupported input', () {
    for (final pair in {
      '0': 0,
      '0.01': 1,
      '12.5': 1250,
      '10000.00': 1000000,
    }.entries) {
      expect(MenuDraft.parsePrice(pair.key), pair.value);
    }
    for (final text in [
      '-1',
      '1.001',
      '1e2',
      '10000.01',
      'NaN',
      'RM 12',
      '1,20',
      '',
    ]) {
      expect(() => MenuDraft.parsePrice(text), throwsFormatException);
    }
  });
  test('malformed records never receive fabricated defaults', () {
    for (final extra in [
      {'priceMinor': 1.5},
      {'priceMinor': -1},
      {'currency': 'USD'},
      {'isAvailable': 'true'},
      {'isArchived': null},
      {'version': 0},
      {'name': ''},
      {'createdAt': 'bad'},
      {'id': 'a/b'},
      {'createdBy': ''},
    ]) {
      expect(
        () => MenuItem.fromMap({...menuData(), ...extra}),
        throwsFormatException,
      );
    }
  });
  test('draft contains only normalized editable backend fields', () {
    expect(const MenuDraft(' Flat  White ', ' Coffee ', 1200, false).toData(), {
      'name': 'Flat White',
      'category': 'Coffee',
      'priceMinor': 1200,
      'isAvailable': false,
    });
  });
}
