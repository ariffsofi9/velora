import 'package:flutter/foundation.dart';

import 'android_sqlite_journal_engine.dart';
import 'platform_journal_store.dart';
import 'workspace_inventory_https_transport.dart';
import 'workspace_session.dart';

PlatformJournalStore? realInventoryJournal(WorkspaceSession workspace) {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  final engine = AndroidSqliteJournalEngine(
    workspace: workspace,
    firebaseProjectId: HttpsWorkspaceInventory.realProject,
  );
  return PlatformJournalStore(engine: engine, sha256: engine.sha256);
}
