import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/staff_invitation_service.dart';
import 'package:velora/services/staff_invitation_https_transport.dart';
import 'package:velora/services/invitation_recovery_service.dart';

class _JournalStore implements InvitationJournalPersistence {
  Object? value;
  bool fail = false;
  bool failWrite = false;
  int writes = 0;
  @override
  Future<Object?> read(String projectId, String uid) async {
    if (fail) throw StateError('synthetic persistence failure');
    return value == null ? null : jsonDecode(jsonEncode(value));
  }

  @override
  Future<bool> compareAndSet(
    String projectId,
    String uid,
    Object? expected,
    Map<String, Object> next,
  ) async {
    if (fail || failWrite) throw StateError('synthetic persistence failure');
    if (jsonEncode(value) != jsonEncode(expected)) return false;
    value = jsonDecode(jsonEncode(next));
    writes++;
    return true;
  }
}

class _Client extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  _Client(this.respond);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

/// A real stream with a deliberately delayed/failing cancellation dependency.
class _CancelStream<T> extends Stream<T> {
  final Stream<T> source;
  final FutureOr<void> Function() onCancel;
  _CancelStream(this.source, this.onCancel);
  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _CancelSubscription(
    source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    onCancel,
  );
}

class _CancelSubscription<T> implements StreamSubscription<T> {
  final StreamSubscription<T> source;
  final FutureOr<void> Function() onCancel;
  Future<void>? _cancellation;
  _CancelSubscription(this.source, this.onCancel);
  @override
  Future<void> cancel() => _cancellation ??= _cancel();
  Future<void> _cancel() async {
    await source.cancel();
    await onCancel();
  }

  @override
  void onData(void Function(T)? handler) => source.onData(handler);
  @override
  void onError(Function? handler) => source.onError(handler);
  @override
  void onDone(void Function()? handler) => source.onDone(handler);
  @override
  void pause([Future<void>? resumeSignal]) => source.pause(resumeSignal);
  @override
  void resume() => source.resume();
  @override
  bool get isPaused => source.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => source.asFuture(futureValue);
}

const _session = InvitationHttpsSession(
  uid: 'owner',
  projectId: 'velora-spark-test',
  revision: 0,
  emailVerified: true,
);
const _workspace = CafeWorkspace(
  cafeId: 'cafe',
  uid: 'owner',
  ownerUid: 'owner',
  role: CafeRole.owner,
  membershipGeneration: 7,
);
final _now = DateTime.utc(2026, 11, 11);
final _creation = {
  'invitationId': 'a' * 32,
  'code': '${'a' * 32}.${'b' * 64}',
  'expiresAt': '2026-11-12T00:00:00.000Z',
};
http.StreamedResponse _response(
  Object? body, {
  int status = 200,
  Map<String, String>? headers,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: headers ?? {'content-type': 'application/json'},
);
Matcher _failure({bool unknown = true, String? code}) =>
    isA<StaffInvitationFailure>()
        .having((e) => e.outcomeUnknown, 'outcomeUnknown', unknown)
        .having((e) => code == null || e.code == code, 'code matches', true);

class _Harness {
  InvitationHttpsSession? session = _session;
  final events = StreamController<InvitationHttpsSession?>.broadcast(
    sync: true,
  );
  final scope = Object();
  final journalStore = _JournalStore();
  int calls = 0, ids = 0;
  String nextRequestId = 'request_123456789';
  final requests = <http.Request>[];
  Future<String?> Function(InvitationHttpsSession) token = (_) async =>
      'synthetic.jwt.token';
  Future<http.StreamedResponse> Function(http.BaseRequest)? response;
  Stream<InvitationHttpsSession?>? eventStream;
  late final client = _Client((request) async {
    calls++;
    requests.add(request as http.Request);
    return response == null ? _response(_creation) : response!(request);
  });
  HttpsStaffInvitations service({
    Duration timeout = const Duration(seconds: 1),
    Duration cleanupTimeout = const Duration(milliseconds: 100),
    int limit = 65536,
    Object? scopeOverride,
  }) => HttpsStaffInvitations(
    endpoint: Uri.parse('https://test-api.example.invalid'),
    projectId: 'velora-spark-test',
    endpointProjectId: 'velora-spark-test',
    client: client,
    currentSession: () => session,
    sessionChanges: eventStream ?? events.stream,
    idToken: (s) => token(s),
    sessionScope: scopeOverride ?? scope,
    requestId: () {
      ids++;
      return nextRequestId;
    },
    clock: () => _now,
    timeout: timeout,
    cleanupTimeout: cleanupTimeout,
    maxResponseBytes: limit,
    journal: InvitationRecoveryJournal(journalStore),
  );
  Future<void> close() async {
    await events.close();
    client.close();
  }
}

void main() {
  const pending = PendingInvitationOperation(
    projectId: 'velora-spark-test',
    uid: 'owner',
    requestId: 'request_123456789',
    expectedCafeId: 'cafe',
    expectedMembershipGeneration: 7,
  );
  test(
    'journal persistence completes before create dispatch and contains no secrets',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.response = (_) async {
        expect(h.journalStore.value, pending.toJson());
        return _response(_creation);
      };
      await h.service().create('private@example.test', workspace: _workspace);
      expect((h.journalStore.value as Map)['state'], 'pending');
      final serialized = jsonEncode(h.journalStore.value);
      expect(serialized, isNot(contains('private@example.test')));
      expect(serialized, isNot(contains(_creation['code']!)));
      expect(serialized, isNot(contains('synthetic.jwt.token')));
    },
  );
  test('journal failure prevents dispatch', () async {
    final h = _Harness();
    addTearDown(h.close);
    h.journalStore.failWrite = true;
    await expectLater(
      h.service().create('x@example.test', workspace: _workspace),
      throwsA(_failure(unknown: false)),
    );
    expect(h.calls, 0);
  });
  test(
    'pre-dispatch identity failure cannot settle a retained uncertain request',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.journalStore.value = pending.toJson();
      h.token = (_) async => null;
      await expectLater(
        h.service().create('x@example.test', workspace: _workspace),
        throwsA(_failure(unknown: false)),
      );
      h.token = (_) async => 'synthetic.jwt.token';
      h.nextRequestId = 'next_request_123456789';
      await expectLater(
        h.service().create('x@example.test', workspace: _workspace),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(h.calls, 0);
      expect(h.journalStore.value, pending.toJson());
    },
  );
  test(
    'direct validated success permits a later explicit creation in the same process',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final service = h.service();
      await service.create('x@example.test', workspace: _workspace);
      expect(h.calls, 1);
      h.nextRequestId = 'next_request_123456789';
      await service.create('y@example.test', workspace: _workspace);
      expect(h.calls, 2);
      expect((h.journalStore.value as Map)['requestId'], h.nextRequestId);
      expect((h.journalStore.value as Map)['state'], 'pending');
    },
  );
  test(
    'lost response followed by fresh service scope remains blocked by retained journal',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.response = (_) async => _response({
        'error': 'unavailable',
        'outcomeUnknown': true,
      }, status: 503);
      await expectLater(
        h.service().create('x@example.test', workspace: _workspace),
        throwsA(_failure()),
      );
      final restored = h.service(scopeOverride: Object());
      await expectLater(
        restored.create('x@example.test', workspace: _workspace),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(h.calls, 1);
      expect(h.journalStore.value, pending.toJson());
    },
  );
  test(
    'unknown followed by committed observation never clears or replays creation',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.journalStore.value = pending.toJson();
      var reads = 0;
      h.response = (_) async => _response(
        reads++ == 0
            ? {'state': 'unknown'}
            : {'state': 'committed', 'invitationState': 'pending'},
      );
      final service = h.service(scopeOverride: Object());
      expect((await service.reconcile()).state, 'unknown');
      expect((await service.reconcile()).state, 'committed');
      expect(h.journalStore.value, pending.toJson());
      expect(h.journalStore.writes, 0);
      expect(service.creationBlocked, true);
      expect(h.requests.every((r) => r.url.path == '/staff/reconcile'), true);
      expect(jsonDecode(h.requests.first.body), {
        'requestId': pending.requestId,
        'expectedCafeId': 'cafe',
        'expectedMembershipGeneration': 7,
      });
      await expectLater(
        service.create('x@example.test', workspace: _workspace),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(h.calls, 2);
    },
  );
  for (final patch in [
    <String, Object?>{'version': 99},
    {'uid': 'other'},
    {'projectId': 'velora-73222'},
    {'code': 'secret'},
  ]) {
    test('invalid journal prevents reconciliation dispatch: $patch', () async {
      final h = _Harness();
      addTearDown(h.close);
      h.journalStore.value = {...pending.toJson(), ...patch};
      await expectLater(
        h.service().reconcile(),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(h.calls, 0);
    });
  }
  for (final response in [
    null,
    {'state': 'committed'},
    {'state': 'unknown', 'code': 'secret'},
  ]) {
    test(
      'invalid reconciliation response leaves journal blocked: $response',
      () async {
        final h = _Harness();
        addTearDown(h.close);
        h.journalStore.value = pending.toJson();
        h.response = (_) async => _response(response);
        final service = h.service();
        await expectLater(
          service.reconcile(),
          throwsA(isA<StaffInvitationFailure>()),
        );
        expect(service.creationBlocked, true);
        expect(h.journalStore.value, pending.toJson());
        expect(h.calls, 1);
      },
    );
  }
  test(
    'session transition during reconciliation rejects late result',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.journalStore.value = pending.toJson();
      final entered = Completer<void>(),
          response = Completer<http.StreamedResponse>();
      h.response = (_) {
        entered.complete();
        return response.future;
      };
      final assertion = expectLater(
        h.service().reconcile(),
        throwsA(_failure()),
      );
      await entered.future;
      h.events.add(null);
      response.complete(
        _response({'state': 'committed', 'invitationState': 'revoked'}),
      );
      await assertion;
      expect(h.journalStore.value, pending.toJson());
      expect(h.calls, 1);
    },
  );
  test(
    'reconciliation timeout remains blocked without mutation replay',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.journalStore.value = pending.toJson();
      h.response = (_) => Completer<http.StreamedResponse>().future;
      final service = h.service(timeout: const Duration(milliseconds: 20));
      await expectLater(
        service.reconcile(),
        throwsA(_failure(code: 'deadline-exceeded')),
      );
      expect(h.calls, 1);
      expect(h.journalStore.value, pending.toJson());
      expect(service.creationBlocked, true);
    },
  );
  Future<Object?> invoke(HttpsStaffInvitations service, String action) =>
      switch (action) {
        'create' => service.create('x@example.test', workspace: _workspace),
        'revoke' => service.revoke('a' * 32, workspace: _workspace),
        _ => service.redeem('code'),
      };
  Object success(String action) => action == 'create'
      ? _creation
      : action == 'revoke'
      ? {'revoked': true}
      : {'joined': true};
  for (final phase in ['response', 'session']) {
    for (final action in ['create', 'revoke', 'redeem']) {
      test(
        'revision transition during $phase cancellation rejects $action success',
        () async {
          final h = _Harness();
          addTearDown(h.close);
          final entered = Completer<void>(), release = Completer<void>();
          Future<void> delay() {
            entered.complete();
            return release.future;
          }

          h.eventStream = _CancelStream(
            h.events.stream,
            phase == 'session' ? delay : () {},
          );
          h.response = (_) async => http.StreamedResponse(
            _CancelStream(
              Stream.value(utf8.encode(jsonEncode(success(action)))),
              phase == 'response' ? delay : () {},
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
          final service = h.service();
          final assertion = expectLater(
            invoke(service, action),
            throwsA(_failure()),
          );
          await entered.future;
          h.session = const InvitationHttpsSession(
            uid: 'owner',
            projectId: 'velora-spark-test',
            revision: 1,
            emailVerified: true,
          );
          release.complete();
          await assertion;
          expect(h.calls, 1);
          expect(h.events.hasListener, false);
          if (action == 'create') expect(service.creationBlocked, true);
        },
      );
    }
    for (final behavior in ['stall', 'throw']) {
      test(
        '$phase cancellation $behavior is bounded and both cleanups attempted',
        () async {
          final h = _Harness();
          addTearDown(h.close);
          final late = Completer<void>();
          var responseCancels = 0, sessionCancels = 0;
          FutureOr<void> fault() {
            if (behavior == 'throw') {
              throw StateError('synthetic cancellation failure');
            }
            return late.future;
          }

          h.eventStream = _CancelStream(h.events.stream, () {
            sessionCancels++;
            if (phase == 'session') return fault();
          });
          h.response = (_) async => http.StreamedResponse(
            _CancelStream(Stream.value(utf8.encode(jsonEncode(_creation))), () {
              responseCancels++;
              if (phase == 'response') return fault();
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
          final service = h.service(
            timeout: const Duration(milliseconds: 50),
            cleanupTimeout: const Duration(milliseconds: 20),
          );
          expect(service.completionBudget, const Duration(milliseconds: 70));
          var completed = false;
          final assertion =
              expectLater(
                service.create('x@example.test', workspace: _workspace),
                throwsA(
                  _failure(
                    code: behavior == 'stall'
                        ? 'deadline-exceeded'
                        : 'unavailable',
                  ),
                ),
              ).then((_) {
                completed = true;
              });
          await assertion.timeout(
            service.completionBudget + const Duration(seconds: 1),
          );
          expect(completed, true);
          await assertion;
          expect(responseCancels, 1);
          expect(sessionCancels, 1);
          expect(h.events.hasListener, false);
          expect(service.creationBlocked, true);
          // Only the stalled case consumes the future; do not create an orphan error.
          if (behavior == 'throw') late.future.catchError((Object _) {});
          late.completeError(StateError('late cancellation failure'));
          await Future<void>.delayed(Duration.zero);
          expect(h.calls, 1);
        },
      );
    }
  }
  test(
    'dispatch timeout plus stalled cancellation settles within total budget',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      var cancelled = 0;
      final pending = Completer<void>();
      h.eventStream = _CancelStream(h.events.stream, () {
        cancelled++;
        return pending.future;
      });
      h.response = (_) => Completer<http.StreamedResponse>().future;
      final service = h.service(
        timeout: const Duration(milliseconds: 30),
        cleanupTimeout: const Duration(milliseconds: 20),
      );
      var completed = false;
      final assertion =
          expectLater(
            service.create('x@example.test', workspace: _workspace),
            throwsA(_failure(code: 'deadline-exceeded')),
          ).then((_) {
            completed = true;
          });
      await assertion.timeout(
        service.completionBudget + const Duration(seconds: 1),
      );
      expect(completed, true);
      await assertion;
      expect(cancelled, 1);
      expect(h.calls, 1);
      expect(service.creationBlocked, true);
      pending.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );
  test(
    'definite rejection survives throwing cleanup without becoming success',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.eventStream = _CancelStream(h.events.stream, () {
        throw StateError('cleanup');
      });
      h.response = (_) async =>
          _response({'error': 'permission-denied'}, status: 403);
      final service = h.service();
      await expectLater(
        service.create('x@example.test', workspace: _workspace),
        throwsA(_failure(unknown: false, code: 'permission-denied')),
      );
      expect(h.calls, 1);
      expect(service.creationBlocked, false);
    },
  );
  test(
    'URI normalization removes empty userinfo without changing destination',
    () {
      final endpoint = Uri.parse('https://@api.example.invalid');
      expect(endpoint.userInfo, isEmpty);
      expect(endpoint.authority, 'api.example.invalid');
      expect(
        endpoint.resolve('/staff/create').toString(),
        'https://api.example.invalid/staff/create',
      );
    },
  );
  test(
    'redirect rejection cancels response stream and session subscription',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      addTearDown(body.close);
      h.response = (_) async => http.StreamedResponse(body.stream, 307);
      await expectLater(
        h.service().create('x@example.test', workspace: _workspace),
        throwsA(_failure()),
      );
      expect(cancelled, true);
      expect(h.events.hasListener, false);
      expect(h.calls, 1);
    },
  );
  test(
    'stalled response body times out and cancels listeners without retry',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      addTearDown(body.close);
      h.response = (_) async => http.StreamedResponse(
        body.stream,
        200,
        headers: {'content-type': 'application/json'},
      );
      await expectLater(
        h
            .service(timeout: const Duration(milliseconds: 20))
            .create('x@example.test', workspace: _workspace),
        throwsA(_failure()),
      );
      expect(cancelled, true);
      expect(h.events.hasListener, false);
      expect(h.calls, 1);
      expect(h.service().creationBlocked, true);
    },
  );
  test('session stream errors fail closed during pending response', () async {
    final h = _Harness();
    addTearDown(h.close);
    final pending = Completer<http.StreamedResponse>();
    final entered = Completer<void>();
    h.response = (_) {
      entered.complete();
      return pending.future;
    };
    final assertion = expectLater(
      h.service().create('x@example.test', workspace: _workspace),
      throwsA(_failure()),
    );
    await entered.future;
    h.events.addError(StateError('synthetic error'));
    pending.complete(_response(_creation));
    await assertion;
    expect(h.calls, 1);
    expect(h.events.hasListener, false);
  });
  for (final url in [
    'http://api.example.invalid',
    'https://user:password@api.example.invalid',
    'https://api.example.invalid/path',
    'https://api.example.invalid?x=1',
    'https://api.example.invalid#x',
    'https://api.example.invalid:8443',
    'https://127.0.0.1',
    'https://localhost',
    'https://api..example.invalid',
    'https://-api.example.invalid',
  ]) {
    test('reject unsafe endpoint $url', () {
      final h = _Harness();
      addTearDown(h.close);
      expect(
        () => HttpsStaffInvitations(
          journal: InvitationRecoveryJournal(h.journalStore),
          endpoint: Uri.parse(url),
          projectId: 'velora-spark-test',
          endpointProjectId: 'velora-spark-test',
          client: h.client,
          currentSession: () => h.session,
          sessionChanges: h.events.stream,
          idToken: h.token,
          sessionScope: h.scope,
          requestId: () => 'request_123456789',
          clock: () => _now,
        ),
        throwsA(isA<StaffInvitationTransportException>()),
      );
    });
  }
  test('endpoint environment binding rejects mismatch', () {
    final h = _Harness();
    addTearDown(h.close);
    expect(
      () => HttpsStaffInvitations(
        journal: InvitationRecoveryJournal(h.journalStore),
        endpoint: Uri.parse('https://api.example.invalid'),
        projectId: 'velora-spark-test',
        endpointProjectId: 'velora-73222',
        client: h.client,
        currentSession: () => h.session,
        sessionChanges: h.events.stream,
        idToken: h.token,
        sessionScope: h.scope,
        requestId: () => 'request_123456789',
        clock: () => _now,
      ),
      throwsA(isA<StaffInvitationTransportException>()),
    );
  });
  test(
    'create forwards current token exact request ID and captured generation once',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final result = await h.service().create(
        'joiner@example.test',
        workspace: _workspace,
      );
      expect(result.id, _creation['invitationId']);
      expect(h.calls, 1);
      expect(h.ids, 1);
      final request = h.requests.single;
      expect(request.url.path, '/staff/create');
      expect(request.followRedirects, false);
      expect(request.maxRedirects, 0);
      expect(request.headers['authorization'], 'Bearer synthetic.jwt.token');
      expect(jsonDecode(request.body), {
        'email': 'joiner@example.test',
        'requestId': 'request_123456789',
        'expectedCafeId': 'cafe',
        'expectedMembershipGeneration': 7,
      });
      expect(h.events.hasListener, false);
    },
  );
  test(
    'revoke and redeem preserve exact contracts and literal acknowledgements',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      h.response = (r) async => _response(
        r.url.path.endsWith('revoke')
            ? {'revoked': true}
            : {'joined': true, 'cafeId': 'cafe'},
      );
      final service = h.service();
      await service.revoke('a' * 32, workspace: _workspace);
      await service.redeem(' code ');
      expect(jsonDecode(h.requests[0].body), {
        'invitationId': 'a' * 32,
        'expectedCafeId': 'cafe',
        'expectedMembershipGeneration': 7,
      });
      expect(jsonDecode(h.requests[1].body), {'code': 'code'});
      expect(h.calls, 2);
    },
  );
  for (final session in [
    null,
    const InvitationHttpsSession(
      uid: 'owner',
      projectId: 'velora-73222',
      revision: 0,
      emailVerified: true,
    ),
    const InvitationHttpsSession(
      uid: 'owner',
      projectId: 'velora-spark-test',
      revision: 0,
      emailVerified: false,
    ),
  ]) {
    test(
      'missing wrong-project or unverified session never dispatches: ${session?.projectId}/${session?.emailVerified}',
      () async {
        final h = _Harness();
        addTearDown(h.close);
        h.session = session;
        await expectLater(
          h.service().create('x@example.test', workspace: _workspace),
          throwsA(_failure(unknown: false)),
        );
        expect(h.calls, 0);
      },
    );
  }
  test('Staff context cannot invoke Owner operation', () async {
    final h = _Harness();
    addTearDown(h.close);
    const staff = CafeWorkspace(
      cafeId: 'cafe',
      uid: 'owner',
      ownerUid: 'another',
      role: CafeRole.staff,
    );
    await expectLater(
      h.service().create('x@example.test', workspace: staff),
      throwsA(_failure(unknown: false)),
    );
    expect(h.calls, 0);
  });
  test('missing or header-injecting token never dispatches', () async {
    for (final token in [null, 'secret\r\nheader']) {
      final h = _Harness();
      addTearDown(h.close);
      h.token = (_) async => token;
      await expectLater(
        h.service().create('x@example.test', workspace: _workspace),
        throwsA(_failure(unknown: false)),
      );
      expect(h.calls, 0);
    }
  });
  for (final entry in {
    'unauthenticated': 401,
    'permission-denied': 403,
    'failed-precondition': 409,
  }.entries) {
    test(
      'HTTP ${entry.value} ${entry.key} is typed definite rejection without replay',
      () async {
        final h = _Harness();
        addTearDown(h.close);
        h.response = (_) async =>
            _response({'error': entry.key}, status: entry.value);
        final service = h.service();
        await expectLater(
          service.create('x@example.test', workspace: _workspace),
          throwsA(_failure(unknown: false, code: entry.key)),
        );
        expect(h.calls, 1);
        expect(service.creationBlocked, false);
      },
    );
  }
  for (final status in [302, 307, 500, 503]) {
    test(
      'HTTP $status is uncertain and blocks fresh issuance across reconstruction',
      () async {
        final h = _Harness();
        addTearDown(h.close);
        h.response = (_) async =>
            _response({'error': 'unavailable'}, status: status);
        await expectLater(
          h.service().create('x@example.test', workspace: _workspace),
          throwsA(_failure()),
        );
        expect(h.service().creationBlocked, true);
        await expectLater(
          h.service().create('x@example.test', workspace: _workspace),
          throwsA(_failure()),
        );
        expect(h.calls, 1);
        expect(h.events.hasListener, false);
      },
    );
  }
  test('duplicate receipt is not recovered success', () async {
    final h = _Harness();
    addTearDown(h.close);
    h.response = (_) async =>
        _response({'error': 'already-exists'}, status: 409);
    await expectLater(
      h.service().create('x@example.test', workspace: _workspace),
      throwsA(_failure(code: 'already-exists')),
    );
    expect(h.service().creationBlocked, true);
    expect(h.calls, 1);
  });
  for (final body in [
    null,
    [],
    {},
    {'invitationId': 'bad'},
    {'error': 'unavailable'},
    {'joined': 'true'},
  ]) {
    test('invalid creation acknowledgement blocks issuance: $body', () async {
      final h = _Harness();
      addTearDown(h.close);
      h.response = (_) async => _response(body);
      await expectLater(
        h.service().create('x@example.test', workspace: _workspace),
        throwsA(_failure()),
      );
      expect(h.service().creationBlocked, true);
      expect(h.calls, 1);
    });
  }
  test('revoke and redeem reject truthy acknowledgement', () async {
    final h = _Harness();
    addTearDown(h.close);
    h.response = (_) async => _response({'revoked': 1, 'joined': 'true'});
    await expectLater(
      h.service().revoke('a' * 32, workspace: _workspace),
      throwsA(_failure()),
    );
    await expectLater(h.service().redeem('code'), throwsA(_failure()));
    expect(h.calls, 2);
  });
  test('oversized streamed response is rejected', () async {
    final h = _Harness();
    addTearDown(h.close);
    h.response = (_) async => _response(_creation);
    await expectLater(
      h.service(limit: 16).create('x@example.test', workspace: _workspace),
      throwsA(_failure()),
    );
    expect(h.calls, 1);
  });
  test(
    'timeout never retries and late acknowledgement cannot unblock creation',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final pending = Completer<http.StreamedResponse>();
      h.response = (_) => pending.future;
      await expectLater(
        h
            .service(timeout: const Duration(milliseconds: 20))
            .create('x@example.test', workspace: _workspace),
        throwsA(_failure(code: 'deadline-exceeded')),
      );
      pending.complete(_response(_creation));
      await Future<void>.delayed(Duration.zero);
      expect(h.service().creationBlocked, true);
      expect(h.calls, 1);
    },
  );
  test(
    'session change and return to original identity cannot accept late success',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      final pending = Completer<http.StreamedResponse>();
      final entered = Completer<void>();
      h.response = (_) {
        entered.complete();
        return pending.future;
      };
      final future = h.service().create(
        'x@example.test',
        workspace: _workspace,
      );
      final assertion = expectLater(future, throwsA(_failure()));
      await entered.future;
      h.events.add(null);
      h.events.add(_session);
      pending.complete(_response(_creation));
      await assertion;
      expect(h.calls, 1);
      expect(h.service().creationBlocked, true);
      expect(h.events.hasListener, false);
    },
  );
  test('session change during token lookup stops dispatch', () async {
    final h = _Harness();
    addTearDown(h.close);
    final token = Completer<String?>();
    final entered = Completer<void>();
    h.token = (_) {
      entered.complete();
      return token.future;
    };
    final assertion = expectLater(
      h.service().create('x@example.test', workspace: _workspace),
      throwsA(_failure(unknown: false)),
    );
    await entered.future;
    h.events.add(null);
    token.complete('synthetic.jwt.token');
    await assertion;
    expect(h.calls, 0);
    expect(h.events.hasListener, false);
  });
}
