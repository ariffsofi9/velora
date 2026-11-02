import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/inventory_item.dart';
import '../services/workspace_session.dart';

class WorkspaceInventoryDocument {
  final String id;
  final Map<String, dynamic> data;

  const WorkspaceInventoryDocument({required this.id, required this.data});
}

class WorkspaceInventoryDataException implements Exception {
  const WorkspaceInventoryDataException();

  @override
  String toString() => 'Workspace inventory data is invalid.';
}

abstract interface class WorkspaceInventoryDataSource {
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path);
  Future<List<WorkspaceInventoryDocument>> readCollection(String path);
}

class FirestoreWorkspaceInventoryDataSource
    implements WorkspaceInventoryDataSource {
  final FirebaseFirestore _firestore;

  FirestoreWorkspaceInventoryDataSource({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) =>
      _firestore.collection(path).snapshots().map(_documents);

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async =>
      _documents(await _firestore.collection(path).get());

  List<WorkspaceInventoryDocument> _documents(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) => snapshot.docs
      .map((doc) => WorkspaceInventoryDocument(id: doc.id, data: doc.data()))
      .toList(growable: false);
}

/// Read-only inventory access scoped to a resolver-verified workspace.
class WorkspaceInventoryRepository {
  final WorkspaceSession session;
  final WorkspaceInventoryDataSource _dataSource;

  WorkspaceInventoryRepository({
    required this.session,
    WorkspaceInventoryDataSource? dataSource,
  }) : _dataSource = dataSource ?? FirestoreWorkspaceInventoryDataSource();

  String get collectionPath => 'cafes/${session.cafeId}/inventory';

  Stream<List<InventoryItem>> watchItems() => _dataSource
      .watchCollection(collectionPath)
      .map((documents) => _items(documents, archived: false));

  Stream<List<InventoryItem>> watchArchivedItems() => _dataSource
      .watchCollection(collectionPath)
      .map((documents) => _items(documents, archived: true));

  Future<List<InventoryItem>> getItems() async =>
      _items(await _dataSource.readCollection(collectionPath), archived: false);

  List<InventoryItem> _items(
    List<WorkspaceInventoryDocument> documents, {
    required bool archived,
  }) {
    try {
      return documents
          .map((doc) => InventoryItem.fromMap(doc.id, doc.data))
          .where((item) => item.isArchived == archived)
          .toList(growable: false);
    } on FormatException {
      throw const WorkspaceInventoryDataException();
    }
  }
}
