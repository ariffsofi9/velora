import 'package:cloud_firestore/cloud_firestore.dart';

abstract interface class WorkspaceReader {
  Future<Map<String, dynamic>?> readDocument(String path);
}

abstract interface class WorkspaceStore {
  Future<T> readTransaction<T>(Future<T> Function(WorkspaceReader reader) read);
}

/// Read-only server transaction: offline or denied reads fail closed.
class FirestoreWorkspaceStore implements WorkspaceStore {
  final FirebaseFirestore firestore;
  final Duration timeout;
  final int maxAttempts;
  FirestoreWorkspaceStore({
    FirebaseFirestore? firestore,
    this.timeout = const Duration(seconds: 30),
    this.maxAttempts = 5,
  }) : firestore = firestore ?? FirebaseFirestore.instance;

  @override
  Future<T> readTransaction<T>(
    Future<T> Function(WorkspaceReader reader) read,
  ) => firestore.runTransaction(
    (transaction) => read(_FirestoreWorkspaceReader(firestore, transaction)),
    timeout: timeout,
    maxAttempts: maxAttempts,
  );
}

class _FirestoreWorkspaceReader implements WorkspaceReader {
  final FirebaseFirestore firestore;
  final Transaction transaction;
  _FirestoreWorkspaceReader(this.firestore, this.transaction);

  @override
  Future<Map<String, dynamic>?> readDocument(String path) async =>
      (await transaction.get(firestore.doc(path))).data();
}
