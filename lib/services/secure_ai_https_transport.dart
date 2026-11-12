import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'secure_ai_service.dart';
import 'workspace_session.dart';

/// Trusted composition context, never server authority. Revision advances on
/// every identity/workspace transition, including sign-out/back to the same UID.
class SecureAiHttpsSession {
  final String uid, projectId;
  final int revision;
  final bool emailVerified;
  final WorkspaceSession workspace;
  const SecureAiHttpsSession({
    required this.uid,
    required this.projectId,
    required this.revision,
    required this.emailVerified,
    required this.workspace,
  });
  bool matches(SecureAiHttpsSession? other) =>
      other != null &&
      uid == other.uid &&
      projectId == other.projectId &&
      revision == other.revision &&
      emailVerified == other.emailVerified &&
      identical(workspace, other.workspace);
}

/// Existing service consumes code/reason; the explicit uncertainty flag remains
/// available to later qualified recovery wiring without exposing raw responses.
class SecureAiHttpsException extends SecureAiTransportException {
  final bool outcomeUnknown;
  const SecureAiHttpsException(
    super.code, {
    super.reason,
    required this.outcomeUnknown,
  });
  @override
  String toString() => 'Secure AI HTTPS unavailable: $code';
}

SecureAiHttpsException _error(
  String code, {
  bool unknown = false,
  String? reason,
}) => SecureAiHttpsException(
  code,
  outcomeUnknown: unknown,
  reason: unknown ? 'outcome-unknown' : reason,
);
bool _integer(Object? n) => n is int && n >= 0 && n <= 9007199254740991;
bool _id(Object? s) =>
    s is String &&
    s.isNotEmpty &&
    s.length <= 128 &&
    s.trim() == s &&
    !['.', '..'].contains(s) &&
    !RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(s);
bool _nonce(Object? s) => s is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(s);

class _Ticket {
  final SecureAiHttpsSession session;
  final int expiresAt, maxRecipes;
  bool dispatched = false;
  _Ticket(this.session, this.expiresAt, this.maxRecipes);
}

class _Scope {
  final tickets = <String, _Ticket>{};
  bool busy = false, uncertain = false;
}

final _scopes = Expando<_Scope>('secure AI transport evidence');

/// Unwired, disabled-by-default TEST transport. No Firebase SDK/default client,
/// provider URL/model selection, secrets, writes, quota maintenance or retries.
/// Caller owns a non-retrying client honoring followRedirects=false and retains
/// sessionScope across reconstruction. In-memory ticket bindings/unknown holds
/// are not durable recovery. Do not replace this scope to escape uncertainty.
/// Configure the containing service's timeout above completionBudget so this
/// adapter can classify uncertainty and finish bounded cleanup first.
class SecureAiHttpsTransport implements SecureAiTransport {
  final Uri endpoint;
  final String projectId;
  final http.Client client;
  final SecureAiHttpsSession? Function() currentSession;
  final Stream<SecureAiHttpsSession?> sessionChanges;
  final Future<String?> Function(SecureAiHttpsSession) idToken;
  final Object sessionScope;
  final int Function() now;
  final bool enabled;
  final Duration timeout, cleanupTimeout;
  Duration get completionBudget => timeout + cleanupTimeout;
  @override
  bool get available => enabled;
  @override
  bool get isDemo => false;
  SecureAiHttpsTransport({
    required this.endpoint,
    required this.projectId,
    required String endpointProjectId,
    required this.client,
    required this.currentSession,
    required this.sessionChanges,
    required this.idToken,
    required this.sessionScope,
    required this.now,
    this.enabled = false,
    this.timeout = const Duration(seconds: 15),
    this.cleanupTimeout = const Duration(milliseconds: 100),
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
        cleanupTimeout > const Duration(seconds: 5)) {
      throw _error('invalid-configuration');
    }
  }
  int _clock() {
    final time = now();
    if (!_integer(time)) throw _error('invalid-configuration');
    return time;
  }

  SecureAiHttpsSession _capture() {
    final s = currentSession();
    if (s == null ||
        s.projectId != projectId ||
        !_id(s.uid) ||
        !_integer(s.revision) ||
        s.uid != s.workspace.uid ||
        !s.workspace.isActive ||
        !_id(s.workspace.cafeId) ||
        !_id(s.workspace.ownerUid) ||
        !_integer(s.workspace.membershipGeneration) ||
        s.workspace.isOwner != (s.uid == s.workspace.ownerUid)) {
      throw _error('unauthenticated');
    }
    if (!s.emailVerified) {
      throw _error('unauthenticated', reason: 'email-unverified');
    }
    return s;
  }

  void _check(SecureAiHttpsSession s, bool unknown) {
    if (!s.workspace.isActive || !s.matches(currentSession())) {
      throw _error('aborted', unknown: unknown);
    }
  }

  @override
  Future<Object?> call(Map<String, Object> input) async {
    if (!enabled) throw const SecureAiException(SecureAiFailure.unavailable);
    final state = _scopes[sessionScope] ??= _Scope();
    var owned = false, dispatched = false, validating = false;
    try {
      if (state.uncertain) throw _error('unavailable', unknown: true);
      if (state.busy) {
        throw _error('resource-exhausted', reason: 'workspace-busy');
      }
      final s = _capture(), operation = input['operation'];
      if (!['issue', 'generate'].contains(operation)) {
        throw _error('invalid-argument');
      }
      final allowed = [
        'operation',
        'expectedCafeId',
        'expectedMembershipGeneration',
        'maxRecipes',
        if (operation == 'generate') 'ticketId',
      ];
      if (!input.keys.every(allowed.contains) ||
          !_id(input['expectedCafeId']) ||
          !_integer(input['expectedMembershipGeneration']) ||
          (input.containsKey('maxRecipes') &&
              (input['maxRecipes'] is! int ||
                  (input['maxRecipes'] as int) < 1 ||
                  (input['maxRecipes'] as int) > 3)) ||
          (operation == 'generate' && !_nonce(input['ticketId']))) {
        throw _error('invalid-argument');
      }
      if (input['expectedCafeId'] != s.workspace.cafeId ||
          input['expectedMembershipGeneration'] !=
              s.workspace.membershipGeneration) {
        throw _error('aborted');
      }
      final maxRecipes = input['maxRecipes'] as int? ?? 1;
      // Digest is canonical server-owned data. Bind the exact public parameters;
      // never send a client digest, fence, lease, provider or inventory snapshot.
      final body = <String, Object>{
        for (final entry in input.entries)
          if (entry.key != 'operation') entry.key: entry.value,
      };
      if (secureAiJsonBytes(body) > 2048) throw _error('invalid-argument');
      _Ticket? ticket;
      if (operation == 'generate') {
        ticket = state.tickets[body['ticketId']];
        if (ticket == null) throw _error('failed-precondition');
        if (!ticket.session.matches(s)) throw _error('aborted');
        if (ticket.maxRecipes != maxRecipes) {
          throw _error('failed-precondition');
        }
        if (_clock() >= ticket.expiresAt) {
          throw _error('failed-precondition', reason: 'ticket-expired');
        }
        if (ticket.dispatched) {
          throw _error('already-exists', reason: 'ticket-replayed');
        }
      } else if (state.tickets.length >= 1024) {
        throw _error('resource-exhausted');
      }
      state.busy = true;
      owned = true;
      final result = await _call(
        '/ai/$operation',
        body,
        s,
        onDispatch: () {
          dispatched = true;
          // A generation ticket is a one-shot dispatch capability. No client
          // resend is authorized by timeout, malformed output or a later error.
          ticket?.dispatched = true;
        },
      );
      validating = true;
      validateSecureAiResponseBytes(result);
      if (operation == 'issue') {
        if (result.length != 3 ||
            result['schemaVersion'] != 2 ||
            !_nonce(result['ticketId']) ||
            !_integer(result['expiresAt']) ||
            (result['expiresAt'] as int) <= _clock() ||
            state.tickets.containsKey(result['ticketId'])) {
          throw const FormatException();
        }
        _check(s, true);
        state.tickets[result['ticketId'] as String] = _Ticket(
          s,
          result['expiresAt'] as int,
          maxRecipes,
        );
      } else {
        SecureAiResult.parse(
          result,
          body['ticketId'] as String,
          maxRecipes,
          isDemo: false,
        );
        _check(s, true);
      }
      return result;
    } catch (e) {
      final unknown =
          state.uncertain ||
          validating ||
          (e is SecureAiHttpsException ? e.outcomeUnknown : dispatched);
      if (owned && unknown) state.uncertain = true;
      if (e is SecureAiHttpsException) {
        throw _error(e.code, unknown: unknown, reason: e.reason);
      }
      throw _error(
        e is FormatException || e is SecureAiException
            ? 'data-loss'
            : 'unavailable',
        unknown: unknown,
        reason: !unknown && (e is FormatException || e is SecureAiException)
            ? 'invalid-response'
            : null,
      );
    } finally {
      if (owned) state.busy = false;
    }
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, Object> data,
    SecureAiHttpsSession s, {
    required void Function() onDispatch,
  }) async {
    var active = true, changed = false, sent = false;
    StreamSubscription<SecureAiHttpsSession?>? identities;
    StreamSubscription<List<int>>? reader;
    SecureAiHttpsException? failure;
    Map<String, dynamic>? result;
    void check() {
      if (!active || changed) throw _error('aborted', unknown: sent);
      _check(s, sent);
    }

    Future<Map<String, dynamic>> perform() async {
      identities = sessionChanges.listen(
        (value) {
          if (!s.matches(value)) changed = true;
        },
        onError: (Object _) {
          changed = true;
        },
        onDone: () {
          changed = true;
        },
      );
      check();
      final token = await idToken(s);
      check();
      if (token == null ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,8192}$').hasMatch(token)) {
        throw _error('unauthenticated');
      }
      final request = http.Request('POST', endpoint.resolve(path))
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll({
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        })
        ..body = jsonEncode(data);
      check();
      sent = true;
      onDispatch();
      final response = await client.send(request);
      if (!active) {
        await Future<void>.sync(
          () => response.stream.listen(null, onError: (Object _) {}).cancel(),
        ).timeout(cleanupTimeout);
        check();
      }
      final bytes = <int>[], done = Completer<void>();
      unawaited(done.future.then<void>((_) {}, onError: (Object _) {}));
      reader = response.stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          try {
            check();
            if (bytes.length + chunk.length > secureAiMaxResponseBytes) {
              throw const FormatException();
            }
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
        throw _error('unavailable', unknown: true);
      }
      if ((response.contentLength ?? 0) > secureAiMaxResponseBytes ||
          !RegExp(
            r'^application/json(?:\s*;\s*charset=utf-8)?$',
            caseSensitive: false,
          ).hasMatch(response.headers['content-type'] ?? '')) {
        throw const FormatException();
      }
      await done.future;
      check();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
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
          throw _error(
            code,
            reason: switch (code) {
              'already-exists' => 'ticket-replayed',
              'invalid-argument' || 'too-large' => 'invalid-request',
              _ => null,
            },
          );
        }
        // HTTP supplies no granular quota/expiry/fencing reasons. Never infer
        // them from generic codes, raw text or arbitrary response properties.
        throw _error('unavailable', unknown: true);
      }
      return decoded;
    }

    try {
      result = await perform().timeout(timeout);
    } catch (e) {
      failure = e is SecureAiHttpsException
          ? e
          : _error(
              e is TimeoutException
                  ? 'deadline-exceeded'
                  : e is FormatException
                  ? 'data-loss'
                  : 'unavailable',
              unknown: sent,
            );
    }
    active = false;
    Future<bool> cancel(FutureOr<void> Function() action) => Future<void>.sync(
      action,
    ).then((_) => true, onError: (Object _) => false);
    var cleaned = false;
    try {
      cleaned = (await Future.wait([
        cancel(() => reader?.cancel()),
        cancel(() => identities?.cancel()),
      ]).timeout(cleanupTimeout)).every((ok) => ok);
    } catch (_) {
      /* bounded, sanitized cleanup */
    }
    if (failure == null) {
      if (!cleaned) {
        failure = _error('unavailable', unknown: sent);
      } else {
        active = true;
        try {
          check();
        } catch (_) {
          failure = _error('aborted', unknown: sent);
        }
        active = false;
      }
    }
    if (failure != null) throw failure;
    return result!;
  }
}
