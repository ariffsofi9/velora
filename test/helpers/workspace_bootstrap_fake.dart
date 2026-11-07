import 'package:velora/services/workspace_provisioning_service.dart';

/// Offline optimistic transaction model, not a Rules emulator.
class BootstrapFake implements WorkspaceBootstrapStore {
  final Map<String, Map<String, dynamic>> docs = {};
  int calls = 0, ids = 0, callbacks = 0, commits = 0, revision = 0;
  bool retryOnce = false;
  Object? error, afterCommitError;
  bool rejectExistingWrites = false;
  void Function()? beforeCommit;
  Future<void> Function()? onRead;
  @override
  String newCafeId() => 'cafe-${++ids}';
  @override
  Object serverTimestamp() => 'server-time';
  @override
  Future<T> runTransaction<T>(
    Future<T> Function(WorkspaceBootstrapTransaction) action,
  ) async {
    calls++;
    for (var attempt = 0; attempt < 10; attempt++) {
      callbacks++;
      final version = revision;
      final tx = _Transaction(this);
      final result = await action(tx);
      if (error != null) throw error!;
      if (retryOnce) {
        retryOnce = false;
        continue;
      }
      if (version != revision) continue;
      beforeCommit?.call();
      // Optional create-only Rules model; default set behavior permits overwrite.
      if (rejectExistingWrites && tx.writes.keys.any(docs.containsKey)) {
        throw StateError('Overwrite denied');
      }
      docs.addAll(tx.writes);
      if (tx.writes.isNotEmpty) {
        revision++;
        commits++;
      }
      if (afterCommitError != null) throw afterCommitError!;
      return result;
    }
    throw StateError('Retry exhausted');
  }
}

class _Transaction implements WorkspaceBootstrapTransaction {
  final BootstrapFake store;
  final Map<String, Map<String, dynamic>> writes = {};
  _Transaction(this.store);
  @override
  Future<Map<String, dynamic>?> readDocument(String path) async {
    if (writes.isNotEmpty) throw StateError('Read after write');
    await store.onRead?.call();
    final data = store.docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  @override
  void set(String path, Map<String, dynamic> data) => writes[path] = data;
}
