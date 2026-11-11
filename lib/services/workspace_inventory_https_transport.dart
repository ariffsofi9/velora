import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'workspace_inventory_create_service.dart';
import 'workspace_inventory_update_service.dart';
import 'workspace_inventory_stock_service.dart';
import 'workspace_inventory_lifecycle_service.dart';
import 'workspace_session.dart';
import 'mutation_recovery_service.dart';

/// Trusted composition snapshot, never a source of server authorization.
/// revision must advance on EVERY identity/workspace transition, including
/// sign-out/back to the same UID. workspace must be the stable verified episode.
class InventoryHttpsSession {
  final String uid, projectId;
  final int revision;
  final bool emailVerified;
  final WorkspaceSession workspace;
  const InventoryHttpsSession({
    required this.uid,
    required this.projectId,
    required this.revision,
    required this.emailVerified,
    required this.workspace,
  });
  bool matches(InventoryHttpsSession? other) =>
      other != null &&
      uid == other.uid &&
      projectId == other.projectId &&
      revision == other.revision &&
      emailVerified == other.emailVerified &&
      identical(workspace, other.workspace);
}

/// Safe public metadata. Raw dependency exceptions and response bodies are never
/// retained. Unknown means a mutation may have committed: do not auto-replay.
class InventoryHttpsFailure implements Exception {
  final String code;
  final bool outcomeUnknown;
  final String? reason;
  const InventoryHttpsFailure(
    this.code, {
    required this.outcomeUnknown,
    this.reason,
  });
  @override
  String toString() => 'Inventory HTTPS failure: $code';
}

class InventoryHttpsCreateException extends WorkspaceInventoryCreateException {
  final InventoryHttpsFailure transport;
  InventoryHttpsCreateException(super.failure, this.transport);
  bool get outcomeUnknown => transport.outcomeUnknown;
}

class InventoryHttpsUpdateException extends WorkspaceInventoryUpdateException {
  final InventoryHttpsFailure transport;
  InventoryHttpsUpdateException(super.failure, this.transport);
  bool get outcomeUnknown => transport.outcomeUnknown;
}

class InventoryHttpsStockException extends WorkspaceInventoryStockException {
  final InventoryHttpsFailure transport;
  InventoryHttpsStockException(super.failure, this.transport);
  bool get outcomeUnknown => transport.outcomeUnknown;
}

class InventoryHttpsLifecycleException
    extends WorkspaceInventoryLifecycleException {
  final InventoryHttpsFailure transport;
  InventoryHttpsLifecycleException(super.failure, this.transport);
  bool get outcomeUnknown => transport.outcomeUnknown;
}

final _httpsEpisodes = Expando<InventoryHttpsSession>(
  'inventory HTTPS episode',
);
const _maxSafeInteger = 9007199254740991;
bool _integer(Object? value, {int min = 0}) =>
    value is int && value >= min && value <= _maxSafeInteger;
bool _identifier(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 128 &&
    !value.contains('/') &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
Never _invalidResponse() =>
    throw const InventoryHttpsFailure('invalid-response', outcomeUnknown: true);

/// Unwired, provider-independent adapters for all four existing interfaces.
/// The caller owns client lifetime and must inject a client honoring redirects
/// disabled on Request (no retrying/redirecting wrapper). No Firebase SDK access,
/// live client construction, privileged writes, or automatic mutation retries.
/// endpointProjectId is trusted deployment metadata, not remote attestation.
class HttpsWorkspaceInventory
    implements
        WorkspaceInventoryCreator,
        WorkspaceInventoryUpdater,
        WorkspaceInventoryStockAdjuster,
        WorkspaceInventoryLifecycleManager {
  final Uri endpoint;
  final String projectId;
  final http.Client client;
  final InventoryHttpsSession? Function() currentSession;
  final Stream<InventoryHttpsSession?> sessionChanges;
  final Future<String?> Function(InventoryHttpsSession) idToken;
  final Duration timeout, cleanupTimeout;
  final int maxResponseBytes;
  final MutationRecoveryJournal? journal;
  Duration get completionBudget =>
      timeout +
      cleanupTimeout +
      (journal == null ? Duration.zero : journal!.timeout * 4 + cleanupTimeout);

  HttpsWorkspaceInventory({
    required this.endpoint,
    required this.projectId,
    required String endpointProjectId,
    required this.client,
    required this.currentSession,
    required this.sessionChanges,
    required this.idToken,
    this.timeout = const Duration(seconds: 15),
    this.cleanupTimeout = const Duration(milliseconds: 100),
    this.maxResponseBytes = 65536,
    this.journal,
  }) {
    if (!['velora-spark-test', 'velora-73222'].contains(projectId) ||
        endpointProjectId != projectId ||
        endpoint.scheme != 'https' ||
        endpoint.host.length > 253 ||
        !RegExp(
          r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
        ).hasMatch(endpoint.host) ||
        endpoint.authority.contains('@') ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path != '' && endpoint.path != '/') ||
        endpoint.port != 443 ||
        endpoint.host.endsWith('.localhost') ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 30) ||
        cleanupTimeout <= Duration.zero ||
        cleanupTimeout > const Duration(seconds: 5) ||
        maxResponseBytes < 1 ||
        maxResponseBytes > 65536) {
      throw const InventoryHttpsFailure(
        'invalid-configuration',
        outcomeUnknown: false,
      );
    }
  }

  Future<T> _call<T>(
    Object operation,
    String path,
    Map<String, Object> data,
    T Function(Map<String, dynamic>) parse, {
    bool Function()? observedSessionChanged,
  }) async {
    final observation = path == '/inventory/reconcile';
    MutationDispatchPermit? permit;
    var journalFinalized = false;
    var dispatched = false, changed = false, active = true;
    StreamSubscription<InventoryHttpsSession?>? subscription;
    StreamSubscription<List<int>>? reader;
    InventoryHttpsSession? session;
    T? result;
    InventoryHttpsFailure? failure;
    void check() {
      final captured = session;
      InventoryHttpsSession? current;
      try {
        current = currentSession();
      } catch (_) {
        changed = true;
      }
      if (!active ||
          changed ||
          observedSessionChanged?.call() == true ||
          captured == null ||
          !captured.matches(current) ||
          !captured.workspace.isActive) {
        throw InventoryHttpsFailure(
          'session-changed',
          outcomeUnknown: dispatched,
        );
      }
    }

    Future<T> perform() async {
      final current = currentSession();
      if (current == null ||
          current.uid.isEmpty ||
          current.uid != current.workspace.uid ||
          current.projectId != projectId ||
          !current.emailVerified ||
          current.revision < 0) {
        throw const InventoryHttpsFailure(
          'unauthenticated',
          outcomeUnknown: false,
        );
      }
      try {
        captureMutationSession(operation, current.workspace);
      } catch (_) {
        throw const InventoryHttpsFailure(
          'session-changed',
          outcomeUnknown: false,
        );
      }
      session = _httpsEpisodes[operation] ?? current;
      if (!session!.matches(current)) {
        throw const InventoryHttpsFailure(
          'session-changed',
          outcomeUnknown: false,
        );
      }
      _httpsEpisodes[operation] = session;
      if (observedSessionChanged == null) {
        subscription = sessionChanges.listen(
          (value) {
            if (!session!.matches(value)) changed = true;
          },
          onError: (Object _) {
            changed = true;
          },
          onDone: () {
            changed = true;
          },
        );
      }
      check();
      final payload = observation
          ? data
          : {...data, ...session!.workspace.mutationData};
      final body = jsonEncode(payload);
      if (utf8.encode(body).length > (observation ? 4160 : 4096)) {
        throw const InventoryHttpsFailure(
          'invalid-argument',
          outcomeUnknown: false,
        );
      }
      final token = await idToken(session!);
      check();
      if (token == null ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,8192}$').hasMatch(token)) {
        throw const InventoryHttpsFailure(
          'unauthenticated',
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
      if (!observation && journal != null) {
        permit = await journal!.prepare(
          projectId: projectId,
          uid: session!.uid,
          operation: path.substring('/inventory/'.length),
          request: payload,
        );
        check();
        await journal!.markDispatched(permit!);
        check();
      }
      dispatched = true;
      final response = await client.send(request);
      if (!active) {
        // An arbitrary injected client may finish after timeout. Consume no late
        // result; attempt bounded cancellation without closing the shared client.
        await Future<void>.sync(
          () => response.stream.listen(null, onError: (Object _) {}).cancel(),
        ).timeout(cleanupTimeout);
        check();
      }
      final bytes = <int>[];
      final done = Completer<void>();
      unawaited(done.future.then<void>((_) {}, onError: (Object _) {}));
      reader = response.stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          try {
            check();
            if (bytes.length + chunk.length > maxResponseBytes) {
              _invalidResponse();
            }
            bytes.addAll(chunk);
          } catch (error, stack) {
            done.completeError(error, stack);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      check();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const InventoryHttpsFailure(
          'redirect-rejected',
          outcomeUnknown: true,
        );
      }
      if ((response.contentLength ?? 0) > maxResponseBytes ||
          !RegExp(
            r'^application/json(?:\s*;\s*charset=utf-8)?$',
            caseSensitive: false,
          ).hasMatch(response.headers['content-type'] ?? '')) {
        _invalidResponse();
      }
      await done.future;
      check();
      Map<String, dynamic> decoded;
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic>) _invalidResponse();
        decoded = value;
      } catch (_) {
        _invalidResponse();
      }
      if (response.statusCode != 200) {
        const statuses = {
          'unauthenticated': 401,
          'permission-denied': 403,
          'invalid-argument': 400,
          'already-exists': 409,
          'aborted': 409,
          'failed-precondition': 409,
          'out-of-range': 409,
          'resource-exhausted': 429,
          'not-found': 404,
          'deadline-exceeded': 408,
          'too-large': 413,
          'method-not-allowed': 405,
        };
        final code = decoded['error'];
        final reason = decoded['reason'];
        final stockReason =
            path == '/inventory/adjust-stock' &&
            code == 'failed-precondition' &&
            reason == 'insufficient-stock';
        if (code is String &&
            statuses[code] == response.statusCode &&
            decoded.keys.every(
              (key) => key == 'error' || (key == 'reason' && stockReason),
            )) {
          throw InventoryHttpsFailure(
            code,
            outcomeUnknown: false,
            reason: stockReason ? 'insufficient-stock' : null,
          );
        }
        throw const InventoryHttpsFailure('unavailable', outcomeUnknown: true);
      }
      if ((!observation && decoded['cafeId'] != session!.workspace.cafeId) ||
          decoded.containsKey('error') ||
          decoded.containsKey('outcomeUnknown')) {
        _invalidResponse();
      }
      final parsed = parse(decoded);
      if (!observation && permit != null) {
        final acknowledgement = validateMutationAcknowledgement(
          path.substring('/inventory/'.length),
          payload,
          decoded,
        );
        journalFinalized = true;
        await journal!.finish(permit!, result: acknowledgement);
        check();
      }
      return parsed;
    }

    try {
      result = await perform().timeout(timeout);
    } catch (error) {
      failure = error is InventoryHttpsFailure
          ? error
          : InventoryHttpsFailure(
              error is TimeoutException ? 'deadline-exceeded' : 'unavailable',
              outcomeUnknown:
                  dispatched ||
                  (error is MutationRecoveryFailure && error.outcomeUnknown),
            );
    }
    active = false;
    Future<bool> cancel(FutureOr<void> Function() action) => Future<void>.sync(
      action,
    ).then((_) => true, onError: (Object _) => false);
    // Start independently: a throwing/stalled cancellation cannot hide the other.
    final cleanup = [
      cancel(() => reader?.cancel()),
      cancel(() => subscription?.cancel()),
    ];
    var cleaned = false;
    try {
      cleaned = (await Future.wait(
        cleanup,
      ).timeout(cleanupTimeout)).every((ok) => ok);
    } catch (_) {
      /* every individual future already has an error observer */
    }
    if (failure != null) {
      if (permit != null && !journalFinalized) {
        try {
          await journal!.finish(permit!, uncertain: failure.outcomeUnknown);
        } catch (_) {
          throw const InventoryHttpsFailure(
            'journal-unavailable',
            outcomeUnknown: true,
          );
        }
      }
      throw failure;
    }
    if (!cleaned) {
      throw InventoryHttpsFailure('cleanup-failed', outcomeUnknown: dispatched);
    }
    // Cleanup can itself cause an identity/workspace transition. Recheck only
    // after both subscriptions have completed cancellation, before publishing.
    active = true;
    try {
      check();
    } finally {
      active = false;
    }
    return result as T;
  }

  /// Explicit observation only. Reconstructed records never acquire a dispatch
  /// permit. A fresh verified session may observe its original cafe/generation;
  /// server authority is rechecked independently. No automatic mutation replay.
  Future<MutationReceiptObservation> reconcile(
    PendingMutationOperation pending,
  ) async {
    StreamSubscription<InventoryHttpsSession?>? monitor;
    var changed = false;
    try {
      if (journal == null || pending.projectId != projectId) {
        throw const InventoryHttpsFailure(
          'recovery-unavailable',
          outcomeUnknown: true,
        );
      }
      final current = currentSession();
      if (current == null ||
          current.uid != pending.uid ||
          current.uid != current.workspace.uid ||
          current.projectId != projectId ||
          !current.emailVerified ||
          current.revision < 0 ||
          !current.workspace.isActive ||
          current.workspace.cafeId != pending.request['expectedCafeId'] ||
          current.workspace.membershipGeneration !=
              pending.request['expectedMembershipGeneration']) {
        throw const InventoryHttpsFailure(
          'session-changed',
          outcomeUnknown: true,
        );
      }
      void checkObservation() {
        if (changed ||
            !current.matches(currentSession()) ||
            !current.workspace.isActive) {
          throw const InventoryHttpsFailure(
            'session-changed',
            outcomeUnknown: true,
          );
        }
      }

      monitor = sessionChanges.listen(
        (value) {
          if (!current.matches(value)) changed = true;
        },
        onError: (Object _) {
          changed = true;
        },
        onDone: () {
          changed = true;
        },
      );
      final latest = await journal!.load(
        projectId,
        pending.uid,
        pending.operation,
        pending.stableKey,
      );
      checkObservation();
      if (latest == null ||
          latest.revision != pending.revision ||
          latest.payloadDigest != pending.payloadDigest) {
        throw const InventoryHttpsFailure(
          'recovery-unavailable',
          outcomeUnknown: true,
        );
      }
      final observation = await _call(
        pending,
        '/inventory/reconcile',
        pending.observationEnvelope,
        (data) => MutationReceiptObservation.parse(pending, data),
        observedSessionChanged: () => changed,
      );
      // _call has completed bounded listener cleanup/session checks. Persist an
      // observation only after that; an unknown response never changes state.
      final captured = _httpsEpisodes[pending];
      if (captured == null ||
          !captured.matches(currentSession()) ||
          !captured.workspace.isActive) {
        throw const InventoryHttpsFailure(
          'session-changed',
          outcomeUnknown: true,
        );
      }
      await journal!.recordObservation(pending, observation);
      checkObservation();
      if (!captured.matches(currentSession()) || !captured.workspace.isActive) {
        throw const InventoryHttpsFailure(
          'session-changed',
          outcomeUnknown: true,
        );
      }
      await monitor.cancel().timeout(cleanupTimeout);
      monitor = null;
      checkObservation();
      return observation;
    } catch (error) {
      if (error is InventoryHttpsFailure) {
        throw InventoryHttpsFailure(
          error.code,
          outcomeUnknown: pending.unresolved || error.outcomeUnknown,
          reason: error.reason,
        );
      }
      throw const InventoryHttpsFailure(
        'recovery-unavailable',
        outcomeUnknown: true,
      );
    } finally {
      if (monitor != null) {
        try {
          await monitor.cancel().timeout(cleanupTimeout);
        } catch (_) {
          /* bounded cleanup */
        }
      }
    }
  }

  @override
  Future<WorkspaceInventoryCreateResult> createItem(
    WorkspaceInventoryCreateRequest request,
  ) async {
    try {
      return await _call(
        request,
        '/inventory/create',
        request.toCallableData(),
        (data) {
          final itemId = data['itemId'];
          if (itemId is! String ||
              !RegExp(r'^item_[0-9a-f]{64}$').hasMatch(itemId) ||
              data['created'] is! bool) {
            _invalidResponse();
          }
          return WorkspaceInventoryCreateResult(
            itemId: data['itemId'] as String,
            created: data['created'] as bool,
          );
        },
      );
    } on InventoryHttpsFailure catch (e) {
      throw InventoryHttpsCreateException(switch (e.code) {
        'unauthenticated' => WorkspaceInventoryCreateFailure.unauthenticated,
        'invalid-argument' ||
        'too-large' => WorkspaceInventoryCreateFailure.invalidInput,
        'permission-denied' || 'failed-precondition' =>
          WorkspaceInventoryCreateFailure.permissionDenied,
        'already-exists' ||
        'aborted' => WorkspaceInventoryCreateFailure.conflict,
        _ => WorkspaceInventoryCreateFailure.unavailable,
      }, e);
    }
  }

  @override
  Future<WorkspaceInventoryUpdateResult> updateItem(
    WorkspaceInventoryUpdateRequest request,
  ) async {
    try {
      return await _call(
        request,
        '/inventory/update',
        request.toCallableData(),
        (data) {
          if (data['itemId'] != request.itemId ||
              !_identifier(data['itemId']) ||
              data['updated'] is! bool ||
              !_integer(data['version'], min: 1) ||
              data['version'] !=
                  request.expectedVersion + (data['updated'] == true ? 1 : 0)) {
            _invalidResponse();
          }
          return WorkspaceInventoryUpdateResult(
            itemId: data['itemId'] as String,
            updated: data['updated'] as bool,
            version: data['version'] as int,
          );
        },
      );
    } on InventoryHttpsFailure catch (e) {
      throw InventoryHttpsUpdateException(switch (e.code) {
        'unauthenticated' => WorkspaceInventoryUpdateFailure.unauthenticated,
        'invalid-argument' ||
        'too-large' => WorkspaceInventoryUpdateFailure.invalidInput,
        'permission-denied' || 'failed-precondition' =>
          WorkspaceInventoryUpdateFailure.permissionDenied,
        'not-found' => WorkspaceInventoryUpdateFailure.notFound,
        'already-exists' => WorkspaceInventoryUpdateFailure.conflict,
        'aborted' => WorkspaceInventoryUpdateFailure.stale,
        _ => WorkspaceInventoryUpdateFailure.unavailable,
      }, e);
    }
  }

  @override
  Future<WorkspaceInventoryStockResult> adjustStock(
    WorkspaceInventoryStockRequest request,
  ) async {
    try {
      return await _call(
        request,
        '/inventory/adjust-stock',
        request.toCallableData(),
        (data) {
          if (data['itemId'] != request.itemId ||
              !_identifier(data['itemId']) ||
              data['direction'] != request.directionValue ||
              !_integer(data['quantity'], min: 1) ||
              data['quantity'] != request.quantity ||
              !_integer(data['resultingQuantity']) ||
              // Replays return the original movement result, which obeys the
              // same lower bound regardless of the item's current quantity.
              (request.direction == StockDirection.stockIn &&
                  (data['resultingQuantity'] as int) < request.quantity) ||
              !_integer(data['version'], min: 1) ||
              data['version'] != request.expectedVersion + 1 ||
              data['adjusted'] is! bool) {
            _invalidResponse();
          }
          return WorkspaceInventoryStockResult(
            itemId: request.itemId,
            direction: request.direction,
            quantity: data['quantity'] as int,
            resultingQuantity: data['resultingQuantity'] as int,
            version: data['version'] as int,
            adjusted: data['adjusted'] as bool,
          );
        },
      );
    } on InventoryHttpsFailure catch (e) {
      throw InventoryHttpsStockException(switch (e.code) {
        'unauthenticated' => WorkspaceInventoryStockFailure.unauthenticated,
        'invalid-argument' ||
        'too-large' => WorkspaceInventoryStockFailure.invalidInput,
        'permission-denied' => WorkspaceInventoryStockFailure.permissionDenied,
        'not-found' => WorkspaceInventoryStockFailure.notFound,
        'already-exists' => WorkspaceInventoryStockFailure.conflict,
        'aborted' => WorkspaceInventoryStockFailure.stale,
        'out-of-range' => WorkspaceInventoryStockFailure.outOfRange,
        'failed-precondition' when e.reason == 'insufficient-stock' =>
          WorkspaceInventoryStockFailure.insufficientStock,
        _ => WorkspaceInventoryStockFailure.unavailable,
      }, e);
    }
  }

  @override
  Future<WorkspaceInventoryLifecycleResult> setLifecycle(
    WorkspaceInventoryLifecycleRequest request,
  ) async {
    try {
      return await _call(
        request,
        '/inventory/lifecycle',
        request.toCallableData(),
        (data) {
          final state = request.action == InventoryLifecycleAction.archive
              ? 'archived'
              : 'active';
          if (data['itemId'] != request.itemId ||
              !_identifier(data['itemId']) ||
              data['lifecycleState'] != state ||
              !_integer(data['version'], min: 1) ||
              data['version'] != request.expectedVersion + 1 ||
              data['changed'] is! bool) {
            _invalidResponse();
          }
          return WorkspaceInventoryLifecycleResult(
            itemId: request.itemId,
            lifecycleState: state,
            version: data['version'] as int,
            changed: data['changed'] as bool,
          );
        },
      );
    } on InventoryHttpsFailure catch (e) {
      throw InventoryHttpsLifecycleException(switch (e.code) {
        'unauthenticated' => WorkspaceInventoryLifecycleFailure.unauthenticated,
        'invalid-argument' ||
        'too-large' => WorkspaceInventoryLifecycleFailure.invalidInput,
        'permission-denied' || 'failed-precondition' =>
          WorkspaceInventoryLifecycleFailure.permissionDenied,
        'not-found' => WorkspaceInventoryLifecycleFailure.notFound,
        'already-exists' => WorkspaceInventoryLifecycleFailure.conflict,
        'aborted' => WorkspaceInventoryLifecycleFailure.stale,
        _ => WorkspaceInventoryLifecycleFailure.unavailable,
      }, e);
    }
  }
}
