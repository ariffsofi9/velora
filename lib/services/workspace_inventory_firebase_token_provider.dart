import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';

import 'workspace_inventory_https_transport.dart';

/// Supplies [HttpsWorkspaceInventory.idToken] from the Auth instance that owns
/// the verified workspace. The session authority must invalidate the workspace
/// or advance the revision on every replacement, including same-UID sign-in.
final class WorkspaceInventoryFirebaseTokenProvider {
  final FirebaseAuth _auth;
  final String _projectId;
  final InventoryHttpsSession? Function() _currentSession;
  final DateTime Function() _now;

  WorkspaceInventoryFirebaseTokenProvider({
    required FirebaseAuth auth,
    required String projectId,
    required InventoryHttpsSession? Function() currentSession,
    DateTime Function()? now,
  }) : _auth = auth,
       _projectId = projectId,
       _currentSession = currentSession,
       _now = now ?? DateTime.now;

  Future<String?> call(
    InventoryHttpsSession session, {
    bool forceRefresh = true,
  }) async {
    try {
      final user = _matchingUser(session);
      if (user == null) return null;
      final token = await user
          .getIdToken(forceRefresh)
          .timeout(const Duration(seconds: 5));
      final currentUser = _matchingUser(session);
      if (token == null ||
          currentUser == null ||
          currentUser.email != user.email) {
        return null;
      }
      return _hasBoundClaims(token, session.uid, currentUser.email)
          ? token
          : null;
    } catch (_) {
      return null;
    }
  }

  User? _matchingUser(InventoryHttpsSession session) {
    if ((_projectId != 'velora-73222' && _projectId != 'velora-spark-test') ||
        _auth.app.options.projectId != _projectId ||
        session.projectId != _projectId ||
        !session.workspace.isActive ||
        session.uid.isEmpty ||
        session.uid != session.workspace.uid ||
        session.workspace.cafeId.isEmpty ||
        session.revision < 0 ||
        !session.emailVerified ||
        !session.matches(_currentSession())) {
      return null;
    }
    final user = _auth.currentUser;
    return user?.uid == session.uid && user?.emailVerified == true
        ? user
        : null;
  }

  // This is local admission only. The trusted backend verifies the signature,
  // current account status, and workspace authorization independently.
  bool _hasBoundClaims(String token, String uid, String? email) {
    if (token.length > 8192 || email == null || email.isEmpty) return false;
    final segments = token.split('.');
    if (segments.length != 3 || !segments.every(_segment.hasMatch)) {
      return false;
    }

    final header = _jsonSegment(segments[0]);
    final claims = _jsonSegment(segments[1]);
    if (header is! Map<String, dynamic> ||
        header['alg'] != 'RS256' ||
        header['kid'] is! String ||
        (header['kid'] as String).isEmpty ||
        claims is! Map<String, dynamic>) {
      return false;
    }

    final now = _now().millisecondsSinceEpoch ~/ 1000;
    final expiry = claims['exp'];
    final issued = claims['iat'];
    final authenticated = claims['auth_time'];
    final notBefore = claims['nbf'];
    return claims['aud'] == _projectId &&
        claims['iss'] == 'https://securetoken.google.com/$_projectId' &&
        claims['sub'] == uid &&
        claims['email'] == email &&
        claims['email_verified'] == true &&
        expiry is int &&
        expiry > now &&
        expiry <= 253402300799 &&
        issued is int &&
        issued >= 0 &&
        issued <= now &&
        issued < expiry &&
        authenticated is int &&
        authenticated >= 0 &&
        authenticated <= issued &&
        (!claims.containsKey('nbf') ||
            (notBefore is int &&
                notBefore >= 0 &&
                notBefore <= now &&
                notBefore < expiry));
  }

  static final _segment = RegExp(r'^[A-Za-z0-9_-]+$');

  static Object? _jsonSegment(String segment) =>
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(segment))));
}
