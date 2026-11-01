import '../models/cafe_workspace.dart';

/// Immutable context created only from a successfully resolved workspace.
///
/// This is routing context, not an authorization token. Firestore Rules must
/// still validate the authenticated member on every request.
class WorkspaceSession {
  final String cafeId;
  final String uid;
  final String ownerUid;
  final CafeRole role;

  const WorkspaceSession._({
    required this.cafeId,
    required this.uid,
    required this.ownerUid,
    required this.role,
  });

  factory WorkspaceSession.fromVerified(CafeWorkspace workspace) =>
      WorkspaceSession._(
        cafeId: workspace.cafeId,
        uid: workspace.uid,
        ownerUid: workspace.ownerUid,
        role: workspace.role,
      );

  bool get isOwner => role == CafeRole.owner;
}
