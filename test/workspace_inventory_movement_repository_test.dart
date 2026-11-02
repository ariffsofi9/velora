import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_movement.dart';
import 'package:velora/repositories/workspace_inventory_movement_repository.dart';
import 'package:velora/services/workspace_session.dart';

class _Source implements WorkspaceMovementDataSource {
  List<WorkspaceMovementDocument> documents = const [];
  Object? error;
  String? path;
  String? itemId;
  int? limit;
  bool? descending;
  Object? startAfter;

  @override
  Future<List<WorkspaceMovementDocument>> fetchPage({
    required String path,
    required String itemId,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) async {
    this.path = path;
    this.itemId = itemId;
    this.limit = limit;
    this.descending = descending;
    this.startAfter = startAfter;
    if (error != null) throw error!;
    return documents;
  }
}

WorkspaceSession _session(String cafeId) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafeId,
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

Map<String, dynamic> _initial({
  String cafeId = 'cafe-a',
  String itemId = 'item-a',
  Object? createdAt,
}) => {
  'cafeId': cafeId,
  'itemId': itemId,
  'actorUid': 'staff-a',
  'type': 'initial_stock',
  'quantity': 0,
  'unit': 'kg',
  'requestHash': 'request-hash',
  'createdAt': createdAt ?? DateTime.utc(2030),
};

Map<String, dynamic> _adjustment({
  required String type,
  String cafeId = 'cafe-a',
  String itemId = 'item-a',
  bool optionalFields = true,
}) {
  final stockIn = type == 'stock_in';
  return {
    'cafeId': cafeId,
    'itemId': itemId,
    'actorUid': 'staff-a',
    'type': type,
    'direction': stockIn ? 'in' : 'out',
    'quantity': 2,
    'delta': stockIn ? 2 : -2,
    'previousQuantity': stockIn ? 3 : 5,
    'resultingQuantity': stockIn ? 5 : 3,
    'unit': 'kg',
    'fromVersion': 1,
    'resultVersion': 2,
    if (optionalFields) 'reason': 'Delivery',
    'requestHash': 'request-hash',
    'createdAt': DateTime.utc(2030),
  };
}

WorkspaceMovementDocument _document(String id, Map<String, dynamic> data) =>
    WorkspaceMovementDocument(id: id, data: data, cursorToken: 'cursor-$id');

void main() {
  test(
    'uses verified cafe path, item filter, descending query contract and limit',
    () async {
      final source = _Source()
        ..documents = [_document('movement-a', _initial())];
      final repository = WorkspaceInventoryMovementRepository(
        session: _session('cafe-a'),
        dataSource: source,
      );

      final page = await repository.getItemMovements('item-a');

      expect(source.path, 'cafes/cafe-a/inventory_movements');
      expect(source.itemId, 'item-a');
      expect(source.limit, 20);
    expect(source.descending, isTrue);
      expect(source.startAfter, isNull);
      expect(page.movements.single.type, InventoryMovementType.initialStock);
      expect(page.nextCursor, isNull);
    },
  );

  test(
    'parses initial, stock in, stock out and missing optional fields',
    () async {
      final source = _Source()
        ..documents = [
          _document('initial', _initial()),
          _document('in', _adjustment(type: 'stock_in')),
          _document(
            'out',
            _adjustment(type: 'stock_out', optionalFields: false),
          ),
        ];
      final page = await WorkspaceInventoryMovementRepository(
        session: _session('cafe-a'),
        dataSource: source,
      ).getItemMovements('item-a');

      expect(page.movements[0].quantity, 0);
      expect(page.movements[0].delta, isNull);
      expect(page.movements[1].delta, 2);
      expect(page.movements[1].reason, 'Delivery');
      expect(page.movements[2].delta, -2);
      expect(page.movements[2].reason, isNull);
    },
  );

  test('empty results return an empty page', () async {
    final page = await WorkspaceInventoryMovementRepository(
      session: _session('cafe-a'),
      dataSource: _Source(),
    ).getItemMovements('item-a');
    expect(page.movements, isEmpty);
    expect(page.nextCursor, isNull);
  });

  test(
    'page cursor is forwarded and cannot cross cafe or item scope',
    () async {
      final firstSource = _Source()
        ..documents = List.generate(
          20,
          (index) => _document('movement-$index', _initial()),
        );
      final firstRepository = WorkspaceInventoryMovementRepository(
        session: _session('cafe-a'),
        dataSource: firstSource,
      );
      final firstPage = await firstRepository.getItemMovements('item-a');
      expect(firstPage.nextCursor, isNotNull);

      final secondSource = _Source();
      await firstRepository.getItemMovements(
        'item-a',
        cursor: firstPage.nextCursor,
      );
      expect(firstSource.startAfter, 'cursor-movement-19');

      final otherItemRepository = WorkspaceInventoryMovementRepository(
        session: _session('cafe-a'),
        dataSource: secondSource,
      );
      await expectLater(
        otherItemRepository.getItemMovements(
          'item-b',
          cursor: firstPage.nextCursor,
        ),
        throwsA(
          isA<WorkspaceMovementException>().having(
            (error) => error.failure,
            'failure',
            WorkspaceMovementFailure.invalidData,
          ),
        ),
      );
      final otherCafeRepository = WorkspaceInventoryMovementRepository(
        session: _session('cafe-b'),
        dataSource: secondSource,
      );
      await expectLater(
        otherCafeRepository.getItemMovements(
          'item-a',
          cursor: firstPage.nextCursor,
        ),
        throwsA(
          isA<WorkspaceMovementException>().having(
            (error) => error.failure,
            'failure',
            WorkspaceMovementFailure.invalidData,
          ),
        ),
      );
    },
  );

  test('malformed timestamps, data and scope mismatches fail closed', () async {
    for (final data in [
      _initial(createdAt: 'not-a-timestamp'),
      {..._adjustment(type: 'stock_in'), 'delta': -2},
      _initial(cafeId: 'cafe-b'),
      _initial(itemId: 'item-b'),
    ]) {
      final source = _Source()..documents = [_document('movement-a', data)];
      final repository = WorkspaceInventoryMovementRepository(
        session: _session('cafe-a'),
        dataSource: source,
      );
      await expectLater(
        repository.getItemMovements('item-a'),
        throwsA(
          isA<WorkspaceMovementException>().having(
            (error) => error.failure,
            'failure',
            WorkspaceMovementFailure.invalidData,
          ),
        ),
      );
    }
  });

  test('permission and unavailable errors remain distinguishable', () async {
    final denied = _Source()
      ..error = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
    final unavailable = _Source()..error = StateError('network unavailable');

    for (final entry in [
      (denied, WorkspaceMovementFailure.permissionDenied),
      (unavailable, WorkspaceMovementFailure.unavailable),
    ]) {
      final repository = WorkspaceInventoryMovementRepository(
        session: _session('cafe-a'),
        dataSource: entry.$1,
      );
      await expectLater(
        repository.getItemMovements('item-a'),
        throwsA(
          isA<WorkspaceMovementException>().having(
            (error) => error.failure,
            'failure',
            entry.$2,
          ),
        ),
      );
    }
  });

  test('invalid cafe and item identities are rejected before reads', () async {
    expect(
      () => WorkspaceInventoryMovementRepository(
        session: _session('bad/cafe'),
        dataSource: _Source(),
      ),
      throwsArgumentError,
    );
    final source = _Source();
    final repository = WorkspaceInventoryMovementRepository(
      session: _session('cafe-a'),
      dataSource: source,
    );
    expect(() => repository.getItemMovements('bad/item'), throwsArgumentError);
    expect(source.path, isNull);
  });
}
