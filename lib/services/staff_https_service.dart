import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/cafe_workspace.dart';
import 'team_members_service.dart';
import 'workspace_session.dart';

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

/// Unwired TEST-only service. No SDK/default client, direct writes, credentials
/// or automatic retries. Caller owns a client honoring redirect rejection and
/// a real SHA-256 hex provider. Endpoint project metadata is not attestation.
/// In-memory request bindings do not supply durable process-death recovery.
class StaffHttpsService implements TeamMembers {
  final Uri endpoint;
  final String projectId;
  final http.Client client;
  final StaffHttpsSession? Function() currentSession;
  final Stream<StaffHttpsSession?> sessionChanges;
  final Future<String?> Function(StaffHttpsSession) idToken;
  final String Function(String) sha256;
  final Duration timeout, cleanupTimeout;
  final int maxResponseBytes;
  StaffHttpsService({
    required this.endpoint,
    required this.projectId,
    required String endpointProjectId,
    required this.client,
    required this.currentSession,
    required this.sessionChanges,
    required this.idToken,
    required this.sha256,
    this.timeout = const Duration(seconds: 15),
    this.cleanupTimeout = const Duration(milliseconds: 100),
    this.maxResponseBytes = 262144,
  }) {
    if (projectId != 'velora-spark-test' ||
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
  Future<TeamRoster> load(CafeWorkspace workspace) async {
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
      final data = await _call('/staff/list', const {}, s, mutation: false);
      if (data.length != 3 ||
          data['cafeId'] != w.cafeId ||
          data['viewerRole'] != w.role.name ||
          data['members'] is! List) {
        _invalid();
      }
      final rows = data['members'] as List;
      if (rows.length > 100 || (!w.isOwner && rows.length > 2)) _invalid();
      final seen = <String>{}, members = <TeamMember>[];
      for (final row in rows) {
        if (row is! Map<String, dynamic> ||
            row.length != 4 ||
            !_id(row['uid']) ||
            !seen.add(row['uid'] as String) ||
            !_text(row['name'], 254) ||
            !_text(row['email'], 254) ||
            !RegExp(
              r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
            ).hasMatch(row['email'] as String) ||
            !['owner', 'staff'].contains(row['role']) ||
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
          ),
        );
      }
      _check(s, false);
      return TeamRoster(workspace, List.unmodifiable(members));
    } on StaffHttpsException {
      rethrow;
    } catch (_) {
      throw const StaffHttpsException('unavailable', outcomeUnknown: false);
    }
  }

  Future<StaffRemovalResult> remove(StaffRemovalRequest request) async {
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
      final digest = sha256(
        jsonEncode([s.uid, w.cafeId, request.idempotencyKey]),
      );
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
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
          ack['eventId'] != 'remove_$digest' ||
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
      final token = await idToken(captured);
      check();
      if (token == null ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,8192}$').hasMatch(token)) {
        throw const StaffHttpsException(
          'unauthenticated',
          outcomeUnknown: false,
        );
      }
      final body = jsonEncode(data);
      if (utf8.encode(body).length > 2048) {
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
          : StaffHttpsException(
              e is TimeoutException ? 'deadline-exceeded' : 'unavailable',
              outcomeUnknown: mutation && dispatched,
            );
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
