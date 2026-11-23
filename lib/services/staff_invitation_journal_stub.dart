import 'package:flutter/foundation.dart';

import 'invitation_recovery_service.dart';
import 'real_inventory_journal.dart';
import 'workspace_session.dart';

InvitationRecoveryJournal? openStaffInvitationJournal(
  WorkspaceSession? workspace,
) {
  if (defaultTargetPlatform != TargetPlatform.android ||
      workspace == null ||
      !workspace.isActive ||
      !workspace.isOwner) {
    return null;
  }
  final store = realInventoryJournal(workspace);
  return store == null ? null : InvitationRecoveryJournal(store.invitations);
}
