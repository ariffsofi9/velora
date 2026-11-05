import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/cafe_workspace.dart';
import 'workspace_resolver.dart';

class TeamMember {
  final String uid, name, email;
  final CafeRole role;
  const TeamMember(this.uid, this.name, this.email, this.role);
}

class TeamRoster {
  final CafeWorkspace workspace;
  final List<TeamMember> members;
  const TeamRoster(this.workspace, this.members);
}

abstract interface class TeamMembers {
  Future<TeamRoster> load(CafeWorkspace workspace);
}

class FirebaseTeamMembers implements TeamMembers {
  final FirebaseAuth auth;
  final WorkspaceResolver resolver;
  final FirebaseFunctions? functions;
  FirebaseTeamMembers({
    required this.auth,
    required this.resolver,
    this.functions,
  });

  @override
  Future<TeamRoster> load(CafeWorkspace workspace) async {
    if (auth.currentUser?.uid != workspace.uid) {
      throw StateError('Session changed.');
    }
    final response =
        await (functions ??
                FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
            .httpsCallable('listTeamMembers')
            .call<Map<String, dynamic>>({});
    final current = await resolver.resolve();
    final data = response.data;
    final role = workspace.role == CafeRole.owner ? 'owner' : 'staff';
    if (auth.currentUser?.uid != workspace.uid ||
        current.uid != workspace.uid ||
        current.cafeId != workspace.cafeId ||
        current.ownerUid != workspace.ownerUid ||
        current.membershipGeneration != workspace.membershipGeneration ||
        current.role != workspace.role ||
        data['cafeId'] != workspace.cafeId ||
        data['viewerRole'] != role ||
        data['members'] is! List ||
        (data['members'] as List).length > 100) {
      throw StateError('Team verification failed.');
    }
    final seen = <String>{};
    final members = <TeamMember>[];
    for (final raw in data['members'] as List) {
      if (raw is! Map) throw StateError('Invalid team response.');
      final uid = raw['uid'],
          name = raw['name'],
          email = raw['email'],
          memberRole = raw['role'];
      if (uid is! String ||
          uid.isEmpty ||
          uid.length > 128 ||
          !seen.add(uid) ||
          name is! String ||
          name.isEmpty ||
          name.length > 254 ||
          email is! String ||
          email.isEmpty ||
          email.length > 254 ||
          !['owner', 'staff'].contains(memberRole) ||
          (memberRole == 'owner') != (uid == workspace.ownerUid) ||
          (workspace.role == CafeRole.staff &&
              uid != workspace.uid &&
              uid != workspace.ownerUid)) {
        throw StateError('Invalid team response.');
      }
      members.add(
        TeamMember(
          uid,
          name,
          email,
          memberRole == 'owner' ? CafeRole.owner : CafeRole.staff,
        ),
      );
    }
    return TeamRoster(workspace, List.unmodifiable(members));
  }
}
