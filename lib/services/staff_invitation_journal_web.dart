import 'dart:convert';

import '../journal_qualification/indexed_db_journal_engine.dart';
import 'invitation_recovery_service.dart';

final _persistence = _BrowserInvitations();
InvitationRecoveryJournal? openStaffInvitationJournal() =>
    InvitationRecoveryJournal(_persistence);

final class _BrowserInvitations implements InvitationJournalPersistence {
  Future<IndexedDbJournalEngine> _open() => IndexedDbJournalEngine.open(
    name: IndexedDbJournalEngine.invitationDatabase,
  );

  String _key(String project, String uid) =>
      'staff/${base64Url.encode(utf8.encode('$project/$uid'))}';

  @override
  Future<Object?> read(String projectId, String uid) async {
    final engine = await _open();
    try {
      return await engine.transaction((tx) async {
        final raw = await tx.read(_key(projectId, uid));
        return raw == null ? null : jsonDecode(raw as String);
      });
    } finally {
      engine.close();
    }
  }

  @override
  Future<bool> compareAndSet(
    String projectId,
    String uid,
    Object? expected,
    Map<String, Object> value,
  ) async {
    final engine = await _open();
    try {
      final key = _key(projectId, uid);
      return await engine.transaction((tx) async {
        final current = await tx.read(key);
        if (current != (expected == null ? null : jsonEncode(expected))) {
          return false;
        }
        await tx.put(key, jsonEncode(value));
        return true;
      });
    } finally {
      engine.close();
    }
  }
}
