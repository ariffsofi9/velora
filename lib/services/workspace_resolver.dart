import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/cafe_workspace.dart';
import 'workspace_store.dart';

/// Not wired into production routing. This service never provisions membership.
/// Firestore Rules remain responsible for authorization on every request.
class WorkspaceResolver {
  final FirebaseAuth? _auth;
  final WorkspaceStore? _store;
  final void Function(String message)? _debugLog;
  WorkspaceResolver({
    FirebaseAuth? auth,
    WorkspaceStore? store,
    void Function(String message)? debugLog,
  }) : _auth = auth,
       _store = store,
       _debugLog = debugLog;

  String? get _uid => (_auth ?? FirebaseAuth.instance).currentUser?.uid;

  Future<CafeWorkspace> resolve() async {
    final uid = _uid;
    if (uid == null) {
      throw const WorkspaceResolutionException(
        WorkspaceFailure.unauthenticated,
      );
    }
    var operation = 'validate-session';
    try {
      if (!_validId(uid)) _invalid();
      operation = 'begin-read-transaction';
      final documents = await (_store ?? FirestoreWorkspaceStore())
          .readTransaction((reader) async {
            operation = 'read-self-mapping';
            final mapping = await reader.readDocument(
              'user_cafe_memberships/$uid',
            );
            if (mapping == null) return const _WorkspaceDocuments();
            final cafeId = mapping['cafeId'];
            if (cafeId is! String || !_validId(cafeId)) {
              return _WorkspaceDocuments(mapping: mapping);
            }
            if (!_validLink(mapping, uid, cafeId)) {
              return _WorkspaceDocuments(mapping: mapping);
            }
            operation = 'read-workspace';
            final cafe = await reader.readDocument('cafes/$cafeId');
            operation = 'read-self-membership';
            final member = await reader.readDocument(
              'cafes/$cafeId/members/$uid',
            );
            final ownerUid = cafe?['ownerUid'];
            final memberRole = member?['role'];
            if (cafe == null ||
                member == null ||
                !_validLink(member, uid, cafeId) ||
                cafe['schemaVersion'] != 1 ||
                cafe['status'] != 'active' ||
                ownerUid is! String ||
                !_validId(ownerUid) ||
                (memberRole != 'owner' && memberRole != 'staff') ||
                ((memberRole == 'owner') != (uid == ownerUid))) {
              return _WorkspaceDocuments(
                mapping: mapping,
                cafe: cafe,
                member: member,
              );
            }
            operation = 'read-owner-membership';
            final ownerMember = ownerUid == uid
                ? member
                : await reader.readDocument('cafes/$cafeId/members/$ownerUid');
            operation = 'read-owner-mapping';
            final ownerMapping = ownerUid == uid
                ? mapping
                : await reader.readDocument('user_cafe_memberships/$ownerUid');
            return _WorkspaceDocuments(
              mapping: mapping,
              cafe: cafe,
              member: member,
              ownerMember: ownerMember,
              ownerMapping: ownerMapping,
            );
          });

      // Keep domain exceptions outside the Firestore Web transaction callback.
      // The JS transaction bridge can surface callback-thrown Dart exceptions as
      // an opaque NativeError, losing the typed missing-membership outcome.
      operation = 'validate-self-mapping';
      final mapping = documents.mapping;
      if (mapping == null) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.missingMembership,
        );
      }
      final cafeId = mapping['cafeId'];
      if (cafeId is! String || !_validId(cafeId)) _invalid();
      _validateLink(mapping, uid, cafeId);

      operation = 'validate-workspace';
      final cafe = documents.cafe;
      final member = documents.member;
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

      operation = 'validate-owner-links';
      final ownerMember = documents.ownerMember;
      final ownerMapping = documents.ownerMapping;
      if (ownerMember == null || ownerMapping == null) _invalid();
      _validateLink(ownerMember, ownerUid, cafeId);
      _validateLink(ownerMapping, ownerUid, cafeId);
      if (ownerMember['role'] != 'owner') _invalid();

      final result = CafeWorkspace(
        cafeId: cafeId,
        uid: uid,
        ownerUid: ownerUid,
        role: role,
      );
      operation = 'verify-session-unchanged';
      if (_uid != uid) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.sessionChanged,
        );
      }
      return result;
    } on WorkspaceResolutionException catch (error) {
      _diagnose('typed-failure', operation, failure: error.failure.name);
      rethrow;
    } catch (error) {
      if (error is FirebaseException) {
        _diagnose(
          'firebase-failure',
          operation,
          plugin: error.plugin,
          code: error.code,
        );
      } else {
        _diagnose(
          'unexpected-failure',
          operation,
          errorType: error.runtimeType.toString(),
        );
      }
      // Do not expose backend details or fall back to stale/local memberships.
      throw const WorkspaceResolutionException(WorkspaceFailure.unavailable);
    }
  }

  void _diagnose(
    String result,
    String operation, {
    String? failure,
    String? plugin,
    String? code,
    String? errorType,
  }) {
    if (!kDebugMode) return;
    final fields = <String>[
      'result=${_safeDiagnosticToken(result)}',
      'operation=${_safeDiagnosticToken(operation)}',
      if (failure != null) 'failure=${_safeDiagnosticToken(failure)}',
      if (plugin != null) 'plugin=${_safeDiagnosticToken(plugin)}',
      if (code != null) 'code=${_safeDiagnosticToken(code)}',
      if (errorType != null) 'type=${_safeDiagnosticToken(errorType)}',
    ];
    (_debugLog ?? debugPrint)('[WorkspaceResolver] ${fields.join(' ')}');
  }

  static String _safeDiagnosticToken(String value) {
    final normalized = value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9._-]'),
      '-',
    );
    return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
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
    if (!_validLink(data, uid, cafeId)) _invalid();
  }

  static bool _validLink(
    Map<String, dynamic> data,
    String uid,
    String cafeId,
  ) =>
      data['uid'] == uid &&
      data['cafeId'] == cafeId &&
      data['status'] == 'active' &&
      data['schemaVersion'] == 1;

  static Never _invalid() => throw const WorkspaceResolutionException(
    WorkspaceFailure.inconsistentMembership,
  );
}

class _WorkspaceDocuments {
  final Map<String, dynamic>? mapping;
  final Map<String, dynamic>? cafe;
  final Map<String, dynamic>? member;
  final Map<String, dynamic>? ownerMember;
  final Map<String, dynamic>? ownerMapping;

  const _WorkspaceDocuments({
    this.mapping,
    this.cafe,
    this.member,
    this.ownerMember,
    this.ownerMapping,
  });
}
