import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'workspace_provisioning_service.dart';

/// Trusted identity snapshot, not server authority. Revision advances on every
/// identity transition, including sign-out/back to the same UID. No membership
/// is required for onboarding. Server verification and fresh account checks apply.
class WorkspaceProvisioningIdentity {
  final String projectId, uid;
  final int revision;
  final bool emailVerified;
  const WorkspaceProvisioningIdentity({
    required this.projectId,
    required this.uid,
    required this.revision,
    required this.emailVerified,
  });
  bool matches(WorkspaceProvisioningIdentity? other) =>
      other != null &&
      projectId == other.projectId &&
      uid == other.uid &&
      revision == other.revision &&
      emailVerified == other.emailVerified;
}

class WorkspaceHttpsProvisioningException
    extends WorkspaceProvisioningException {
  final String code;
  const WorkspaceHttpsProvisioningException(
    super.failure,
    this.code, {
    required super.outcomeUncertain,
  });
  @override
  String toString() => 'Workspace HTTPS provisioning unavailable: $code';
}

class _Binding {
  final WorkspaceProvisioningIdentity identity;
  final String body;
  bool uncertain = false, busy = false;
  _Binding(this.identity, this.body);
}

final _bindings = Expando<_Binding>('workspace HTTPS request identity/payload');
bool _id(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 128 &&
    value.trim() == value &&
    !['.', '..'].contains(value) &&
    !RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(value);

/// Unwired TEST-only adapter. The caller owns the injected client's lifetime and
/// must provide a non-retrying client honoring followRedirects=false. No Firebase
/// SDK, default client, credential discovery or live endpoint is initialized.
/// Endpoint project metadata is trusted configuration, not remote attestation.
/// Bindings are in-memory only, not a durable crash journal or resend permission.
class WorkspaceHttpsProvisioner implements WorkspaceProvisioner {
  final Uri endpoint;
  final String projectId;
  final http.Client client;
  final WorkspaceProvisioningIdentity? Function() currentIdentity;
  final Stream<WorkspaceProvisioningIdentity?> identityChanges;
  final Future<String?> Function(WorkspaceProvisioningIdentity) idToken;
  final Duration timeout, cleanupTimeout;
  final int maxResponseBytes;

  WorkspaceHttpsProvisioner({
    required this.endpoint,
    required this.projectId,
    required String endpointProjectId,
    required this.client,
    required this.currentIdentity,
    required this.identityChanges,
    required this.idToken,
    this.timeout = const Duration(seconds: 15),
    this.cleanupTimeout = const Duration(milliseconds: 100),
    this.maxResponseBytes = 2048,
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
        maxResponseBytes > 65536) {
      throw const WorkspaceHttpsProvisioningException(
        WorkspaceProvisioningFailure.invalidProfile,
        'invalid-configuration',
        outcomeUncertain: false,
      );
    }
  }

  @override
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  ) async {
    var active = true, dispatched = false, changed = false, ownsBinding = false;
    _Binding? binding = _bindings[request];
    StreamSubscription<WorkspaceProvisioningIdentity?>? identityReader;
    StreamSubscription<List<int>>? bodyReader;
    WorkspaceCreationResult? result;
    WorkspaceHttpsProvisioningException? failure;
    WorkspaceHttpsProvisioningException error(
      String code,
      WorkspaceProvisioningFailure kind, {
      bool? uncertain,
    }) => WorkspaceHttpsProvisioningException(
      kind,
      code,
      outcomeUncertain: binding?.uncertain == true || (uncertain ?? dispatched),
    );
    void check() {
      WorkspaceProvisioningIdentity? current;
      try {
        current = currentIdentity();
      } catch (_) {
        changed = true;
      }
      if (!active ||
          changed ||
          binding == null ||
          !binding!.identity.matches(current)) {
        throw error(
          'session-changed',
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
    }

    Future<WorkspaceCreationResult> perform() async {
      final identity = currentIdentity();
      if (identity == null ||
          identity.projectId != projectId ||
          !_id(identity.uid) ||
          identity.revision < 0 ||
          identity.revision > 9007199254740991) {
        throw error(
          'unauthenticated',
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
      if (!identity.emailVerified) {
        throw error(
          'email-unverified',
          WorkspaceProvisioningFailure.emailUnverified,
        );
      }
      // Serialize the existing seven-field protocol. Server owns normalization,
      // validation, business-type aliases and transactional membership policy.
      final body = jsonEncode(request.toCallableData());
      binding = _bindings[request];
      if (binding != null &&
          (!binding!.identity.matches(identity) || binding!.body != body)) {
        throw error(
          'request-context-changed',
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
      binding ??= _Binding(identity, body);
      _bindings[request] = binding;
      if (binding!.busy) {
        throw error(
          'request-in-flight',
          WorkspaceProvisioningFailure.unavailable,
          uncertain: true,
        );
      }
      binding!.busy = true;
      ownsBinding = true;
      if (utf8.encode(body).length > 2048) {
        throw error(
          'invalid-argument',
          WorkspaceProvisioningFailure.invalidInput,
        );
      }
      identityReader = identityChanges.listen(
        (value) {
          if (!identity.matches(value)) changed = true;
        },
        onError: (Object _) {
          changed = true;
        },
        onDone: () {
          changed = true;
        },
      );
      check();
      final token = await idToken(identity);
      check();
      if (token == null ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,8192}$').hasMatch(token)) {
        throw error(
          'unauthenticated',
          WorkspaceProvisioningFailure.unauthenticated,
        );
      }
      final message =
          http.Request('POST', endpoint.resolve('/workspace/create'))
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers.addAll({
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
            })
            ..body = body;
      check();
      dispatched = true;
      final response = await client.send(message);
      if (!active) {
        // A client may complete after our deadline; cancel without publishing it.
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
            if (bytes.length + chunk.length > maxResponseBytes) {
              throw FormatException();
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
        throw error(
          'redirect-rejected',
          WorkspaceProvisioningFailure.unavailable,
        );
      }
      if ((response.contentLength ?? 0) > maxResponseBytes ||
          !RegExp(
            r'^application/json(?:\s*;\s*charset=utf-8)?$',
            caseSensitive: false,
          ).hasMatch(response.headers['content-type'] ?? '')) {
        throw FormatException();
      }
      await done.future;
      check();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw FormatException();
      if (response.statusCode != 200) {
        const statuses = {
          'unauthenticated': 401,
          'permission-denied': 403,
          'invalid-argument': 400,
          'already-exists': 409,
          'failed-precondition': 409,
          'resource-exhausted': 429,
          'deadline-exceeded': 408,
          'too-large': 413,
        };
        final code = decoded['error'];
        if (code is! String ||
            statuses[code] != response.statusCode ||
            decoded.length != 1) {
          throw error('unavailable', WorkspaceProvisioningFailure.unavailable);
        }
        final kind = switch (code) {
          'unauthenticated' => WorkspaceProvisioningFailure.unauthenticated,
          'permission-denied' => WorkspaceProvisioningFailure.permissionDenied,
          'invalid-argument' ||
          'too-large' => WorkspaceProvisioningFailure.invalidInput,
          'already-exists' => WorkspaceProvisioningFailure.existingMembership,
          'failed-precondition' => WorkspaceProvisioningFailure.unavailable,
          'deadline-exceeded' => WorkspaceProvisioningFailure.timedOut,
          _ => WorkspaceProvisioningFailure.unavailable,
        };
        throw error(code, kind, uncertain: false);
      }
      if (decoded.length != 2 ||
          !_id(decoded['cafeId']) ||
          decoded['created'] is! bool) {
        throw FormatException();
      }
      return WorkspaceCreationResult(created: decoded['created'] as bool);
    }

    try {
      result = await perform().timeout(timeout);
    } catch (e) {
      failure = e is WorkspaceHttpsProvisioningException
          ? e
          : error(
              e is TimeoutException ? 'deadline-exceeded' : 'unavailable',
              e is TimeoutException
                  ? WorkspaceProvisioningFailure.timedOut
                  : WorkspaceProvisioningFailure.unavailable,
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
        cancel(() => identityReader?.cancel()),
      ]).timeout(cleanupTimeout)).every((ok) => ok);
    } catch (_) {
      /* bounded cleanup; no raw dependency details */
    }
    if (failure == null) {
      if (!cleaned) {
        failure = error(
          'cleanup-failed',
          WorkspaceProvisioningFailure.unavailable,
        );
      } else {
        active = true;
        try {
          check();
        } on WorkspaceHttpsProvisioningException catch (e) {
          failure = e;
        }
        active = false;
      }
    }
    if (ownsBinding) {
      binding!.busy = false;
      if (failure?.outcomeUncertain == true) binding!.uncertain = true;
    }
    if (failure != null) throw failure;
    return result!;
  }
}
