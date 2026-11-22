import 'android_pilot_policy.dart';
import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../models/cafe_workspace.dart';
import 'team_members_service.dart';
import 'workspace_session.dart';
import 'workspace_inventory_firebase_token_provider.dart';
import 'workspace_inventory_https_transport.dart';

/// Trusted composition snapshot, not authorization. Revision advances on every
/// identity/workspace transition, including sign-out/back to the same UID.
class StaffHttpsSession {
  final String projectId, uid;
  final int revision;
  final bool emailVerified;
  final WorkspaceSession workspace;
  const StaffHttpsSession({
    required this.projectId,
    required this.uid,
    required this.revision,
    required this.emailVerified,
    required this.workspace,
  });
  bool matches(StaffHttpsSession? other) =>
      other != null &&
      projectId == other.projectId &&
      uid == other.uid &&
      revision == other.revision &&
      emailVerified == other.emailVerified &&
      identical(workspace, other.workspace);
}

class StaffHttpsException implements Exception {
  final String code;
  final bool outcomeUnknown;
  const StaffHttpsException(this.code, {required this.outcomeUnknown});
  @override
  String toString() => 'Staff HTTPS unavailable: $code';
}

/// Capture original preconditions/key once; unchanged retries reuse this object.
class StaffRemovalRequest {
  final String targetUid, expectedCafeId, idempotencyKey;
  final int expectedGeneration, expectedActorGeneration;
  const StaffRemovalRequest({
    required this.targetUid,
    required this.expectedCafeId,
    required this.expectedGeneration,
    required this.expectedActorGeneration,
    required this.idempotencyKey,
  });
  Map<String, Object> toJson() => {
    'targetUid': targetUid,
    'expectedCafeId': expectedCafeId,
    'expectedGeneration': expectedGeneration,
    'expectedActorGeneration': expectedActorGeneration,
    'idempotencyKey': idempotencyKey,
  };
}

/// Historical acknowledgement only; never a claim about current membership.
class StaffRemovalResult {
  final String cafeId, targetUid, eventId;
  final int resultGeneration;
  final bool changed;
  const StaffRemovalResult({
    required this.cafeId,
    required this.targetUid,
    required this.eventId,
    required this.resultGeneration,
    required this.changed,
  });
}

class _RemovalBinding {
  final StaffHttpsSession session;
  final String body;
  bool busy = false, uncertain = false;
  _RemovalBinding(this.session, this.body);
}

final _removals = Expando<_RemovalBinding>(
  'Staff removal original request binding',
);
const _safe = 9007199254740991;
bool _integer(Object? n) => n is int && n >= 0 && n <= _safe;
bool _id(Object? s) =>
    s is String &&
    s.isNotEmpty &&
    s.length <= 128 &&
    s.trim() == s &&
    !['.', '..'].contains(s) &&
    !RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(s);
bool _text(Object? s, int max) =>
    s is String &&
    s.isNotEmpty &&
    s.length <= max &&
    s.trim() == s &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(s);
Never _invalid() => throw const FormatException('Invalid Staff response');

/// The REAL composition is roster-only. The existing TEST removal adapter
/// retains its original session and request bindings.
class StaffHttpsService implements PagedTeamMembers {
  static const realProject = 'velora-73222';
  static const canonicalOrigin =
      'https://rest-api.velora-smart-inventory.workers.dev';
  static const configuredOrigin = String.fromEnvironment(
    'VELORA_PUBLIC_ORIGIN',
    defaultValue: canonicalOrigin,
  );
  final AndroidPilotPolicy pilotPolicy;
  final Uri endpoint;
  final String projectId;
  final http.Client client;
  final StaffHttpsSession? Function() currentSession;
  final Stream<StaffHttpsSession?> sessionChanges;
  final Future<String?> Function(StaffHttpsSession) idToken;
  final Future<String?> Function(StaffHttpsSession)? _readIdToken;
  final String Function(String)? _sha256;
  final bool _realRoster;
  final Duration timeout, cleanupTimeout;
  final int maxResponseBytes;
  StaffHttpsService({
    required AndroidPilotPolicy pilotPolicy,
    required Uri endpoint,
    required String projectId,
    required String endpointProjectId,
    required http.Client client,
    required StaffHttpsSession? Function() currentSession,
    required Stream<StaffHttpsSession?> sessionChanges,
    required Future<String?> Function(StaffHttpsSession) idToken,
    required String Function(String) sha256,
    Duration timeout = const Duration(seconds: 15),
    Duration cleanupTimeout = const Duration(milliseconds: 100),
    int maxResponseBytes = 262144,
  }) : this._(
         pilotPolicy: pilotPolicy,
         endpoint: endpoint,
         projectId: projectId,
         endpointProjectId: endpointProjectId,
         client: client,
         currentSession: currentSession,
         sessionChanges: sessionChanges,
         idToken: idToken,
         sha256: sha256,
         timeout: timeout,
         cleanupTimeout: cleanupTimeout,
         maxResponseBytes: maxResponseBytes,
       );

  factory StaffHttpsService.realRoster({
    required AndroidPilotPolicy pilotPolicy,
    required FirebaseAuth auth,
    required WorkspaceSession workspace,
    required http.Client client,
    required bool Function() isCurrent,
    String origin = configuredOrigin,
  }) {
    final endpoint = Uri.tryParse(origin);
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        !endpoint.hasAuthority ||
        origin != canonicalOrigin ||
        endpoint.host.endsWith('.invalid') ||
        auth.app.options.projectId != realProject) {
      throw const StaffHttpsException(
        'invalid-configuration',
        outcomeUnknown: false,
      );
    }
    final session = StaffHttpsSession(
      projectId: realProject,
      uid: workspace.uid,
      revision: 0,
      emailVerified: true,
      workspace: workspace,
    );
    final tokenSession = InventoryHttpsSession(
      projectId: realProject,
      uid: workspace.uid,
      revision: 0,
      emailVerified: true,
      workspace: workspace,
    );
    StaffHttpsSession? current() {
      if (!isCurrent() ||
          !workspace.isActive ||
          auth.app.options.projectId != realProject) {
        return null;
      }
      final user = auth.currentUser;
      return user?.uid == workspace.uid && user?.emailVerified == true
          ? session
          : null;
    }

    final provider = WorkspaceInventoryFirebaseTokenProvider(
      auth: auth,
      projectId: realProject,
      currentSession: () => current() == null ? null : tokenSession,
    );
    return StaffHttpsService._(
      pilotPolicy: pilotPolicy,
      endpoint: endpoint,
      projectId: realProject,
      endpointProjectId: realProject,
      client: client,
      currentSession: current,
      sessionChanges: auth.authStateChanges().map((_) => current()),
      idToken: (captured) async =>
          captured.matches(current()) ? provider(tokenSession) : null,
      readIdToken: (captured) async => captured.matches(current())
          ? provider(tokenSession, forceRefresh: false)
          : null,
      realRoster: true,
    );
  }

  StaffHttpsService._({
    required this.pilotPolicy,
    required this.endpoint,
    required this.projectId,
    required String endpointProjectId,
    required this.client,
    required this.currentSession,
    required this.sessionChanges,
    required this.idToken,
    Future<String?> Function(StaffHttpsSession)? readIdToken,
    String Function(String)? sha256,
    bool realRoster = false,
    this.timeout = const Duration(seconds: 15),
    this.cleanupTimeout = const Duration(milliseconds: 100),
    this.maxResponseBytes = 262144,
  }) : _readIdToken = readIdToken,
       _sha256 = sha256,
       _realRoster = realRoster {
    if (projectId != (realRoster ? realProject : 'velora-spark-test') ||
        endpointProjectId != projectId ||
        endpoint.scheme != 'https' ||
        endpoint.port != 443 ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.authority.contains('@') ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        !['', '/'].contains(endpoint.path) ||
        endpoint.host.length > 253 ||
        !RegExp(
          r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
        ).hasMatch(endpoint.host) ||
        endpoint.host.endsWith('.localhost') ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 30) ||
        cleanupTimeout <= Duration.zero ||
        cleanupTimeout > const Duration(seconds: 5) ||
        maxResponseBytes < 1 ||
        maxResponseBytes > 262144) {
      throw const StaffHttpsException(
        'invalid-configuration',
        outcomeUnknown: false,
      );
    }
  }

  bool get _policyAllowed =>
      pilotPolicy.state == AndroidPilotState.normal ||
      pilotPolicy.permits(AndroidPilotCapability.teamCallables);
  void _requirePolicy() {
    if (!_policyAllowed) {
      throw const StaffHttpsException(
        'pilot-policy-denied',
        outcomeUnknown: false,
      );
    }
  }

  StaffHttpsSession _capture() {
    final s = currentSession();
    if (s == null ||
        s.projectId != projectId ||
        !_id(s.uid) ||
        !_integer(s.revision) ||
        !s.emailVerified ||
        !s.workspace.isActive ||
        s.uid != s.workspace.uid ||
        !_id(s.workspace.cafeId) ||
        !_id(s.workspace.ownerUid) ||
        !_integer(s.workspace.membershipGeneration) ||
        s.workspace.isOwner != (s.uid == s.workspace.ownerUid)) {
      throw const StaffHttpsException('unauthenticated', outcomeUnknown: false);
    }
    return s;
  }

  @override
  Future<TeamRoster> load(CafeWorkspace workspace) => _load(workspace);

  @override
  Future<TeamRoster> loadPage(CafeWorkspace workspace, String cursor) =>
      _load(workspace, cursor);

  Future<TeamRoster> _load(CafeWorkspace workspace, [String? cursor]) async {
    _requirePolicy();
    try {
      final s = _capture(), w = s.workspace;
      if (workspace.uid != w.uid ||
          workspace.cafeId != w.cafeId ||
          workspace.ownerUid != w.ownerUid ||
          workspace.role != w.role ||
          workspace.membershipGeneration != w.membershipGeneration) {
        throw const StaffHttpsException(
          'session-changed',
          outcomeUnknown: false,
        );
      }
      if (cursor != null &&
          (!w.isOwner ||
              cursor.isEmpty ||
              cursor.length > 1900 ||
              RegExp(r'[^A-Za-z0-9_-]').hasMatch(cursor))) {
        throw const StaffHttpsException(
          'invalid-argument',
          outcomeUnknown: false,
        );
      }
      final data = await _call(
        '/staff/list',
        {'cursor': ?cursor, if (_realRoster) ...w.mutationData},
        s,
        mutation: false,
      );
      final nextCursor = readTeamCursor(data, workspace);
      if (data.length != (nextCursor == null ? 3 : 4) ||
          (nextCursor != null && nextCursor == cursor) ||
          data['cafeId'] != w.cafeId ||
          data['viewerRole'] != w.role.name ||
          data['members'] is! List) {
        _invalid();
      }
      final rows = data['members'] as List;
      if (rows.length > (w.isOwner ? 21 : 2)) _invalid();
      final seen = <String>{}, members = <TeamMember>[];
      for (final row in rows) {
        final generation = row is Map ? row['membershipGeneration'] : null;
        final removalTarget =
            _realRoster && w.isOwner && row is Map && row['role'] == 'staff';
        if (row is! Map<String, dynamic> ||
            row.length != (generation == null ? 4 : 5) ||
            (generation != null && (!removalTarget || !_integer(generation))) ||
            !_id(row['uid']) ||
            !seen.add(row['uid'] as String) ||
            !_text(row['name'], 254) ||
            !_text(row['email'], 254) ||
            !RegExp(
              r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
            ).hasMatch(row['email'] as String) ||
            !['owner', 'staff'].contains(row['role']) ||
            (cursor != null && row['role'] == 'owner') ||
            (row['role'] == 'owner') != (row['uid'] == w.ownerUid) ||
            (!w.isOwner && row['uid'] != w.uid && row['uid'] != w.ownerUid)) {
          _invalid();
        }
        members.add(
          TeamMember(
            row['uid'] as String,
            row['name'] as String,
            row['email'] as String,
            row['role'] == 'owner' ? CafeRole.owner : CafeRole.staff,
            membershipGeneration: generation as int?,
          ),
        );
      }
      if (w.isOwner &&
          members.where((m) => m.role == CafeRole.staff).length > 20) {
        _invalid();
      }
      _check(s, false);
      return TeamRoster(
        workspace,
        List.unmodifiable(members),
        nextCursor: nextCursor,
      );
    } on StaffHttpsException {
      rethrow;
    } catch (_) {
      throw const StaffHttpsException('unavailable', outcomeUnknown: false);
    }
  }

  Future<StaffRemovalResult> remove(StaffRemovalRequest request) async {
    _requirePolicy();
    var binding = _removals[request];
    var owned = false, sent = false;
    try {
      final s = _capture(), w = s.workspace;
      if (!w.isOwner || request.targetUid == s.uid) {
        throw const StaffHttpsException(
          'permission-denied',
          outcomeUnknown: false,
        );
      }
      if (!_id(request.targetUid) ||
          !_id(request.expectedCafeId) ||
          !_integer(request.expectedGeneration) ||
          !_integer(request.expectedActorGeneration) ||
          !RegExp(
            r'^[A-Za-z0-9_-]{16,128}$',
          ).hasMatch(request.idempotencyKey)) {
        throw const StaffHttpsException(
          'invalid-argument',
          outcomeUnknown: false,
        );
      }
      final data = request.toJson(), body = jsonEncode(data);
      if (binding != null &&
          (!binding.session.matches(s) || binding.body != body)) {
        throw const StaffHttpsException(
          'request-context-changed',
          outcomeUnknown: false,
        );
      }
      if (request.expectedCafeId != w.cafeId ||
          request.expectedActorGeneration != w.membershipGeneration) {
        throw const StaffHttpsException('aborted', outcomeUnknown: false);
      }
      binding ??= _RemovalBinding(s, body);
      _removals[request] = binding;
      if (binding.busy) {
        throw const StaffHttpsException(
          'request-in-flight',
          outcomeUnknown: true,
        );
      }
      final digest = _sha256?.call(
        jsonEncode([s.uid, w.cafeId, request.idempotencyKey]),
      );
      if (!_realRoster &&
          (digest == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest))) {
        throw const StaffHttpsException(
          'invalid-configuration',
          outcomeUnknown: false,
        );
      }
      binding.busy = true;
      owned = true;
      final ack = await _call(
        '/staff/remove',
        data,
        s,
        mutation: true,
        onDispatch: () {
          sent = true;
        },
      );
      if (ack.length != 5 ||
          ack['cafeId'] != request.expectedCafeId ||
          ack['targetUid'] != request.targetUid ||
          (digest == null
              ? ack['eventId'] is! String ||
                    !RegExp(
                      r'^remove_[a-f0-9]{64}$',
                    ).hasMatch(ack['eventId'] as String)
              : ack['eventId'] != 'remove_$digest') ||
          !_integer(ack['resultGeneration']) ||
          ack['resultGeneration'] != request.expectedGeneration + 1 ||
          ack['changed'] is! bool) {
        _invalid();
      }
      _check(s, true);
      return StaffRemovalResult(
        cafeId: ack['cafeId'] as String,
        targetUid: ack['targetUid'] as String,
        eventId: ack['eventId'] as String,
        resultGeneration: ack['resultGeneration'] as int,
        changed: ack['changed'] as bool,
      );
    } catch (e) {
      final code = e is StaffHttpsException ? e.code : 'unavailable';
      final unknown =
          binding?.uncertain == true ||
          (e is StaffHttpsException ? e.outcomeUnknown : sent);
      if (owned && unknown) binding!.uncertain = true;
      throw StaffHttpsException(code, outcomeUnknown: unknown);
    } finally {
      if (owned) binding!.busy = false;
    }
  }

  void _check(StaffHttpsSession captured, bool unknown) {
    if (!captured.workspace.isActive || !captured.matches(currentSession())) {
      throw StaffHttpsException('session-changed', outcomeUnknown: unknown);
    }
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, Object> data,
    StaffHttpsSession captured, {
    required bool mutation,
    void Function()? onDispatch,
  }) async {
    var active = true, changed = false, dispatched = false;
    StreamSubscription<StaffHttpsSession?>? sessionReader;
    StreamSubscription<List<int>>? bodyReader;
    StaffHttpsException? failure;
    Map<String, dynamic>? result;
    void check() {
      if (!active || changed) {
        throw StaffHttpsException(
          'session-changed',
          outcomeUnknown: mutation && dispatched,
        );
      }
      _check(captured, mutation && dispatched);
    }

    Future<Map<String, dynamic>> perform() async {
      sessionReader = sessionChanges.listen(
        (value) {
          if (!captured.matches(value)) changed = true;
        },
        onError: (Object _) {
          changed = true;
        },
        onDone: () {
          changed = true;
        },
      );
      check();
      final token = await (mutation ? idToken : _readIdToken ?? idToken)(
        captured,
      );
      check();
      if (token == null ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,8192}$').hasMatch(token)) {
        throw const StaffHttpsException(
          'unauthenticated',
          outcomeUnknown: false,
        );
      }
      final body = jsonEncode(data);
      if (utf8.encode(body).length > (_realRoster ? 2560 : 2048)) {
        throw const StaffHttpsException(
          'invalid-argument',
          outcomeUnknown: false,
        );
      }
      final request = http.Request('POST', endpoint.resolve(path))
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll({
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        })
        ..body = body;
      check();
      dispatched = true;
      onDispatch?.call();
      final response = await client.send(request);
      if (!active) {
        await Future<void>.sync(
          () => response.stream.listen(null, onError: (Object _) {}).cancel(),
        ).timeout(cleanupTimeout);
        check();
      }
      final bytes = <int>[], done = Completer<void>();
      unawaited(done.future.then<void>((_) {}, onError: (Object _) {}));
      bodyReader = response.stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          try {
            check();
            if (bytes.length + chunk.length > maxResponseBytes) _invalid();
            bytes.addAll(chunk);
          } catch (e, stack) {
            done.completeError(e, stack);
          }
        },
        onError: (Object e, StackTrace stack) {
          if (!done.isCompleted) done.completeError(e, stack);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw StaffHttpsException(
          'redirect-rejected',
          outcomeUnknown: mutation,
        );
      }
      if ((response.contentLength ?? 0) > maxResponseBytes ||
          !RegExp(
            r'^application/json(?:\s*;\s*charset=utf-8)?$',
            caseSensitive: false,
          ).hasMatch(response.headers['content-type'] ?? '')) {
        _invalid();
      }
      await done.future;
      check();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) _invalid();
      if (response.statusCode != 200) {
        const statuses = {
          'unauthenticated': 401,
          'permission-denied': 403,
          'invalid-argument': 400,
          'already-exists': 409,
          'failed-precondition': 409,
          'aborted': 409,
          'resource-exhausted': 429,
          'deadline-exceeded': 408,
          'too-large': 413,
        };
        final code = decoded['error'];
        if (code is String &&
            statuses[code] == response.statusCode &&
            decoded.length == 1) {
          throw StaffHttpsException(code, outcomeUnknown: false);
        }
        throw StaffHttpsException('unavailable', outcomeUnknown: mutation);
      }
      return decoded;
    }

    try {
      result = await perform().timeout(timeout);
    } catch (e) {
      failure = e is StaffHttpsException
          ? e
          : StaffHttpsException(switch (e) {
              TimeoutException() => 'deadline-exceeded',
              http.ClientException() when !mutation => 'network-unavailable',
              _ => 'unavailable',
            }, outcomeUnknown: mutation && dispatched);
    }
    active = false;
    Future<bool> cancel(FutureOr<void> Function() action) => Future<void>.sync(
      action,
    ).then((_) => true, onError: (Object _) => false);
    var cleaned = false;
    try {
      cleaned = (await Future.wait([
        cancel(() => bodyReader?.cancel()),
        cancel(() => sessionReader?.cancel()),
      ]).timeout(cleanupTimeout)).every((ok) => ok);
    } catch (_) {
      /* retain original failure; no raw dependency details */
    }
    if (failure == null) {
      if (!cleaned) {
        failure = StaffHttpsException(
          'cleanup-failed',
          outcomeUnknown: mutation && dispatched,
        );
      } else {
        active = true;
        try {
          check();
        } catch (_) {
          failure = StaffHttpsException(
            'session-changed',
            outcomeUnknown: mutation && dispatched,
          );
        }
        active = false;
      }
    }
    if (failure != null) throw failure;
    return result!;
  }
}
