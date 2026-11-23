// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../journal_qualification/indexed_db_journal_engine.dart';
import 'platform_journal_store.dart';
import 'workspace_inventory_https_transport.dart';
import 'workspace_session.dart';

PlatformJournalStore? realInventoryJournal(WorkspaceSession workspace) {
  // A blocked browser preflight looks like an unknown POST outcome to Dart.
  // Keep it from creating a journal hold on an unsupported frontend origin.
  if (!web.window.isSecureContext ||
      web.window.location.origin !=
          Uri.https(HttpsWorkspaceInventory.realHost).origin) {
    return null;
  }
  return PlatformJournalStore(
    engine: const _InventoryJournalEngine(),
    sha256: (input) async {
      final digest = await web.window.crypto.subtle
          .digest('SHA-256'.toJS, utf8.encode(input).toJS)
          .toDart;
      return (digest as JSArrayBuffer).toDart
          .asUint8List()
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
    },
  );
}

final class _InventoryJournalEngine implements TransactionalJournalEngine {
  const _InventoryJournalEngine();

  @override
  Future<T> transaction<T>(
    Future<T> Function(JournalStorageTransaction tx) action,
  ) async {
    final engine = await IndexedDbJournalEngine.open(
      name: IndexedDbJournalEngine.inventoryDatabase,
    );
    try {
      return await engine.transaction(action);
    } finally {
      engine.close();
    }
  }
}
