import 'package:firebase_auth/firebase_auth.dart';
import '../models/cafe_workspace.dart';
import 'workspace_store.dart';

/// Not wired into production routing. This service never provisions membership.
/// Firestore Rules remain responsible for authorization on every request.
class WorkspaceResolver {
  final FirebaseAuth? _auth;
  final WorkspaceStore? _store;
  WorkspaceResolver({FirebaseAuth? auth, WorkspaceStore? store})
    : _auth = auth,
      _store = store;

  String? get _uid => (_auth ?? FirebaseAuth.instance).currentUser?.uid;

  Future<CafeWorkspace> resolve() async {
    final uid = _uid;
    if (uid == null) {
      throw const WorkspaceResolutionException(
        WorkspaceFailure.unauthenticated,
      );
    }
    try {
      if (!_validId(uid)) _invalid();
      final result = await (_store ?? FirestoreWorkspaceStore())
          .readTransaction((reader) async {
            final mapping = await reader.readDocument(
              'user_cafe_memberships/$uid',
            );
            if (mapping == null) {
              throw const WorkspaceResolutionException(
                WorkspaceFailure.missingMembership,
              );
            }
            final cafeId = mapping['cafeId'];
            if (cafeId is! String || !_validId(cafeId)) _invalid();
            _validateLink(mapping, uid, cafeId);
            final cafe = await reader.readDocument('cafes/$cafeId');
            final member = await reader.readDocument(
              'cafes/$cafeId/members/$uid',
            );
            if (cafe == null || member == null) _invalid();
            _validateLink(member, uid, cafeId);
            final ownerUid = cafe['ownerUid'];
            if (cafe['schemaVersion'] != 1 ||
                cafe['status'] != 'active' ||
                ownerUid is! String ||
                !_validId(ownerUid)) {
              _invalid();
            }
            final role = switch (member['role']) {
              'owner' => CafeRole.owner,
              'staff' => CafeRole.staff,
              _ => throw const WorkspaceResolutionException(
                WorkspaceFailure.inconsistentMembership,
              ),
            };
            if ((role == CafeRole.owner) != (uid == ownerUid)) _invalid();
            final owner = ownerUid;
            final ownerMember = owner == uid
                ? member
                : await reader.readDocument('cafes/$cafeId/members/$owner');
            final ownerMapping = owner == uid
                ? mapping
                : await reader.readDocument('user_cafe_memberships/$owner');
            if (ownerMember == null || ownerMapping == null) _invalid();
            _validateLink(ownerMember, owner, cafeId);
            _validateLink(ownerMapping, owner, cafeId);
            if (ownerMember['role'] != 'owner') _invalid();
            return CafeWorkspace(
              cafeId: cafeId,
              uid: uid,
              ownerUid: owner,
              role: role,
            );
          });
      if (_uid != uid) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.sessionChanged,
        );
      }
      return result;
    } on WorkspaceResolutionException {
      rethrow;
    } catch (_) {
      // Do not expose backend details or fall back to stale/local memberships.
      throw const WorkspaceResolutionException(WorkspaceFailure.unavailable);
    }
  }

  static bool _validId(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      value.trim() == value &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !RegExp(r'[\x00-\x1f]').hasMatch(value);

  static void _validateLink(
    Map<String, dynamic> data,
    String uid,
    String cafeId,
  ) {
    if (data['uid'] != uid ||
        data['cafeId'] != cafeId ||
        data['status'] != 'active' ||
        data['schemaVersion'] != 1) {
      _invalid();
    }
  }

  static Never _invalid() => throw const WorkspaceResolutionException(
    WorkspaceFailure.inconsistentMembership,
  );
}
