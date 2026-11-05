import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/inventory_movement.dart';
import '../services/workspace_session.dart';

class WorkspaceMovementDocument {
  final String id;
  final Map<String, dynamic> data;
  final Object cursorToken;
  const WorkspaceMovementDocument({
    required this.id,
    required this.data,
    required this.cursorToken,
  });
}

class WorkspaceMovementCursor {
  final String _cafeId;
  final String _itemId;
  final Object _token;
  const WorkspaceMovementCursor._(this._cafeId, this._itemId, this._token);
}

class WorkspaceMovementPage {
  final List<InventoryMovement> movements;
  final WorkspaceMovementCursor? nextCursor;
  const WorkspaceMovementPage({required this.movements, this.nextCursor});
}

enum WorkspaceMovementFailure { permissionDenied, unavailable, invalidData }

class WorkspaceMovementException implements Exception {
  final WorkspaceMovementFailure failure;
  const WorkspaceMovementException(this.failure);
}

abstract interface class WorkspaceMovementDataSource {
  Future<List<WorkspaceMovementDocument>> fetchPage({
    required String path,
    required String itemId,
    required int limit,
    required bool descending,
    Object? startAfter,
  });
}

class FirestoreWorkspaceMovementDataSource
    implements WorkspaceMovementDataSource {
  final FirebaseFirestore _firestore;
  FirestoreWorkspaceMovementDataSource({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  @override
  Future<List<WorkspaceMovementDocument>> fetchPage({
    required String path,
    required String itemId,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) async {
    Query<Map<String, dynamic>> query = _firestore
        .collection(path)
        .where('itemId', isEqualTo: itemId)
        .orderBy('createdAt', descending: descending)
        .limit(limit);
    if (startAfter != null) {
      if (startAfter is! DocumentSnapshot<Map<String, dynamic>>) {
        throw const WorkspaceMovementException(
          WorkspaceMovementFailure.invalidData,
        );
      }
      query = query.startAfterDocument(startAfter);
    }
    final snapshot = await query.get(const GetOptions(source: Source.server));
    return snapshot.docs
        .map(
          (doc) => WorkspaceMovementDocument(
            id: doc.id,
            data: doc.data(),
            cursorToken: doc,
          ),
        )
        .toList(growable: false);
  }
}

abstract interface class WorkspaceInventoryMovementReader {
  Future<WorkspaceMovementPage> getItemMovements(
    String itemId, {
    WorkspaceMovementCursor? cursor,
  });
}

class WorkspaceInventoryMovementRepository
    implements WorkspaceInventoryMovementReader {
  static const pageSize = 20;
  final WorkspaceSession session;
  final WorkspaceMovementDataSource _dataSource;

  WorkspaceInventoryMovementRepository({
    required this.session,
    WorkspaceMovementDataSource? dataSource,
  }) : _dataSource = dataSource ?? FirestoreWorkspaceMovementDataSource() {
    _validateId(session.cafeId, 'workspace');
  }

  String get collectionPath => 'cafes/${session.cafeId}/inventory_movements';

  @override
  Future<WorkspaceMovementPage> getItemMovements(
    String itemId, {
    WorkspaceMovementCursor? cursor,
  }) async {
    _validateId(itemId, 'item');
    if (cursor != null &&
        (cursor._cafeId != session.cafeId || cursor._itemId != itemId)) {
      throw const WorkspaceMovementException(
        WorkspaceMovementFailure.invalidData,
      );
    }
    session.requireActive();
    try {
      final documents = await _dataSource.fetchPage(
        path: collectionPath,
        itemId: itemId,
        limit: pageSize,
        descending: true,
        startAfter: cursor?._token,
      );
      session.requireActive();
      final movements = documents
          .map((document) {
            final movement = InventoryMovement.fromMap(
              document.id,
              document.data,
            );
            if (movement.cafeId != session.cafeId ||
                movement.itemId != itemId) {
              throw const FormatException('Movement scope mismatch.');
            }
            return movement;
          })
          .toList(growable: false);
      final nextCursor = documents.length == pageSize
          ? WorkspaceMovementCursor._(
              session.cafeId,
              itemId,
              documents.last.cursorToken,
            )
          : null;
      return WorkspaceMovementPage(
        movements: movements,
        nextCursor: nextCursor,
      );
    } on FirebaseException catch (error) {
      throw WorkspaceMovementException(
        error.code == 'permission-denied'
            ? WorkspaceMovementFailure.permissionDenied
            : WorkspaceMovementFailure.unavailable,
      );
    } on WorkspaceMovementException {
      rethrow;
    } on FormatException {
      throw const WorkspaceMovementException(
        WorkspaceMovementFailure.invalidData,
      );
    } catch (_) {
      throw const WorkspaceMovementException(
        WorkspaceMovementFailure.unavailable,
      );
    }
  }

  static void _validateId(String value, String label) {
    if (value.trim().isEmpty || value != value.trim() || value.contains('/')) {
      throw ArgumentError.value(value, label, 'Invalid identity');
    }
  }
}
