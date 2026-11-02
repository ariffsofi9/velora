import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/workspace_activity.dart';
import '../services/workspace_session.dart';

class WorkspaceActivityDocument {
  final String id;
  final Map<String, dynamic> data;
  final Object cursorToken;
  const WorkspaceActivityDocument({
    required this.id,
    required this.data,
    required this.cursorToken,
  });
}

class WorkspaceActivityCursor {
  final String _cafeId;
  final Object _token;
  const WorkspaceActivityCursor._(this._cafeId, this._token);
}

class WorkspaceActivityPage {
  final List<WorkspaceActivity> activities;
  final WorkspaceActivityCursor? nextCursor;
  const WorkspaceActivityPage({required this.activities, this.nextCursor});
}

enum WorkspaceActivityFailure { permissionDenied, unavailable, invalidData }

class WorkspaceActivityException implements Exception {
  final WorkspaceActivityFailure failure;
  const WorkspaceActivityException(this.failure);
}

abstract interface class WorkspaceActivityDataSource {
  Future<List<WorkspaceActivityDocument>> fetchPage({
    required String path,
    required int limit,
    required bool descending,
    Object? startAfter,
  });
}

class FirestoreWorkspaceActivityDataSource
    implements WorkspaceActivityDataSource {
  final FirebaseFirestore _firestore;
  FirestoreWorkspaceActivityDataSource({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  @override
  Future<List<WorkspaceActivityDocument>> fetchPage({
    required String path,
    required int limit,
    required bool descending,
    Object? startAfter,
  }) async {
    Query<Map<String, dynamic>> query = _firestore
        .collection(path)
        .orderBy('createdAt', descending: descending)
        .limit(limit);
    if (startAfter != null) {
      if (startAfter is! DocumentSnapshot<Map<String, dynamic>>) {
        throw const WorkspaceActivityException(
          WorkspaceActivityFailure.invalidData,
        );
      }
      query = query.startAfterDocument(startAfter);
    }
    final snapshot = await query.get();
    return snapshot.docs
        .map(
          (doc) => WorkspaceActivityDocument(
            id: doc.id,
            data: doc.data(),
            cursorToken: doc,
          ),
        )
        .toList(growable: false);
  }
}

abstract interface class WorkspaceActivityReader {
  Future<WorkspaceActivityPage> getActivities({
    WorkspaceActivityCursor? cursor,
  });
}

class WorkspaceActivityRepository implements WorkspaceActivityReader {
  static const pageSize = 20;
  final WorkspaceSession session;
  final WorkspaceActivityDataSource _dataSource;

  WorkspaceActivityRepository({
    required this.session,
    WorkspaceActivityDataSource? dataSource,
  }) : _dataSource = dataSource ?? FirestoreWorkspaceActivityDataSource();

  String get collectionPath => 'cafes/${session.cafeId}/activities';

  @override
  Future<WorkspaceActivityPage> getActivities({
    WorkspaceActivityCursor? cursor,
  }) async {
    if (cursor != null && cursor._cafeId != session.cafeId) {
      throw const WorkspaceActivityException(
        WorkspaceActivityFailure.invalidData,
      );
    }
    try {
      final documents = await _dataSource.fetchPage(
        path: collectionPath,
        limit: pageSize,
        descending: true,
        startAfter: cursor?._token,
      );
      final activities = documents
          .map((document) {
            final activity = WorkspaceActivity.fromMap(
              document.id,
              document.data,
            );
            if (activity.cafeId != session.cafeId) {
              throw const FormatException('Activity scope mismatch.');
            }
            return activity;
          })
          .toList(growable: false);
      return WorkspaceActivityPage(
        activities: activities,
        nextCursor: documents.length == pageSize
            ? WorkspaceActivityCursor._(
                session.cafeId,
                documents.last.cursorToken,
              )
            : null,
      );
    } on FirebaseException catch (error) {
      throw WorkspaceActivityException(
        error.code == 'permission-denied'
            ? WorkspaceActivityFailure.permissionDenied
            : WorkspaceActivityFailure.unavailable,
      );
    } on WorkspaceActivityException {
      rethrow;
    } on FormatException {
      throw const WorkspaceActivityException(
        WorkspaceActivityFailure.invalidData,
      );
    } catch (_) {
      throw const WorkspaceActivityException(
        WorkspaceActivityFailure.unavailable,
      );
    }
  }
}
