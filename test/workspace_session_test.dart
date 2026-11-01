import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_session.dart';

void main() {
  test('copies only resolver-verified workspace authority', () {
    const workspace = CafeWorkspace(
      cafeId: 'cafe-a',
      uid: 'staff-a',
      ownerUid: 'owner-a',
      role: CafeRole.staff,
    );

    final session = WorkspaceSession.fromVerified(workspace);

    expect(session.cafeId, 'cafe-a');
    expect(session.uid, 'staff-a');
    expect(session.ownerUid, 'owner-a');
    expect(session.role, CafeRole.staff);
    expect(session.isOwner, isFalse);
  });
}
