import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/services/workspace_session.dart';

class _DataSource implements WorkspaceInventoryDataSource {
  String? watchedPath;
  String? readPath;
  Stream<List<WorkspaceInventoryDocument>> watched = const Stream.empty();
  Future<List<WorkspaceInventoryDocument>> Function()? read;

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) {
    readPath = path;
    return read?.call() ?? Future.value(const []);
  }

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watchedPath = path;
    return watched;
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

WorkspaceInventoryDocument _item({String? unit}) {
  final data = <String, dynamic>{
    'name': 'Milk',
    'category': 'Dairy',
    'quantity': 2,
    'expiryDate': DateTime(2030),
    'imageUrl': '',
    'createdAt': DateTime(2029),
  };
  if (unit != null) data['unit'] = unit;
  return WorkspaceInventoryDocument(id: 'item-a', data: data);
}

void main() {
  test('reads only the verified cafe inventory path', () async {
    final source = _DataSource()..read = () async => [_item(unit: 'L')];
    final repository = WorkspaceInventoryRepository(
      session: _session('cafe-a'),
      dataSource: source,
    );

    final items = await repository.getItems();

    expect(source.readPath, 'cafes/cafe-a/inventory');
    expect(items.single.unit, 'L');
  });

  test('legacy item without unit defaults to pcs', () async {
    final source = _DataSource()..read = () async => [_item()];
    final repository = WorkspaceInventoryRepository(
      session: _session('cafe-a'),
      dataSource: source,
    );

    expect((await repository.getItems()).single.unit, 'pcs');
  });

  test('empty cafe returns an empty inventory list', () async {
    final source = _DataSource();
    final repository = WorkspaceInventoryRepository(
      session: _session('empty-cafe'),
      dataSource: source,
    );

    expect(await repository.getItems(), isEmpty);
  });

  test('stream uses only the verified cafe path', () async {
    final source = _DataSource()..watched = Stream.value([_item(unit: 'kg')]);
    final repository = WorkspaceInventoryRepository(
      session: _session('cafe-a'),
      dataSource: source,
    );

    final items = await repository.watchItems().first;

    expect(source.watchedPath, 'cafes/cafe-a/inventory');
    expect(items.single.unit, 'kg');
  });

  test('permission errors remain failures and never become empty data', () {
    final source = _DataSource()
      ..read = () => Future.error(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      );
    final repository = WorkspaceInventoryRepository(
      session: _session('cafe-a'),
      dataSource: source,
    );

    expect(
      repository.getItems(),
      throwsA(
        isA<FirebaseException>().having(
          (error) => error.code,
          'code',
          'permission-denied',
        ),
      ),
    );
  });
}
