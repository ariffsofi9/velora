enum CafeRole { owner, staff }

/// A validated resolution result, never an authorization token.
class CafeWorkspace {
  final String cafeId;
  final String uid;
  final String ownerUid;
  final CafeRole role;

  const CafeWorkspace({
    required this.cafeId,
    required this.uid,
    required this.ownerUid,
    required this.role,
  });
}

enum WorkspaceFailure {
  unauthenticated,
  missingMembership,
  inconsistentMembership,
  unavailable,
  sessionChanged,
}

class WorkspaceResolutionException implements Exception {
  final WorkspaceFailure failure;
  const WorkspaceResolutionException(this.failure);

  @override
  String toString() => 'Workspace resolution failed: ${failure.name}';
}
