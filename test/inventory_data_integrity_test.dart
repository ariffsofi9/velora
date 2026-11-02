import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/logic/inventory_expiry_policy.dart';
import 'package:velora/logic/suggestion_helper.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/utils_inventory/inventory_sort_helper.dart';
import 'package:velora/services/workspace_session.dart';

class _Source implements WorkspaceInventoryDataSource {
  final List<WorkspaceInventoryDocument> documents;

  const _Source(this.documents);

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async =>
      documents;

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) =>
      Stream.value(documents);
}

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'cafe-a',
    uid: 'owner-a',
    ownerUid: 'owner-a',
    role: CafeRole.owner,
  ),
);

Map<String, dynamic> _validData() => {
  'name': 'Milk',
  'category': 'Dairy',
  'quantity': 2,
  'unit': 'L',
  'expiryDate': DateTime(2030, 1, 2),
  'imageUrl': '',
  'createdAt': DateTime(2029, 12, 1),
  'schemaVersion': 1,
  'version': 1,
};

InventoryItem _expiryItem(String id, DateTime expiryDate) => InventoryItem(
  id: id,
  name: id,
  category: 'General',
  quantity: 1,
  expiryDate: expiryDate,
  imageUrl: '',
  createdAt: DateTime(2029),
);

void main() {
  group('InventoryExpiryPolicy', () {
    final now = DateTime(2030, 6, 10, 23, 59, 59);

    test('uses calendar days across today tomorrow and expired boundaries', () {
      expect(
        InventoryExpiryPolicy.daysUntil(DateTime(2030, 6, 10, 0, 1), now: now),
        0,
      );
      expect(
        InventoryExpiryPolicy.daysUntil(DateTime(2030, 6, 11, 0, 1), now: now),
        1,
      );
      expect(
        InventoryExpiryPolicy.daysUntil(DateTime(2030, 6, 9, 23, 59), now: now),
        -1,
      );
      expect(
        InventoryExpiryPolicy.label(DateTime(2030, 6, 10), now: now),
        'Expires today',
      );
      expect(
        InventoryExpiryPolicy.label(DateTime(2030, 6, 11), now: now),
        'Expires tomorrow',
      );
    });

    test('near-expiry includes days zero through three, never expired', () {
      for (final offset in [0, 1, 2, 3]) {
        expect(
          InventoryExpiryPolicy.isNearExpiry(
            DateTime(2030, 6, 10 + offset),
            now: now,
          ),
          isTrue,
        );
      }
      expect(
        InventoryExpiryPolicy.isNearExpiry(DateTime(2030, 6, 14), now: now),
        isFalse,
      );
      expect(
        InventoryExpiryPolicy.isNearExpiry(DateTime(2030, 6, 9), now: now),
        isFalse,
      );
      expect(
        InventoryExpiryPolicy.isExpired(DateTime(2030, 6, 9), now: now),
        isTrue,
      );
    });

    test('Inventory and AI helpers share the same near-expiry boundary', () {
      final today = InventoryExpiryPolicy.calendarDate(DateTime.now());
      final items = [
        _expiryItem('expired', today.subtract(const Duration(days: 1))),
        _expiryItem('today', today),
        _expiryItem('day-three', today.add(const Duration(days: 3))),
        _expiryItem('day-four', today.add(const Duration(days: 4))),
      ];

      final inventory = InventorySortHelper.filterItems(items, 'Near Expiry');
      final ai = SuggestionHelper().nearExpiryItems(items);

      expect(inventory.map((item) => item.id), ['today', 'day-three']);
      expect(ai.map((item) => item.id), ['today', 'day-three']);
    });
  });

  group('InventoryItem parsing', () {
    test(
      'accepts current schema and legitimate missing unit/version legacy data',
      () {
        final current = InventoryItem.fromMap('item-a', _validData());
        expect(current.unit, 'L');

        final legacyData = _validData()
          ..remove('unit')
          ..remove('version')
          ..remove('schemaVersion');
        final legacy = InventoryItem.fromMap('legacy-a', legacyData);
        expect(legacy.unit, 'pcs');
        expect(legacy.version, 1);
      },
    );

    test('preserves the canonical UTC expiry date from Firestore', () {
      final data = _validData()
        ..['expiryDate'] = Timestamp.fromDate(DateTime.utc(2030, 1, 2));

      final item = InventoryItem.fromMap('item-a', data);

      expect(item.expiryDate.isUtc, isTrue);
      expect(item.expiryDate, DateTime.utc(2030, 1, 2));
    });

    test('rejects malformed required fields and unsupported schema', () {
      final invalid = <Map<String, dynamic>>[
        {..._validData(), 'name': ''},
        {..._validData(), 'category': null},
        {..._validData(), 'quantity': -1},
        {..._validData(), 'quantity': 1.5},
        {..._validData(), 'unit': 'box'},
        {..._validData(), 'expiryDate': '2030-01-02'},
        {..._validData(), 'createdAt': null},
        {..._validData(), 'schemaVersion': 2},
      ];

      for (final data in invalid) {
        expect(
          () => InventoryItem.fromMap('item-a', data),
          throwsFormatException,
        );
      }
    });

    test('repository replaces parsing details with a safe data error', () {
      final repository = WorkspaceInventoryRepository(
        session: _session,
        dataSource: _Source([
          WorkspaceInventoryDocument(
            id: 'bad-item',
            data: {..._validData(), 'quantity': 'two'},
          ),
        ]),
      );

      expect(
        repository.getItems(),
        throwsA(isA<WorkspaceInventoryDataException>()),
      );
    });
  });
}
