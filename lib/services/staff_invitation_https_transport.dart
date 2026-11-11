import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/cafe_workspace.dart';
import 'staff_invitation_service.dart';
import 'invitation_recovery_service.dart';

/// Injected, immutable session snapshot. revision must advance on every auth or
/// workspace transition, including sign-out/back to the same UID. No SDK defaults.
class InvitationHttpsSession {
  final String uid, projectId;
  final int revision;
  final bool emailVerified;
  const InvitationHttpsSession({
    required this.uid,
    required this.projectId,
    required this.revision,
    required this.emailVerified,
  });
  bool matches(InvitationHttpsSession? other) =>
      other != null &&
      uid == other.uid &&
      projectId == other.projectId &&
      revision == other.revision &&
      emailVerified == other.emailVerified;
}

/// Unwired foundation. The composition owner supplies the HTTP client, the current
/// Firebase ID-token provider and a session stream. Never construct a live client
/// or access Firebase here. Retain sessionScope across service reconstruction.
/// endpointProjectId is trusted composition metadata, not remote attestation.
class HttpsStaffInvitations implements StaffInvitations {
  final Uri endpoint;
  final String projectId;
  final http.Client client;
  final InvitationHttpsSession? Function() currentSession;
  final Stream<InvitationHttpsSession?> sessionChanges;
  final Future<String?> Function(InvitationHttpsSession) idToken;
  final Object sessionScope;
  final String Function() requestId;
  final DateTime Function() clock;
  final Duration timeout;
  final Duration cleanupTimeout;
  final int maxResponseBytes;
  final InvitationRecoveryJournal journal;

  /// Processing plus cleanup budget, subject to normal event-loop scheduling.
  Duration get completionBudget => timeout + cleanupTimeout;

  Duration get reconciliationCompletionBudget => timeout + completionBudget;

  HttpsStaffInvitations({
    required this.endpoint,
    required this.projectId,
    required String endpointProjectId,
    required this.client,
    required this.currentSession,
    required this.sessionChanges,
    required this.idToken,
    required this.sessionScope,
    required this.requestId,
    required this.clock,
    this.timeout = const Duration(seconds: 15),
    this.cleanupTimeout = const Duration(milliseconds: 100),
    this.maxResponseBytes = 65536,
    required this.journal,
  }) {
    if (!['velora-spark-test', 'velora-73222'].contains(projectId) ||
        endpointProjectId != projectId ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.host.length > 253 ||
        !RegExp(
          r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
        ).hasMatch(endpoint.host) ||
        endpoint.authority.contains('@') ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.path != '' && endpoint.path != '/' ||
        endpoint.port != 443 ||
        endpoint.host == 'localhost' ||
        endpoint.host.endsWith('.localhost') ||
        RegExp(r'^[0-9.]+$').hasMatch(endpoint.host) ||
        endpoint.host.contains(':') ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 30) ||
        cleanupTimeout <= Duration.zero ||
        cleanupTimeout > const Duration(seconds: 5) ||
        maxResponseBytes < 1 ||
        maxResponseBytes > 65536) {
      throw const StaffInvitationTransportException(
        'invalid-argument',
        outcomeUnknown: false,
      );
    }
  }

  bool get creationBlocked {
    final session = currentSession();
    return session != null &&
        StaffInvitationCreation.forSession(sessionScope, session.uid).blocked;
  }

  InvitationHttpsSession _session() {
    final session = currentSession();
    if (session == null ||
        session.uid.isEmpty ||
        session.revision < 0 ||
        session.projectId != projectId ||
        !session.emailVerified) {
      throw const StaffInvitationTransportException(
        'unauthenticated',
        outcomeUnknown: false,
      );
    }
    return session;
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, Object> data,
    InvitationHttpsSession session, {
    void Function(StaffRedeemStage)? onStage,
    PendingInvitationOperation? pendingOperation,
  }) async {
    var changed = false, dispatched = false, active = true;
    StreamSubscription<List<int>>? reader;
    final subscription = sessionChanges.listen(
      (value) {
        if (!session.matches(value)) changed = true;
      },
      onError: (Object _) {
        changed = true;
      },
      onDone: () {
        changed = true;
      },
    );
    void check() {
      if (!active || changed || !session.matches(currentSession())) {
        throw StaffInvitationTransportException(
          'session-changed',
          outcomeUnknown: dispatched,
        );
      }
    }

    Future<Map<String, dynamic>> perform() async {
      check();
      final token = await idToken(session);
      check();
      if (token == null ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,8192}$').hasMatch(token)) {
        throw const StaffInvitationTransportException(
          'unauthenticated',
          outcomeUnknown: false,
        );
      }
      final body = jsonEncode(data);
      if (utf8.encode(body).length > 2048) {
        throw const StaffInvitationTransportException(
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
      if (pendingOperation != null) {
        try {
          await journal.prepare(pendingOperation);
        } catch (_) {
          StaffInvitationCreation.forSession(
            sessionScope,
            session.uid,
          ).requireReconciliation();
          throw const StaffInvitationTransportException(
            'unavailable',
            outcomeUnknown: false,
          );
        }
        check();
      }
      onStage?.call(StaffRedeemStage.callableInvocation);
      dispatched = true;
      final response = await client.send(request);
      if (!active) {
        // Arbitrary clients may continue after timeout. Reject their late result
        // and attempt bounded cleanup; this cannot guarantee socket cancellation.
        await Future<void>.sync(
          () => response.stream.listen(null).cancel(),
        ).timeout(cleanupTimeout);
        check();
      }
      final bytes = <int>[];
      final bodyDone = Completer<void>();
      // Observe errors even when headers cause an earlier rejection.
      unawaited(bodyDone.future.then<void>((_) {}, onError: (Object _) {}));
      reader = response.stream.listen(
        (chunk) {
          if (bodyDone.isCompleted) return;
          try {
            check();
            if (bytes.length + chunk.length > maxResponseBytes) {
              throw const StaffInvitationTransportException(
                'response-too-large',
                outcomeUnknown: true,
              );
            }
            bytes.addAll(chunk);
          } catch (error, stack) {
            bodyDone.completeError(error, stack);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!bodyDone.isCompleted) bodyDone.completeError(error, stack);
        },
        onDone: () {
          if (!bodyDone.isCompleted) bodyDone.complete();
        },
      );
      check();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const StaffInvitationTransportException(
          'redirect-rejected',
          outcomeUnknown: true,
        );
      }
      if ((response.contentLength ?? 0) > maxResponseBytes ||
          !RegExp(
            r'^application/json(?:\s*;\s*charset=utf-8)?$',
            caseSensitive: false,
          ).hasMatch(response.headers['content-type'] ?? '')) {
        throw const StaffInvitationTransportException(
          'invalid-response',
          outcomeUnknown: true,
        );
      }
      await bodyDone.future;
      check();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const StaffInvitationTransportException(
          'invalid-response',
          outcomeUnknown: true,
        );
      }
      if (response.statusCode != 200) {
        const codes = {
          'unauthenticated': 401,
          'permission-denied': 403,
          'invalid-argument': 400,
          'already-exists': 409,
          'failed-precondition': 409,
          'resource-exhausted': 429,
          'not-found': 404,
        };
        final code = decoded['error'];
        if (code is String &&
            codes[code] == response.statusCode &&
            decoded.keys.every((key) => key == 'error')) {
          throw StaffInvitationTransportException(code, outcomeUnknown: false);
        }
        throw const StaffInvitationTransportException(
          'unavailable',
          outcomeUnknown: true,
        );
      }
      if (decoded.containsKey('error') ||
          decoded.containsKey('outcomeUnknown')) {
        throw const StaffInvitationTransportException(
          'invalid-response',
          outcomeUnknown: true,
        );
      }
      return decoded;
    }

    Map<String, dynamic>? result;
    Object? failure;
    try {
      result = await perform().timeout(timeout);
    } catch (error) {
      failure = error is StaffInvitationTransportException
          ? error
          : StaffInvitationTransportException(
              error is TimeoutException ? 'deadline-exceeded' : 'unavailable',
              outcomeUnknown: dispatched,
            );
    }
    // Stop late request continuations. Start BOTH cancellations immediately, so
    // one stalled/throwing dependency cannot prevent the other cleanup attempt.
    active = false;
    Future<bool> cancel(FutureOr<void> Function() action) => Future<void>.sync(
      action,
    ).then((_) => true, onError: (Object _) => false);
    final cancellations = [
      cancel(() => reader?.cancel()),
      cancel(subscription.cancel),
    ];
    var cleaned = false;
    var cleanupExpired = false;
    try {
      cleaned = (await Future.wait(
        cancellations,
      ).timeout(cleanupTimeout)).every((ok) => ok);
    } on TimeoutException {
      cleanupExpired = true;
    }
    // Every cancellation future has an error observer, including late failures.
    // Retain an existing definite rejection/uncertain failure rather than masking it.
    if (failure != null) throw failure;
    if (!cleaned) {
      throw StaffInvitationTransportException(
        cleanupExpired ? 'deadline-exceeded' : 'unavailable',
        outcomeUnknown: dispatched,
      );
    }
    // Publication fence: no await follows this original-session check. The
    // composition must advance revision even when identity changes back again.
    if (changed || !session.matches(currentSession())) {
      throw StaffInvitationTransportException(
        'session-changed',
        outcomeUnknown: dispatched,
      );
    }
    onStage?.call(StaffRedeemStage.callableResponse);
    return result!;
  }

  @override
  Future<StaffInvitation> create(
    String email, {
    required CafeWorkspace workspace,
  }) async {
    try {
      final session = _session();
      final expected = captureInvitationOwnerContext(workspace, session.uid);
      return await StaffInvitationCreation.forSession(
        sessionScope,
        session.uid,
      ).issue((onStage) async {
        final id = requestId();
        if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(id)) {
          throw const StaffInvitationTransportException(
            'invalid-argument',
            outcomeUnknown: false,
          );
        }
        final operation = PendingInvitationOperation(
          projectId: projectId,
          uid: session.uid,
          requestId: id,
          expectedCafeId: workspace.cafeId,
          expectedMembershipGeneration: workspace.membershipGeneration,
        );
        var invoked = false;
        try {
          final response = await _call(
            '/staff/create',
            {'email': email, 'requestId': id, ...expected},
            session,
            onStage: (value) {
              if (value == StaffRedeemStage.callableInvocation) invoked = true;
              onStage(value);
            },
            pendingOperation: operation,
          );
          StaffInvitationCreation.validate(response, clock());
          if (!session.matches(currentSession())) {
            throw const StaffInvitationTransportException(
              'session-changed',
              outcomeUnknown: true,
            );
          }
          // This records only an originating, validated creation acknowledgement;
          // status reconciliation can never settle an unresolved journal.
          journal.recordDefiniteResponse(operation);
          return response;
        } catch (error) {
          final failure = error is StaffInvitationFailure
              ? error
              : StaffInvitationFailure.fromError(
                  StaffRedeemStage.callableInvocation,
                  error,
                );
          if (invoked &&
              !failure.outcomeUnknown &&
              [
                'unauthenticated',
                'permission-denied',
                'invalid-argument',
                'failed-precondition',
                'resource-exhausted',
                'not-found',
              ].contains(failure.code)) {
            journal.recordDefiniteResponse(operation);
          }
          rethrow;
        }
      }, clock: clock);
    } on StaffInvitationFailure {
      rethrow;
    } catch (error) {
      throw StaffInvitationFailure.fromError(
        StaffRedeemStage.callableConfig,
        error,
      );
    }
  }

  /// Reads the retained operation identity; never repairs/rebinds or clears it.
  Future<InvitationReceiptObservation> reconcile() async {
    var stage = StaffRedeemStage.callableConfig;
    try {
      final session = _session();
      final operation = await journal
          .load(projectId, session.uid)
          .timeout(timeout);
      if (operation == null) throw const InvitationRecoveryFailure();
      if (operation.state == 'pending') {
        StaffInvitationCreation.forSession(
          sessionScope,
          session.uid,
        ).requireReconciliation();
      }
      final response = await _call(
        '/staff/reconcile',
        {
          'requestId': operation.requestId,
          'expectedCafeId': operation.expectedCafeId,
          'expectedMembershipGeneration':
              operation.expectedMembershipGeneration,
        },
        session,
        onStage: (value) => stage = value,
      );
      return InvitationReceiptObservation.parse(response);
    } catch (error) {
      throw StaffInvitationFailure.fromError(stage, error);
    }
  }

  @override
  Future<void> revoke(String id, {required CafeWorkspace workspace}) async {
    try {
      final session = _session();
      final expected = captureInvitationOwnerContext(workspace, session.uid);
      await StaffInvitationAcknowledgement.confirm(
        'revoked',
        () =>
            _call('/staff/revoke', {'invitationId': id, ...expected}, session),
      );
    } on StaffInvitationFailure {
      rethrow;
    } catch (error) {
      throw StaffInvitationFailure.fromError(
        StaffRedeemStage.callableConfig,
        error,
      );
    }
  }

  @override
  Future<void> redeem(String code) async {
    try {
      final session = _session();
      await StaffInvitationAcknowledgement.confirm(
        'joined',
        () => _call('/staff/redeem', {'code': code.trim()}, session),
      );
    } on StaffInvitationFailure {
      rethrow;
    } catch (error) {
      throw StaffInvitationFailure.fromError(
        StaffRedeemStage.callableConfig,
        error,
      );
    }
  }
}
