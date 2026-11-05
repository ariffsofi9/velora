import '../models/cafe_workspace.dart';

final _requestEpisodes = Expando<WorkspaceSession>(
  'workspace mutation episode',
);

/// Capture once per request object. A retry cannot adopt another adapter's
/// current session, even when the authenticated UID and cafe remain the same.
WorkspaceSession captureMutationSession(
  Object request,
  WorkspaceSession? current,
) {
  if (current == null) throw StateError('Verified workspace required.');
  current.requireActive();
  final captured = _requestEpisodes[request] ?? current;
  captured.requireActive();
  if (captured.uid != current.uid ||
      captured.cafeId != current.cafeId ||
      captured.ownerUid != current.ownerUid ||
      captured.role != current.role ||
      captured.membershipGeneration != current.membershipGeneration) {
    throw StateError('Mutation belongs to an earlier workspace episode.');
  }
  _requestEpisodes[request] = captured;
  return captured;
}

/// Immutable context created only from a successfully resolved workspace.
///
/// This is routing context, not an authorization token. Firestore Rules must
/// still validate the authenticated member on every request.
class WorkspaceSession {
  final String cafeId;
  final String uid;
  final String ownerUid;
  final CafeRole role;
  final int membershipGeneration;
  bool _active = true;
  bool get isActive => _active;
  void invalidate() => _active = false;
  void requireActive() {
    if (!_active) throw StateError('Workspace session invalidated.');
  }

  Map<String, Object> get mutationData {
    requireActive();
    return {
      'expectedCafeId': cafeId,
      'expectedMembershipGeneration': membershipGeneration,
    };
  }

  WorkspaceSession._({
    required this.cafeId,
    required this.uid,
    required this.ownerUid,
    required this.role,
    required this.membershipGeneration,
  });

  factory WorkspaceSession.fromVerified(CafeWorkspace workspace) =>
      WorkspaceSession._(
        cafeId: workspace.cafeId,
        uid: workspace.uid,
        ownerUid: workspace.ownerUid,
        role: workspace.role,
        membershipGeneration: workspace.membershipGeneration,
      );

  bool get isOwner => role == CafeRole.owner;
}
