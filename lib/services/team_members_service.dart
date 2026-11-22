import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/cafe_workspace.dart';
import 'workspace_resolver.dart';
import 'android_pilot_policy.dart';

class TeamPilotPolicyException implements Exception {
  const TeamPilotPolicyException();
  @override
  String toString() =>
      'Team actions are unavailable under the Android pilot policy.';
}

class TeamMember {
  final String uid, name, email;
  final CafeRole role;
  final int? membershipGeneration;
  const TeamMember(
    this.uid,
    this.name,
    this.email,
    this.role, {
    this.membershipGeneration,
  });
}

class TeamRoster {
  final CafeWorkspace workspace;
  final List<TeamMember> members;
  final String? nextCursor;
  const TeamRoster(this.workspace, this.members, {this.nextCursor});
}

abstract interface class TeamMembers {
  Future<TeamRoster> load(CafeWorkspace workspace);
}

abstract interface class PagedTeamMembers implements TeamMembers {
  Future<TeamRoster> loadPage(CafeWorkspace workspace, String cursor);
}

String? readTeamCursor(Map<dynamic, dynamic> data, CafeWorkspace workspace) {
  if (!data.containsKey('nextCursor')) return null;
  final cursor = data['nextCursor'];
  if (workspace.role != CafeRole.owner ||
      cursor is! String ||
      cursor.isEmpty ||
      cursor.length > 1900 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(cursor)) {
    throw StateError('Invalid team response.');
  }
  return cursor;
}

class FirebaseTeamMembers implements PagedTeamMembers {
  final AndroidPilotPolicy pilotPolicy;
  final FirebaseAuth auth;
  final WorkspaceResolver resolver;
  final FirebaseFunctions? functions;
  FirebaseTeamMembers({
    required this.pilotPolicy,
    required this.auth,
    required this.resolver,
    this.functions,
  });

  @override
  Future<TeamRoster> load(CafeWorkspace workspace) => _load(workspace);

  @override
  Future<TeamRoster> loadPage(CafeWorkspace workspace, String cursor) =>
      _load(workspace, cursor);

  Future<TeamRoster> _load(CafeWorkspace workspace, [String? cursor]) async {
    if (pilotPolicy.state != AndroidPilotState.normal &&
        !pilotPolicy.permits(AndroidPilotCapability.teamCallables)) {
      throw const TeamPilotPolicyException();
    }
    if (auth.currentUser?.uid != workspace.uid) {
      throw StateError('Session changed.');
    }
    final response =
        await (functions ??
                FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
            .httpsCallable('listTeamMembers')
            .call<Map<String, dynamic>>({'cursor': ?cursor});
    final current = await resolver.resolve();
    final data = response.data;
    final role = workspace.role == CafeRole.owner ? 'owner' : 'staff';
    final isOwner = workspace.role == CafeRole.owner;
    if (auth.currentUser?.uid != workspace.uid ||
        current.uid != workspace.uid ||
        current.cafeId != workspace.cafeId ||
        current.ownerUid != workspace.ownerUid ||
        current.membershipGeneration != workspace.membershipGeneration ||
        current.role != workspace.role ||
        data['cafeId'] != workspace.cafeId ||
        data['viewerRole'] != role ||
        data['members'] is! List ||
        (data['members'] as List).length > (isOwner ? 21 : 2)) {
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
          (cursor != null && memberRole == 'owner') ||
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
    final nextCursor = readTeamCursor(data, workspace);
    if (nextCursor != null && nextCursor == cursor ||
        isOwner && members.where((m) => m.role == CafeRole.staff).length > 20) {
      throw StateError('Invalid team response.');
    }
    return TeamRoster(
      workspace,
      List.unmodifiable(members),
      nextCursor: nextCursor,
    );
  }
}
