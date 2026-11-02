import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/workspace_activity.dart';
import 'package:velora/repositories/workspace_activity_repository.dart';
import 'package:velora/services/workspace_session.dart';

class _Source implements WorkspaceActivityDataSource {
  List<WorkspaceActivityDocument> documents = const [];
  Object? error;
  String? path;
  int? limit;
  bool? descending;
  Object? startAfter;

  @override
  Future<List<WorkspaceActivityDocument>> fetchPage({
    required String path,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) async {
    this.path = path;
    this.limit = limit;
    this.descending = descending;
    this.startAfter = startAfter;
    if (error != null) throw error!;
    return documents;
  }
}

class _PagedSource implements WorkspaceActivityDataSource {
  final List<WorkspaceActivityDocument> documents;
  _PagedSource(this.documents);

  @override
  Future<List<WorkspaceActivityDocument>> fetchPage({
    required String path,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) async {
    expect(path, 'cafes/cafe-a/activities');
    expect(descending, isTrue);
    final start = startAfter == null
        ? 0
        : documents.indexWhere((doc) => doc.cursorToken == startAfter) + 1;
    return documents.skip(start).take(limit).toList(growable: false);
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

Map<String, dynamic> _created({
  String cafeId = 'cafe-a',
  DateTime? createdAt,
}) => {
  'cafeId': cafeId,
  'itemId': 'item-a',
  'actorUid': 'staff-a',
  'type': 'inventory_created',
  'itemName': 'Milk',
  'quantity': 2,
  'unit': 'L',
  'requestHash': 'request-hash',
  'schemaVersion': 1,
  'createdAt': createdAt ?? DateTime.utc(2030),
};

Map<String, dynamic> _updated({bool changed = true}) => {
  'cafeId': 'cafe-a',
  'itemId': 'item-a',
  'actorUid': 'staff-a',
  'type': changed ? 'inventory_updated' : 'inventory_update_noop',
  'changedFields': changed ? ['name'] : <String>[],
  'fromVersion': 1,
  'resultVersion': changed ? 2 : 1,
  'updated': changed,
  'requestHash': 'request-hash',
  'schemaVersion': 1,
  'createdAt': DateTime.utc(2030),
};

Map<String, dynamic> _stock() => {
  'cafeId': 'cafe-a',
  'itemId': 'item-a',
  'actorUid': 'staff-a',
  'type': 'inventory_stock_adjusted',
  'direction': 'out',
  'quantity': 2,
  'previousQuantity': 5,
  'resultingQuantity': 3,
  'unit': 'L',
  'fromVersion': 1,
  'resultVersion': 2,
  'requestHash': 'request-hash',
  'schemaVersion': 1,
  'createdAt': DateTime.utc(2030),
};

WorkspaceActivityDocument _document(String id, Map<String, dynamic> data) =>
    WorkspaceActivityDocument(id: id, data: data, cursorToken: 'cursor-$id');

void main() {
  test('strict model accepts only supported verified audit schemas', () {
    expect(
      WorkspaceActivity.fromMap('created', _created()).type,
      WorkspaceActivityType.inventoryCreated,
    );
    expect(
      WorkspaceActivity.fromMap('updated', _updated()).type,
      WorkspaceActivityType.inventoryUpdated,
    );
    expect(
      WorkspaceActivity.fromMap('noop', _updated(changed: false)).type,
      WorkspaceActivityType.inventoryUpdateNoop,
    );
    expect(WorkspaceActivity.fromMap('stock', _stock()).resultingQuantity, 3);
  });

  test('strict model rejects unsupported and inconsistent records', () {
    expect(
      () =>
          WorkspaceActivity.fromMap('bad', {..._created(), 'type': 'unknown'}),
      throwsFormatException,
    );
    expect(
      () => WorkspaceActivity.fromMap('bad', {
        ..._stock(),
        'resultingQuantity': 4,
      }),
      throwsFormatException,
    );
    expect(
      () =>
          WorkspaceActivity.fromMap('bad', {..._created(), 'createdAt': null}),
      throwsFormatException,
    );
  });

  test(
    'uses verified cafe path, descending order and bounded page size',
    () async {
      final source = _Source()..documents = [_document('a', _created())];
      final page = await WorkspaceActivityRepository(
        session: _session('cafe-a'),
        dataSource: source,
      ).getActivities();

      expect(source.path, 'cafes/cafe-a/activities');
      expect(source.limit, 20);
      expect(source.descending, isTrue);
      expect(source.startAfter, isNull);
      expect(page.activities.single.id, 'a');
    },
  );

  test('paginates 21 records without duplicates and detects the end', () async {
    final documents = List.generate(
      21,
      (index) => _document(
        'activity-${index.toString().padLeft(2, '0')}',
        _created(
          createdAt: DateTime.utc(2030).subtract(Duration(minutes: index)),
        ),
      ),
    );
    final repository = WorkspaceActivityRepository(
      session: _session('cafe-a'),
      dataSource: _PagedSource(documents),
    );
    final first = await repository.getActivities();
    final second = await repository.getActivities(cursor: first.nextCursor);

    expect(first.activities, hasLength(20));
    expect(second.activities, hasLength(1));
    expect(second.nextCursor, isNull);
    expect({
      ...first.activities.map((item) => item.id),
      ...second.activities.map((item) => item.id),
    }, hasLength(21));
  });

  test('cross-cafe records and cursors fail closed', () async {
    final source = _Source()
      ..documents = List.generate(
        20,
        (index) => _document('$index', _created()),
      );
    final firstRepository = WorkspaceActivityRepository(
      session: _session('cafe-a'),
      dataSource: source,
    );
    final first = await firstRepository.getActivities();

    await expectLater(
      WorkspaceActivityRepository(
        session: _session('cafe-b'),
        dataSource: _Source(),
      ).getActivities(cursor: first.nextCursor),
      throwsA(
        isA<WorkspaceActivityException>().having(
          (error) => error.failure,
          'failure',
          WorkspaceActivityFailure.invalidData,
        ),
      ),
    );

    source.documents = [_document('wrong', _created(cafeId: 'cafe-b'))];
    await expectLater(
      firstRepository.getActivities(),
      throwsA(isA<WorkspaceActivityException>()),
    );
  });

  test(
    'permission and network failures remain sanitized and distinct',
    () async {
      final source = _Source()
        ..error = FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
        );
      final repository = WorkspaceActivityRepository(
        session: _session('cafe-a'),
        dataSource: source,
      );
      await expectLater(
        repository.getActivities(),
        throwsA(
          isA<WorkspaceActivityException>().having(
            (error) => error.failure,
            'failure',
            WorkspaceActivityFailure.permissionDenied,
          ),
        ),
      );

      source.error = StateError('offline details');
      await expectLater(
        repository.getActivities(),
        throwsA(
          isA<WorkspaceActivityException>().having(
            (error) => error.failure,
            'failure',
            WorkspaceActivityFailure.unavailable,
          ),
        ),
      );
    },
  );
}
