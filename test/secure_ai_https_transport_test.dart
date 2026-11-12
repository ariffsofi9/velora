import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/secure_ai_https_transport.dart';
import 'package:velora/services/secure_ai_service.dart';
import 'package:velora/services/workspace_session.dart';
import 'workspace_inventory_https_transport_test.dart' show CancelStream;

const ticketId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final contract =
    jsonDecode(
          File(
            'test/fixtures/secure_ai_callable_contract.json',
          ).readAsStringSync(),
        )
        as Map;
Map<String, dynamic> generation() => Map<String, dynamic>.from(
  jsonDecode(jsonEncode(contract['generateResponse'])) as Map,
);
WorkspaceSession workspace({
  CafeRole role = CafeRole.owner,
  String cafe = 'cafe',
  int generation = 7,
}) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafe,
    uid: role == CafeRole.owner ? 'owner' : 'staff',
    ownerUid: 'owner',
    role: role,
    membershipGeneration: generation,
  ),
);
SecureAiHttpsSession session(
  WorkspaceSession w, {
  String project = 'velora-spark-test',
  int revision = 0,
  bool verified = true,
  String? uid,
}) => SecureAiHttpsSession(
  uid: uid ?? w.uid,
  projectId: project,
  revision: revision,
  emailVerified: verified,
  workspace: w,
);
http.StreamedResponse response(
  Object? value, {
  int status = 200,
  String? raw,
  String type = 'application/json',
}) => http.StreamedResponse(
  Stream.value(utf8.encode(raw ?? jsonEncode(value))),
  status,
  headers: {'content-type': type},
);

class _Client extends http.BaseClient {
  final calls = <http.BaseRequest>[];
  bool closed = false;
  late Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handle(request);
  }

  @override
  void close() => closed = true;
}

class _Fixture {
  final client = _Client();
  final changes = StreamController<SecureAiHttpsSession?>.broadcast(sync: true);
  final Object scope = Object();
  final WorkspaceSession w;
  int time = 1000000;
  late SecureAiHttpsSession? current;
  late final SecureAiHttpsTransport transport;
  Future<String?> Function(SecureAiHttpsSession) token = (_) async =>
      'synthetic.token.value';
  _Fixture({
    CafeRole role = CafeRole.owner,
    Duration timeout = const Duration(seconds: 1),
  }) : w = workspace(role: role) {
    current = session(w);
    client.handle = (r) async =>
        response(r.url.path == '/ai/issue' ? issued() : generation());
    transport = build(timeout: timeout);
    addTearDown(changes.close);
  }
  Map<String, Object> issued() => {
    'schemaVersion': 2,
    'ticketId': ticketId,
    'expiresAt': time + 300000,
  };
  Map<String, Object> data(String op, {int max = 1}) => {
    'operation': op,
    'expectedCafeId': w.cafeId,
    'expectedMembershipGeneration': w.membershipGeneration,
    'maxRecipes': max,
    if (op == 'generate') 'ticketId': ticketId,
  };
  SecureAiHttpsTransport build({
    bool enabled = true,
    Duration timeout = const Duration(seconds: 1),
    Stream<SecureAiHttpsSession?>? stream,
  }) => SecureAiHttpsTransport(
    endpoint: Uri.parse('https://backend.invalid'),
    projectId: 'velora-spark-test',
    endpointProjectId: 'velora-spark-test',
    client: client,
    currentSession: () => current,
    sessionChanges: stream ?? changes.stream,
    idToken: (s) => token(s),
    sessionScope: scope,
    now: () => time,
    enabled: enabled,
    timeout: timeout,
    cleanupTimeout: const Duration(milliseconds: 10),
  );
  Future<Object?> issue({int max = 1}) =>
      transport.call(data('issue', max: max));
  Future<Object?> generate({int max = 1}) =>
      transport.call(data('generate', max: max));
}

Matcher failure({bool unknown = false, String? code, String? reason}) =>
    isA<SecureAiHttpsException>()
        .having((e) => e.outcomeUnknown, 'uncertainty', unknown)
        .having((e) => code == null || e.code == code, 'code', true)
        .having((e) => reason == null || e.reason == reason, 'reason', true)
        .having((e) => e.toString().contains('PRIVATE'), 'safe failure', false);

void main() {
  test(
    'construction is inert, disabled by default, non-demo and TEST-only',
    () async {
      final f = _Fixture();
      final disabled = f.build(enabled: false);
      expect(disabled.available, false);
      expect(disabled.isDemo, false);
      await expectLater(
        disabled.call(f.data('issue')),
        throwsA(isA<SecureAiException>()),
      );
      expect(f.client.calls, isEmpty);
      for (final url in [
        'http://backend.invalid',
        'https://127.0.0.1',
        'https://u:p@backend.invalid',
        'https://backend.invalid/path',
        'https://backend.invalid?x=1',
        'https://backend.invalid#x',
        'https://a.localhost',
      ]) {
        expect(
          () => SecureAiHttpsTransport(
            endpoint: Uri.parse(url),
            projectId: 'velora-spark-test',
            endpointProjectId: 'velora-spark-test',
            client: f.client,
            currentSession: () => f.current,
            sessionChanges: f.changes.stream,
            idToken: f.token,
            sessionScope: f.scope,
            now: () => f.time,
          ),
          throwsA(failure()),
        );
      }
      expect(
        () => SecureAiHttpsTransport(
          endpoint: Uri.parse('https://backend.invalid'),
          projectId: 'velora-73222',
          endpointProjectId: 'velora-73222',
          client: f.client,
          currentSession: () => f.current,
          sessionChanges: f.changes.stream,
          idToken: f.token,
          sessionScope: f.scope,
          now: () => f.time,
        ),
        throwsA(failure()),
      );
    },
  );
  for (final role in CafeRole.values) {
    test(
      '${role.name}: existing SecureAiService composes two exact requests and validates real-shaped output',
      () async {
        final f = _Fixture(role: role),
            service = SecureAiService(
              currentSession: () => f.w,
              transport: f.transport,
              timeout: const Duration(seconds: 2),
            );
        final result = await service.generate();
        expect(result.ticketId, ticketId);
        expect(result.isDemo, false);
        expect(result.recipes.single.ingredients.single.itemId, 'item-1');
        expect(f.client.calls, hasLength(2));
        for (var i = 0; i < 2; i++) {
          final sent = f.client.calls[i] as http.Request,
              op = i == 0 ? 'issue' : 'generate';
          expect(sent.url.toString(), 'https://backend.invalid/ai/$op');
          expect(sent.method, 'POST');
          expect(sent.followRedirects, false);
          expect(sent.maxRedirects, 0);
          expect(sent.headers['authorization'], 'Bearer synthetic.token.value');
          expect(sent.headers['content-type'], startsWith('application/json'));
          final expected = f.data(op)..remove('operation');
          expect(jsonDecode(sent.body), expected);
        }
        expect(f.client.closed, false);
      },
    );
  }
  test(
    'no_suggestions is valid, never substituted with fabricated recipes',
    () async {
      final f = _Fixture();
      await f.issue();
      f.client.handle = (_) async => response({
        ...generation(),
        'status': 'no_suggestions',
        'recipes': [],
        'inventorySelection': {'eligibleCount': 0, 'usedCount': 0},
      });
      final result = await f.generate() as Map;
      expect(result['recipes'], isEmpty);
    },
  );
  for (final kind in [
    'missing',
    'uid',
    'project',
    'unverified',
    'revision',
    'invalidated',
  ]) {
    test('$kind identity rejects before transport', () async {
      final f = _Fixture();
      f.current = switch (kind) {
        'missing' => null,
        'uid' => session(f.w, uid: 'other'),
        'project' => session(f.w, project: 'velora-73222'),
        'unverified' => session(f.w, verified: false),
        'revision' => session(f.w, revision: -1),
        _ => session(f.w),
      };
      if (kind == 'invalidated') f.w.invalidate();
      await expectLater(f.issue(), throwsA(failure()));
      expect(f.client.calls, isEmpty);
    });
  }
  test(
    'provider/model/digest/lease/fence/identity inputs and stale expectations cannot dispatch',
    () async {
      final f = _Fixture();
      for (final patch in [
        {'model': 'other'},
        {'provider': 'groq'},
        {'url': 'https://evil.invalid'},
        {'payloadDigest': ticketId},
        {'lease': 1},
        {'fence': ticketId},
        {'uid': 'other'},
        {'maxRecipes': 0},
        {'maxRecipes': 4},
        {'expectedCafeId': 'other'},
        {'expectedMembershipGeneration': 0},
        {'operation': 'cleanup'},
      ]) {
        await expectLater(
          f.transport.call({...f.data('issue'), ...patch}),
          throwsA(failure()),
        );
      }
      expect(f.client.calls, isEmpty);
    },
  );
  for (final patch in [
    {'schemaVersion': 1},
    {'ticketId': 'bad'},
    {'expiresAt': 0},
    {'expiresAt': 1000000},
    {'expiresAt': 1000000.5},
    {'extra': 'PRIVATE'},
  ]) {
    test('malformed ticket acknowledgement is uncertain: $patch', () async {
      final f = _Fixture();
      f.client.handle = (_) async => response({...f.issued(), ...patch});
      await expectLater(f.issue(), throwsA(failure(unknown: true)));
      await expectLater(
        f.build().call(f.data('issue')),
        throwsA(failure(unknown: true)),
      );
      expect(f.client.calls, hasLength(1));
    });
  }
  test(
    'unknown, expired, changed-payload and changed-episode tickets do not generate',
    () async {
      final f = _Fixture();
      await expectLater(
        f.generate(),
        throwsA(failure(code: 'failed-precondition')),
      );
      await f.issue();
      await expectLater(
        f.generate(max: 2),
        throwsA(failure(code: 'failed-precondition')),
      );
      f.current = session(f.w, revision: 1);
      await expectLater(f.generate(), throwsA(failure(code: 'aborted')));
      f.current = session(f.w);
      f.time += 300000;
      await expectLater(
        f.generate(),
        throwsA(failure(reason: 'ticket-expired')),
      );
      expect(f.client.calls, hasLength(1));
    },
  );
  for (final patch in [
    {'schemaVersion': 1},
    {'provider': 'other'},
    {'ticketId': 'b' * 64},
    {'status': 'pending'},
    {'extra': 'PRIVATE'},
    {'recipes': []},
    {
      'inventorySelection': {'eligibleCount': 0, 'usedCount': 1},
    },
    {
      'recipes': [
        {
          'title': 'X',
          'ingredients': [],
          'steps': ['Cook'],
          'whyRecommended': 'X',
        },
      ],
    },
  ]) {
    test(
      'malformed generation is unknown and cannot be redispatched: $patch',
      () async {
        final f = _Fixture();
        await f.issue();
        f.client.handle = (_) async => response({...generation(), ...patch});
        await expectLater(f.generate(), throwsA(failure(unknown: true)));
        await expectLater(
          f.build().call(f.data('generate')),
          throwsA(failure(unknown: true)),
        );
        expect(f.client.calls, hasLength(2));
      },
    );
  }
  for (final operation in ['issue', 'generate']) {
    for (final entry in {
      'unauthenticated': 401,
      'permission-denied': 403,
      'aborted': 409,
      'already-exists': 409,
      'failed-precondition': 409,
      'invalid-argument': 400,
      'resource-exhausted': 429,
    }.entries) {
      test(
        '$operation canonical ${entry.key} remains definite without invented granular reason',
        () async {
          final f = _Fixture();
          if (operation == 'generate') await f.issue();
          f.client.handle = (_) async =>
              response({'error': entry.key}, status: entry.value);
          await expectLater(
            f.transport.call(f.data(operation)),
            throwsA(failure(code: entry.key)),
          );
          expect(f.client.calls.length, operation == 'issue' ? 1 : 2);
        },
      );
    }
    for (final kind in [
      'network',
      'json',
      'utf8',
      'size',
      'type',
      'redirect',
      'unknown',
      'forged',
    ]) {
      test(
        '$operation $kind failure preserves unknown evidence and never sends replacement ticket',
        () async {
          final f = _Fixture();
          if (operation == 'generate') await f.issue();
          f.client.handle = (_) async {
            if (kind == 'network') throw StateError('PRIVATE');
            return switch (kind) {
              'json' => response(null, raw: '{PRIVATE'),
              'utf8' => http.StreamedResponse(
                Stream.value([255]),
                200,
                headers: {'content-type': 'application/json'},
              ),
              'size' => response(null, raw: 'x' * 65537),
              'type' => response({}, type: 'text/html'),
              'redirect' => response({}, status: 302),
              'unknown' => response({
                'error': 'unavailable',
                'outcomeUnknown': true,
              }, status: 503),
              _ => response({
                'error': 'failed-precondition',
                'reason': 'ticket-expired',
              }, status: 409),
            };
          };
          await expectLater(
            f.transport.call(f.data(operation)),
            throwsA(failure(unknown: true, reason: 'outcome-unknown')),
          );
          await expectLater(
            f.build().call(f.data('issue')),
            throwsA(failure(unknown: true)),
          );
          expect(f.client.calls.length, operation == 'issue' ? 1 : 2);
        },
      );
    }
    for (final phase in ['token', 'headers', 'body']) {
      test(
        '$operation $phase timeout is bounded and suppresses late work',
        () async {
          final f = _Fixture();
          if (operation == 'generate') await f.issue();
          final adapter = f.build(timeout: const Duration(milliseconds: 15));
          final token = Completer<String?>(),
              headers = Completer<http.StreamedResponse>(),
              body = StreamController<List<int>>();
          if (phase == 'token') f.token = (_) => token.future;
          if (phase == 'headers') f.client.handle = (_) => headers.future;
          if (phase == 'body') {
            f.client.handle = (_) async => http.StreamedResponse(
              body.stream,
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          await expectLater(
            adapter.call(f.data(operation)),
            throwsA(
              failure(unknown: phase != 'token', code: 'deadline-exceeded'),
            ),
          );
          token.complete('synthetic');
          headers.complete(
            response(operation == 'issue' ? f.issued() : generation()),
          );
          await Future<void>.delayed(const Duration(milliseconds: 5));
          expect(
            f.client.calls.length,
            (operation == 'issue' ? 0 : 1) + (phase == 'token' ? 0 : 1),
          );
          if (phase == 'body') {
            await body.close();
          } else {
            unawaited(body.close());
          }
        },
      );
    }
    test(
      '$operation logout/workspace switch suppresses in-flight result',
      () async {
        final f = _Fixture();
        if (operation == 'generate') await f.issue();
        final gate = Completer<http.StreamedResponse>();
        f.client.handle = (_) => gate.future;
        final pending = f.transport.call(f.data(operation));
        await Future<void>.delayed(Duration.zero);
        final checked = expectLater(
          pending,
          throwsA(failure(unknown: true, code: 'aborted')),
        );
        f.changes.add(null);
        f.current = session(workspace(cafe: 'other'), revision: 1);
        gate.complete(
          response(operation == 'issue' ? f.issued() : generation()),
        );
        await checked;
        expect(f.client.calls.length, operation == 'issue' ? 1 : 2);
      },
    );
  }
  test(
    'same scope serializes calls across instances; consumed generation ticket cannot dispatch twice',
    () async {
      final f = _Fixture();
      await f.issue();
      final gate = Completer<http.StreamedResponse>();
      f.client.handle = (_) => gate.future;
      final first = f.generate();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        f.build().call(f.data('generate')),
        throwsA(failure(reason: 'workspace-busy')),
      );
      gate.complete(response(generation()));
      await first;
      await expectLater(
        f.generate(),
        throwsA(failure(code: 'already-exists', reason: 'ticket-replayed')),
      );
      expect(f.client.calls, hasLength(2));
    },
  );
  test(
    'token failure is definite and cannot consume a dispatch capability',
    () async {
      final f = _Fixture();
      await f.issue();
      f.token = (_) async => throw StateError('PRIVATE');
      await expectLater(f.generate(), throwsA(failure()));
      expect(f.client.calls, hasLength(1));
      f.token = (_) async => 'synthetic';
      expect(await f.generate(), generation());
      expect(f.client.calls, hasLength(2));
    },
  );
  test(
    'mutation of caller map during send cannot replace ticket binding',
    () async {
      final f = _Fixture();
      await f.issue();
      final gate = Completer<String?>();
      f.token = (_) => gate.future;
      final input = f.data('generate');
      final pending = f.transport.call(input);
      input['ticketId'] = 'b' * 64;
      gate.complete('synthetic');
      await pending;
      expect(
        jsonDecode((f.client.calls.last as http.Request).body)['ticketId'],
        ticketId,
      );
    },
  );
  test(
    'existing SecureAiService displays unknown outcome rather than retrying provider',
    () async {
      final f = _Fixture();
      f.client.handle = (r) async => r.url.path == '/ai/issue'
          ? response(f.issued())
          : response({
              'error': 'unavailable',
              'outcomeUnknown': true,
            }, status: 503);
      final service = SecureAiService(
        currentSession: () => f.w,
        transport: f.transport,
      );
      await expectLater(
        service.generate(),
        throwsA(
          isA<SecureAiException>().having(
            (e) => e.failure,
            'failure',
            SecureAiFailure.outcomeUnknown,
          ),
        ),
      );
      await expectLater(
        service.generate(),
        throwsA(
          isA<SecureAiException>().having(
            (e) => e.failure,
            'failure',
            SecureAiFailure.outcomeUnknown,
          ),
        ),
      );
      expect(f.client.calls, hasLength(2));
    },
  );
  test(
    'generic quota/fencing rejection is not relabeled as expiry or unknown',
    () async {
      final f = _Fixture();
      await f.issue();
      f.client.handle = (_) async =>
          response({'error': 'failed-precondition'}, status: 409);
      try {
        await f.generate();
        fail('Expected rejection');
      } on SecureAiHttpsException catch (e) {
        expect(e.reason, isNull);
        expect(e.outcomeUnknown, false);
        expect(e.code, 'failed-precondition');
      }
    },
  );
  test(
    'cleanup cancellation stalls or session changes cannot publish success',
    () async {
      for (final stall in [false, true]) {
        final f = _Fixture();
        final transport = f.build(
          stream: CancelStream(f.changes.stream, () async {
            if (stall) return Completer<void>().future;
            f.current = session(f.w, revision: 1);
          }),
        );
        await expectLater(
          transport.call(f.data('issue')),
          throwsA(failure(unknown: true)),
        );
        expect(f.client.closed, false);
      }
    },
  );
}
