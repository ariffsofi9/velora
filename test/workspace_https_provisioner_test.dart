import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/services/workspace_https_provisioner.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'workspace_inventory_https_transport_test.dart' show CancelStream;

WorkspaceCreationRequest request({
  String name = ' Test cafe ',
  String type = 'cafe',
}) => WorkspaceCreationRequest(
  businessName: name,
  businessType: type,
  address: 'Test street',
  inventoryUnit: 'kg',
  lowStockAlerts: true,
  expiryReminders: true,
  reminderDays: 3,
);
WorkspaceProvisioningIdentity identity({
  String uid = 'owner',
  String project = 'velora-spark-test',
  int revision = 0,
  bool verified = true,
}) => WorkspaceProvisioningIdentity(
  projectId: project,
  uid: uid,
  revision: revision,
  emailVerified: verified,
);
http.StreamedResponse response(
  Object? data, {
  int status = 200,
  String? raw,
  String contentType = 'application/json',
}) => http.StreamedResponse(
  Stream.value(utf8.encode(raw ?? jsonEncode(data))),
  status,
  headers: {'content-type': contentType},
);
http.StreamedResponse success({bool created = true}) =>
    response({'cafeId': 'new-cafe', 'created': created});

class _Client extends http.BaseClient {
  final calls = <http.BaseRequest>[];
  Future<http.StreamedResponse> Function(http.BaseRequest) handler =
      (_) async => success();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handler(request);
  }

  @override
  void close() => closed = true;
}

class _Fixture {
  final client = _Client();
  final changes = StreamController<WorkspaceProvisioningIdentity?>.broadcast(
    sync: true,
  );
  WorkspaceProvisioningIdentity? current = identity();
  Future<String?> Function(WorkspaceProvisioningIdentity) token = (_) async =>
      'synthetic.token.value';
  late final WorkspaceHttpsProvisioner adapter;
  _Fixture({
    Duration timeout = const Duration(seconds: 1),
    int maxBytes = 2048,
    Stream<WorkspaceProvisioningIdentity?>? stream,
  }) {
    adapter = WorkspaceHttpsProvisioner(
      endpoint: Uri.parse('https://backend.invalid'),
      projectId: 'velora-spark-test',
      endpointProjectId: 'velora-spark-test',
      client: client,
      currentIdentity: () => current,
      identityChanges: stream ?? changes.stream,
      idToken: (snapshot) => token(snapshot),
      timeout: timeout,
      maxResponseBytes: maxBytes,
      cleanupTimeout: const Duration(milliseconds: 15),
    );
    addTearDown(changes.close);
  }
}

Matcher failure({
  bool uncertain = true,
  WorkspaceProvisioningFailure? kind,
  String? code,
}) => isA<WorkspaceHttpsProvisioningException>()
    .having((e) => e.outcomeUncertain, 'uncertainty', uncertain)
    .having((e) => kind == null || e.failure == kind, 'failure kind', true)
    .having((e) => code == null || e.code == code, 'safe code', true)
    .having((e) => e.toString().contains('PRIVATE'), 'no raw exception', false);

WorkspaceHttpsProvisioner testConstructor(
  Uri endpoint, {
  String project = 'velora-spark-test',
  String endpointProject = 'velora-spark-test',
  Duration timeout = const Duration(seconds: 1),
}) => WorkspaceHttpsProvisioner(
  endpoint: endpoint,
  projectId: project,
  endpointProjectId: endpointProject,
  client: _Client(),
  currentIdentity: () => identity(),
  identityChanges: const Stream.empty(),
  idToken: (_) async => 'token',
  timeout: timeout,
);

void main() {
  test(
    'construction is inert and rejects invalid endpoint/project/budget configuration',
    () {
      final f = _Fixture();
      expect(f.client.calls, isEmpty);
      for (final url in [
        'http://backend.invalid',
        'https://u:p@backend.invalid',
        'https://backend.invalid/path',
        'https://backend.invalid?x=1',
        'https://backend.invalid#x',
        'https://127.0.0.1',
        'https://backend.invalid:8443',
        'https://a.localhost',
      ]) {
        expect(
          () => testConstructor(Uri.parse(url)),
          throwsA(failure(uncertain: false)),
        );
      }
      expect(
        () => testConstructor(
          Uri.parse('https://backend.invalid'),
          project: 'velora-73222',
        ),
        throwsA(failure(uncertain: false)),
      );
      expect(
        () => testConstructor(
          Uri.parse('https://backend.invalid'),
          endpointProject: 'other',
        ),
        throwsA(failure(uncertain: false)),
      );
      expect(
        () => testConstructor(
          Uri.parse('https://backend.invalid'),
          timeout: Duration.zero,
        ),
        throwsA(failure(uncertain: false)),
      );
    },
  );

  for (final created in [true, false]) {
    test(
      'canonical ${created ? 'creation' : 'existing acknowledgement'} uses exact POST without client authority or new IDs',
      () async {
        final f = _Fixture(), input = request();
        f.client.handler = (_) async => success(created: created);
        expect((await f.adapter.createWorkspace(input)).created, created);
        expect(f.client.calls, hasLength(1));
        final message = f.client.calls.single as http.Request;
        expect(
          message.url.toString(),
          'https://backend.invalid/workspace/create',
        );
        expect(message.method, 'POST');
        expect(message.followRedirects, false);
        expect(message.maxRedirects, 0);
        expect(
          message.headers['authorization'],
          'Bearer synthetic.token.value',
        );
        expect(message.headers['content-type'], startsWith('application/json'));
        expect(jsonDecode(message.body), input.toCallableData());
        expect((jsonDecode(message.body) as Map).length, 7);
        expect(f.client.closed, false);
      },
    );
  }
  for (final invalid in [
    null,
    identity(uid: ''),
    identity(uid: '../other'),
    identity(project: 'velora-73222'),
    identity(revision: -1),
    identity(verified: false),
  ]) {
    test('rejects invalid identity $invalid before dispatch', () async {
      final f = _Fixture()..current = invalid;
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure(uncertain: false)),
      );
      expect(f.client.calls, isEmpty);
    });
  }
  for (final token in <String?>[null, '', 'Bearer secret', 'bad\ntoken']) {
    test('rejects malformed token without dispatch: $token', () async {
      final f = _Fixture();
      f.token = (_) async => token;
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure(uncertain: false)),
      );
      expect(f.client.calls, isEmpty);
    });
  }
  for (final ack in [
    null,
    [],
    {},
    {'created': true},
    {'cafeId': 'cafe'},
    {'cafeId': '../other', 'created': true},
    {'cafeId': 'cafe', 'created': 1},
    {'cafeId': 'cafe', 'created': true, 'error': 'PRIVATE'},
    {'cafeId': 'cafe', 'created': true, 'outcomeUnknown': true},
  ]) {
    test('malformed acknowledgement is unknown: $ack', () async {
      final f = _Fixture();
      f.client.handler = (_) async => response(ack);
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure()),
      );
      expect(f.client.calls, hasLength(1));
    });
  }
  for (final variant in [
    'json',
    'utf8',
    'type',
    'size',
    'redirect',
    'stream-error',
  ]) {
    test('rejects $variant response without retry', () async {
      final f = _Fixture(maxBytes: 100);
      f.client.handler = (_) async => switch (variant) {
        'json' => response(null, raw: '{PRIVATE'),
        'utf8' => http.StreamedResponse(
          Stream.value([255]),
          200,
          headers: {'content-type': 'application/json'},
        ),
        'type' => response({
          'cafeId': 'cafe',
          'created': true,
        }, contentType: 'text/html'),
        'size' => response(null, raw: 'x' * 101),
        'redirect' => response({}, status: 302),
        _ => http.StreamedResponse(
          Stream.error(StateError('PRIVATE')),
          200,
          headers: {'content-type': 'application/json'},
        ),
      };
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure()),
      );
      expect(f.client.calls, hasLength(1));
    });
  }
  const statuses = {
    'unauthenticated': 401,
    'permission-denied': 403,
    'invalid-argument': 400,
    'already-exists': 409,
    'failed-precondition': 409,
    'resource-exhausted': 429,
    'deadline-exceeded': 408,
  };
  for (final entry in statuses.entries) {
    test('strict canonical rejection ${entry.key} is definite', () async {
      final f = _Fixture();
      f.client.handler = (_) async =>
          response({'error': entry.key}, status: entry.value);
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure(uncertain: false, code: entry.key)),
      );
      expect(f.client.calls, hasLength(1));
    });
  }
  for (final data in [
    {'error': 'unavailable', 'outcomeUnknown': true},
    {'error': 'permission-denied', 'details': 'PRIVATE'},
    {'error': 'not-a-domain-error'},
  ]) {
    test('unknown or forged HTTP error stays uncertain: $data', () async {
      final f = _Fixture();
      f.client.handler = (_) async => response(data, status: 503);
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure()),
      );
    });
  }
  test(
    'pre-token failure is definite; post-send network failure is unknown and sanitized',
    () async {
      final f = _Fixture();
      f.token = (_) async => throw StateError('PRIVATE');
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure(uncertain: false)),
      );
      expect(f.client.calls, isEmpty);
      f.token = (_) async => 'synthetic';
      f.client.handler = (_) async => throw StateError('PRIVATE');
      await expectLater(
        f.adapter.createWorkspace(request()),
        throwsA(failure()),
      );
      expect(f.client.calls, hasLength(1));
    },
  );
  for (final phase in ['token', 'headers', 'body']) {
    test(
      '$phase timeout is bounded and late work cannot publish or dispatch',
      () async {
        final f = _Fixture(timeout: const Duration(milliseconds: 15));
        final token = Completer<String?>(),
            headers = Completer<http.StreamedResponse>();
        final body = StreamController<List<int>>();
        if (phase == 'token') f.token = (_) => token.future;
        if (phase == 'headers') f.client.handler = (_) => headers.future;
        if (phase == 'body') {
          f.client.handler = (_) async => http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        await expectLater(
          f.adapter.createWorkspace(request()),
          throwsA(
            failure(
              uncertain: phase != 'token',
              kind: WorkspaceProvisioningFailure.timedOut,
            ),
          ),
        );
        token.complete('synthetic');
        headers.complete(success());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(f.client.calls.length, phase == 'token' ? 0 : 1);
        if (phase == 'body') {
          await body.close();
        } else {
          unawaited(body.close());
        }
      },
    );
  }
  for (final phase in ['token', 'response']) {
    test('session transition during $phase suppresses late result', () async {
      final f = _Fixture(),
          token = Completer<String?>(),
          headers = Completer<http.StreamedResponse>();
      if (phase == 'token') {
        f.token = (_) => token.future;
      } else {
        f.client.handler = (_) => headers.future;
      }
      final pending = f.adapter.createWorkspace(request());
      await Future<void>.delayed(Duration.zero);
      f.changes.add(null);
      f.current = identity(revision: 1);
      f.changes.add(f.current);
      final check = expectLater(
        pending,
        throwsA(
          failure(uncertain: phase == 'response', code: 'session-changed'),
        ),
      );
      token.complete('synthetic');
      headers.complete(success());
      await check;
      expect(f.client.calls.length, phase == 'token' ? 0 : 1);
    });
  }
  test(
    'a request cannot adopt another identity episode, even through another adapter',
    () async {
      final f = _Fixture(), input = request();
      await f.adapter.createWorkspace(input);
      final g = _Fixture()..current = identity(revision: 1);
      await expectLater(
        g.adapter.createWorkspace(input),
        throwsA(failure(uncertain: false, code: 'request-context-changed')),
      );
      expect(g.client.calls, isEmpty);
    },
  );
  test(
    'later definite rejection and missing identity cannot erase earlier uncertainty',
    () async {
      final f = _Fixture(), input = request();
      f.client.handler = (_) async => throw StateError('PRIVATE');
      await expectLater(f.adapter.createWorkspace(input), throwsA(failure()));
      f.client.handler = (_) async =>
          response({'error': 'permission-denied'}, status: 403);
      await expectLater(
        f.adapter.createWorkspace(input),
        throwsA(failure(code: 'permission-denied')),
      );
      f.current = null;
      await expectLater(f.adapter.createWorkspace(input), throwsA(failure()));
      expect(f.client.calls, hasLength(2));
    },
  );
  test(
    'explicit unchanged retry retains payload and accepts server prior-ownership acknowledgement',
    () async {
      final f = _Fixture(), input = request();
      f.client.handler = (_) async => throw StateError('PRIVATE');
      await expectLater(f.adapter.createWorkspace(input), throwsA(failure()));
      expect(f.client.calls, hasLength(1));
      f.client.handler = (_) async => success(created: false);
      expect((await f.adapter.createWorkspace(input)).created, false);
      expect(f.client.calls, hasLength(2));
      expect(
        (f.client.calls[0] as http.Request).body,
        (f.client.calls[1] as http.Request).body,
      );
    },
  );
  test('concurrent same-request calls do not dispatch twice', () async {
    final f = _Fixture(),
        input = request(),
        gate = Completer<http.StreamedResponse>();
    f.client.handler = (_) => gate.future;
    final first = f.adapter.createWorkspace(input);
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      f.adapter.createWorkspace(input),
      throwsA(failure(code: 'request-in-flight')),
    );
    gate.complete(success());
    expect((await first).created, true);
    expect(f.client.calls, hasLength(1));
  });
  test(
    'cleanup failure and identity changes during cleanup suppress acknowledged success',
    () async {
      for (final throwing in [false, true]) {
        final f = _Fixture(
          stream: CancelStream<WorkspaceProvisioningIdentity?>(
            const Stream.empty(),
            () async {},
          ),
        );
        // Use a non-closing identity source so onDone is not an identity transition.
        final adapter = WorkspaceHttpsProvisioner(
          endpoint: Uri.parse('https://backend.invalid'),
          projectId: 'velora-spark-test',
          endpointProjectId: 'velora-spark-test',
          client: f.client,
          currentIdentity: () => f.current,
          idToken: (_) async => 'synthetic',
          identityChanges: CancelStream(f.changes.stream, () async {
            if (throwing) throw StateError('PRIVATE');
            f.current = identity(revision: 1);
          }),
        );
        await expectLater(
          adapter.createWorkspace(request()),
          throwsA(failure()),
        );
        expect(f.client.calls, hasLength(1));
        expect(f.client.closed, false);
      }
    },
  );
}
