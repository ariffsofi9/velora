import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'android_pilot_policy.dart';
import 'mutation_recovery_service.dart';
import 'workspace_inventory_firebase_token_provider.dart';
import 'workspace_inventory_https_transport.dart';
import 'workspace_session.dart';

/// Offline composition for the Auth instance and verified workspace supplied
/// by the caller. Only the injected synthetic response handler receives HTTP.
final class OfflineVerifiedWorkspaceInventory {
  final FirebaseAuth _auth;
  final String _projectId;
  final AndroidPilotPolicy _policy;
  final http.Client _client;
  final _changes = StreamController<InventoryHttpsSession?>.broadcast(
    sync: true,
  );
  final _retired = Expando<bool>();
  StreamSubscription<User?>? _authChanges;
  InventoryHttpsSession? _session;
  int _revision = 0;
  String? _verifiedUid;
  bool _closed = false;

  late final HttpsWorkspaceInventory transport;
  late final HttpsWorkspaceInventory Function(InventoryHttpsSession? Function())
  _createTransport;

  OfflineVerifiedWorkspaceInventory({
    required FirebaseAuth auth,
    required String projectId,
    required AndroidPilotPolicy policy,
    required Future<http.Response> Function(http.Request) respond,
    MutationRecoveryJournal? journal,
    DateTime Function()? now,
  }) : _auth = auth,
       _projectId = projectId,
       _policy = policy,
       _client = MockClient(respond) {
    _createTransport = (currentSession) {
      final provider = WorkspaceInventoryFirebaseTokenProvider(
        auth: auth,
        projectId: projectId,
        currentSession: currentSession,
        now: now,
      );
      return HttpsWorkspaceInventory(
        pilotPolicy: policy,
        endpoint: Uri.https('inventory.offline.invalid'),
        projectId: projectId,
        endpointProjectId: projectId,
        client: _client,
        currentSession: currentSession,
        sessionChanges: _changes.stream,
        idToken: provider.call,
        journal: journal,
      );
    };
    transport = _createTransport(_currentSession);
    if (_matchesTarget()) {
      _authChanges = auth.authStateChanges().listen(
        (user) => _replaceAuth(user?.emailVerified == true ? user?.uid : null),
        onError: (Object _) => _replaceAuth(null),
        onDone: () => _replaceAuth(null),
      );
    }
  }

  /// Capture before starting workspace resolution. A result can only bind to
  /// the revision in which that resolution started.
  int get revision => _revision;

  bool usesAuth(FirebaseAuth auth) =>
      !_closed && identical(auth, _auth) && _matchesTarget();

  /// A retained route handle can never adopt a later workspace binding.
  HttpsWorkspaceInventory transportForWorkspace(WorkspaceSession workspace) {
    final captured = _currentSession();
    return _createTransport(() {
      final current = _currentSession();
      return captured != null &&
              identical(captured.workspace, workspace) &&
              captured.matches(current)
          ? current
          : null;
    });
  }

  void releaseVerifiedWorkspace(WorkspaceSession workspace) {
    if (identical(_session?.workspace, workspace)) _clearWorkspace();
  }

  bool bindVerifiedWorkspace(
    WorkspaceSession workspace, {
    required int expectedRevision,
  }) {
    if (_closed ||
        expectedRevision != _revision ||
        !workspace.isActive ||
        _retired[workspace] == true ||
        workspace.uid.isEmpty ||
        workspace.cafeId.isEmpty ||
        !_matchesIdentity(workspace.uid)) {
      return false;
    }
    if (identical(_session?.workspace, workspace)) return true;
    _clearWorkspace();
    if (_closed ||
        _revision != expectedRevision + 1 ||
        !workspace.isActive ||
        !_matchesIdentity(workspace.uid)) {
      return false;
    }
    _session = InventoryHttpsSession(
      uid: workspace.uid,
      projectId: _projectId,
      revision: _revision,
      emailVerified: true,
      workspace: workspace,
    );
    return true;
  }

  void _replaceAuth(String? verifiedUid) {
    if (_closed) return;
    _verifiedUid = verifiedUid;
    _clearWorkspace();
  }

  void _clearWorkspace() {
    final previous = _session;
    _session = null;
    _revision++;
    if (previous != null) {
      _retired[previous.workspace] = true;
      _changes.add(null);
    }
  }

  bool _matchesTarget() =>
      _policy.state == AndroidPilotState.normal &&
      _auth.app.options.projectId == _projectId;

  bool _matchesIdentity(String uid) {
    if (_verifiedUid != uid || !_matchesTarget()) return false;
    final user = _auth.currentUser;
    return user?.uid == uid && user?.emailVerified == true;
  }

  InventoryHttpsSession? _currentSession() {
    final session = _session;
    return !_closed &&
            session != null &&
            session.workspace.isActive &&
            _matchesIdentity(session.uid)
        ? session
        : null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _clearWorkspace();
    _client.close();
    try {
      await _authChanges?.cancel();
    } finally {
      await _changes.close();
    }
  }
}
