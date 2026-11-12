import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/staff_https_service.dart';
import 'package:velora/services/workspace_session.dart';
import 'workspace_inventory_https_transport_test.dart' show CancelStream;

const digest =
    '69334e33346df8362686a34048322e8b062f1f3e6d71e2ee7ff6ca42c2805d1b';
const key = 'remove-key-00001';
// Independent Node SHA-256 fixture for the canonical JSON array. The real
// composition must supply SHA-256; this test provider verifies its exact input.
String hash(String input) {
  expect(input, '["owner","cafe","remove-key-00001"]');
  return digest;
}

WorkspaceSession workspace({
  String cafe = 'cafe',
  CafeRole role = CafeRole.owner,
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
StaffHttpsSession session(
  WorkspaceSession w, {
  String project = 'velora-spark-test',
  int revision = 0,
  bool verified = true,
  String? uid,
}) => StaffHttpsSession(
  projectId: project,
  uid: uid ?? w.uid,
  revision: revision,
  emailVerified: verified,
  workspace: w,
);
CafeWorkspace context(WorkspaceSession w) => CafeWorkspace(
  cafeId: w.cafeId,
  uid: w.uid,
  ownerUid: w.ownerUid,
  role: w.role,
  membershipGeneration: w.membershipGeneration,
);
StaffRemovalRequest removal({
  int actor = 7,
  int target = 2,
  String cafe = 'cafe',
  String uid = 'staff',
  String requestKey = key,
}) => StaffRemovalRequest(
  targetUid: uid,
  expectedCafeId: cafe,
  expectedGeneration: target,
  expectedActorGeneration: actor,
  idempotencyKey: requestKey,
);
Map<String, Object> member(String uid, {String? role}) => {
  'uid': uid,
  'role': role ?? (uid == 'owner' ? 'owner' : 'staff'),
  'name': uid,
  'email': '$uid@example.test',
};
Map<String, Object> roster({String role = 'owner', List<Object>? rows}) => {
  'cafeId': 'cafe',
  'viewerRole': role,
  'members': rows ?? [member('owner'), member('staff')],
};
Map<String, Object> ack({bool changed = true}) => {
  'cafeId': 'cafe',
  'targetUid': 'staff',
  'eventId': 'remove_$digest',
  'resultGeneration': 3,
  'changed': changed,
};
http.StreamedResponse response(
  Object? body, {
  int status = 200,
  String? raw,
  String type = 'application/json',
}) => http.StreamedResponse(
  Stream.value(utf8.encode(raw ?? jsonEncode(body))),
  status,
  headers: {'content-type': type},
);

class _Client extends http.BaseClient {
  final calls = <http.BaseRequest>[];
  bool closed = false;
  Future<http.StreamedResponse> Function(http.BaseRequest) handle = (r) async =>
      response(r.url.path == '/staff/list' ? roster() : ack());
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
  final changes = StreamController<StaffHttpsSession?>.broadcast(sync: true);
  final WorkspaceSession w;
  late StaffHttpsSession? current;
  late final StaffHttpsService service;
  Future<String?> Function(StaffHttpsSession) token = (_) async =>
      'synthetic.token.value';
  _Fixture({
    CafeRole role = CafeRole.owner,
    Duration timeout = const Duration(seconds: 1),
    int maxBytes = 262144,
    Stream<StaffHttpsSession?>? stream,
  }) : w = workspace(role: role) {
    current = session(w);
    service = StaffHttpsService(
      endpoint: Uri.parse('https://backend.invalid'),
      projectId: 'velora-spark-test',
      endpointProjectId: 'velora-spark-test',
      client: client,
      currentSession: () => current,
      sessionChanges: stream ?? changes.stream,
      idToken: (s) => token(s),
      sha256: hash,
      timeout: timeout,
      cleanupTimeout: const Duration(milliseconds: 10),
      maxResponseBytes: maxBytes,
    );
    addTearDown(changes.close);
  }
  Future<Object> call(bool mutation, {StaffRemovalRequest? request}) => mutation
      ? service.remove(request ?? removal())
      : service.load(context(w));
}

Matcher failure({bool unknown = false, String? code}) =>
    isA<StaffHttpsException>()
        .having((e) => e.outcomeUnknown, 'outcomeUnknown', unknown)
        .having((e) => code == null || e.code == code, 'code', true)
        .having((e) => e.toString().contains('PRIVATE'), 'safe error', false);

void main() {
  test(
    'full 100-member Unicode roster fits the bounded response budget',
    () async {
      final f = _Fixture();
      final rows = List.generate(
        100,
        (i) => <String, Object>{
          ...member(i == 0 ? 'owner' : 'staff-$i'),
          'name': '名' * 80,
          'email': '${'文' * 240}@example.test',
        },
      );
      expect(
        utf8.encode(jsonEncode(roster(rows: rows))).length,
        greaterThan(65536),
      );
      f.client.handle = (_) async => response(roster(rows: rows));
      expect((await f.service.load(context(f.w))).members, hasLength(100));
      expect(f.client.calls, hasLength(1));
    },
  );
  test(
    'construction is inert, project-bound and requires safe HTTPS origin',
    () {
      final f = _Fixture();
      expect(f.client.calls, isEmpty);
      for (final uri in [
        'http://backend.invalid',
        'https://127.0.0.1',
        'https://u:p@backend.invalid',
        'https://backend.invalid/path',
        'https://backend.invalid?x=1',
        'https://backend.invalid#x',
        'https://backend.invalid:444',
        'https://a.localhost',
      ]) {
        expect(
          () => StaffHttpsService(
            endpoint: Uri.parse(uri),
            projectId: 'velora-spark-test',
            endpointProjectId: 'velora-spark-test',
            client: f.client,
            currentSession: () => f.current,
            sessionChanges: f.changes.stream,
            idToken: f.token,
            sha256: hash,
          ),
          throwsA(failure(code: 'invalid-configuration')),
        );
      }
      expect(
        () => StaffHttpsService(
          endpoint: Uri.parse('https://backend.invalid'),
          projectId: 'velora-73222',
          endpointProjectId: 'velora-73222',
          client: f.client,
          currentSession: () => f.current,
          sessionChanges: f.changes.stream,
          idToken: f.token,
          sha256: hash,
        ),
        throwsA(failure()),
      );
    },
  );
  for (final role in CafeRole.values) {
    test(
      '${role.name} roster sends exact empty request and preserves server order/visibility',
      () async {
        final f = _Fixture(role: role);
        f.client.handle = (_) async => response(roster(role: role.name));
        final original = context(f.w), result = await f.service.load(original);
        expect(result.workspace, same(original));
        expect(result.members.map((m) => m.uid), ['owner', 'staff']);
        expect(() => result.members.clear(), throwsUnsupportedError);
        final sent = f.client.calls.single as http.Request;
        expect(sent.method, 'POST');
        expect(sent.url.path, '/staff/list');
        expect(sent.body, '{}');
        expect(sent.headers['authorization'], 'Bearer synthetic.token.value');
        expect(sent.headers['content-type'], startsWith('application/json'));
        expect(sent.followRedirects, false);
        expect(sent.maxRedirects, 0);
        expect(f.client.closed, false);
      },
    );
  }
  for (final changed in [true, false]) {
    test(
      'removal ${changed ? 'commit' : 'historical replay'} binds separate generations and receipt',
      () async {
        final f = _Fixture(), request = removal();
        f.client.handle = (_) async => response(ack(changed: changed));
        final result = await f.service.remove(request);
        expect(result.changed, changed);
        expect(result.targetUid, 'staff');
        expect(result.cafeId, 'cafe');
        expect(result.resultGeneration, 3);
        expect(result.eventId, 'remove_$digest');
        final sent = f.client.calls.single as http.Request;
        expect(sent.url.path, '/staff/remove');
        expect(sent.method, 'POST');
        expect(jsonDecode(sent.body), request.toJson());
        expect(jsonDecode(sent.body), hasLength(5));
        expect(sent.followRedirects, false);
        expect(sent.maxRedirects, 0);
      },
    );
  }
  test(
    'Staff cannot remove; cross-cafe/stale actor preconditions do not dispatch',
    () async {
      final staff = _Fixture(role: CafeRole.staff);
      await expectLater(
        staff.service.remove(removal(uid: 'other')),
        throwsA(failure(code: 'permission-denied')),
      );
      expect(staff.client.calls, isEmpty);
      final f = _Fixture();
      for (final r in [
        removal(cafe: 'other'),
        removal(actor: 6),
        removal(uid: 'owner'),
        removal(target: -1),
        removal(requestKey: 'short'),
      ]) {
        await expectLater(f.service.remove(r), throwsA(failure()));
      }
      expect(f.client.calls, isEmpty);
      await expectLater(
        f.service.load(context(workspace(cafe: 'other'))),
        throwsA(failure(code: 'session-changed')),
      );
    },
  );
  for (final kind in [
    'missing',
    'project',
    'uid',
    'unverified',
    'invalidated',
    'revision',
  ]) {
    test('$kind identity blocks both endpoints', () async {
      final f = _Fixture();
      f.current = switch (kind) {
        'missing' => null,
        'project' => session(f.w, project: 'velora-73222'),
        'uid' => session(f.w, uid: 'other'),
        'unverified' => session(f.w, verified: false),
        'revision' => session(f.w, revision: -1),
        _ => session(f.w),
      };
      if (kind == 'invalidated') f.w.invalidate();
      await expectLater(f.call(false), throwsA(failure()));
      await expectLater(f.call(true), throwsA(failure()));
      expect(f.client.calls, isEmpty);
    });
  }
  for (final bad in [
    null,
    {},
    {'cafeId': 'other', 'viewerRole': 'owner', 'members': []},
    {...roster(), 'viewerRole': 'staff'},
    {...roster(), 'nextCursor': 'invented'},
    roster(rows: [member('owner'), member('owner')]),
    roster(rows: [member('other', role: 'owner')]),
    roster(
      rows: [
        {...member('staff'), 'generation': 2},
      ],
    ),
    roster(
      rows: [
        {...member('staff'), 'email': 'bad'},
      ],
    ),
    roster(
      rows: [
        {...member('staff'), 'name': 'bad\nname'},
      ],
    ),
    roster(rows: List.generate(101, (i) => member('staff-$i'))),
  ]) {
    test('strict roster rejects malformed/foreign data: $bad', () async {
      final f = _Fixture();
      f.client.handle = (_) async => response(bad);
      await expectLater(f.call(false), throwsA(failure()));
      expect(f.client.calls, hasLength(1));
    });
  }
  test('Staff roster cannot disclose another Staff member', () async {
    final f = _Fixture(role: CafeRole.staff);
    f.client.handle = (_) async =>
        response(roster(role: 'staff', rows: [member('other')]));
    await expectLater(f.call(false), throwsA(failure()));
  });
  for (final patch in [
    {'cafeId': 'other'},
    {'targetUid': 'other'},
    {'eventId': 'remove_${'b' * 64}'},
    {'resultGeneration': 2},
    {'resultGeneration': 4},
    {'changed': 'true'},
    {'extra': 1},
  ]) {
    test('removal acknowledgement mismatch remains unknown: $patch', () async {
      final f = _Fixture();
      f.client.handle = (_) async => response({...ack(), ...patch});
      await expectLater(f.call(true), throwsA(failure(unknown: true)));
      expect(f.client.calls, hasLength(1));
    });
  }
  for (final mutation in [false, true]) {
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
        '${mutation ? 'remove' : 'list'} canonical ${entry.key} is a definite rejection',
        () async {
          final f = _Fixture();
          f.client.handle = (_) async =>
              response({'error': entry.key}, status: entry.value);
          await expectLater(
            f.call(mutation),
            throwsA(failure(code: entry.key)),
          );
          expect(f.client.calls, hasLength(1));
        },
      );
    }
    for (final kind in [
      'network',
      'json',
      'utf8',
      'redirect',
      'oversized',
      'unknown',
      'forged',
      'type',
    ]) {
      test(
        '${mutation ? 'remove' : 'list'} $kind failure is sanitized and never retried',
        () async {
          final f = _Fixture(maxBytes: 300);
          f.client.handle = (_) async {
            if (kind == 'network') throw StateError('PRIVATE');
            return switch (kind) {
              'json' => response(null, raw: '{PRIVATE'),
              'utf8' => http.StreamedResponse(
                Stream.value([255]),
                200,
                headers: {'content-type': 'application/json'},
              ),
              'redirect' => response({}, status: 302),
              'oversized' => response(null, raw: 'x' * 301),
              'unknown' => response({
                'error': 'unavailable',
                'outcomeUnknown': true,
              }, status: 503),
              'forged' => response({
                'error': 'permission-denied',
                'details': 'PRIVATE',
              }, status: 403),
              _ => response({}, type: 'text/html'),
            };
          };
          await expectLater(
            f.call(mutation),
            throwsA(failure(unknown: mutation)),
          );
          expect(f.client.calls, hasLength(1));
        },
      );
    }
    for (final phase in ['token', 'headers', 'body']) {
      test(
        '${mutation ? 'remove' : 'list'} $phase timeout cannot resume late dispatch',
        () async {
          final f = _Fixture(timeout: const Duration(milliseconds: 15));
          final token = Completer<String?>(),
              headers = Completer<http.StreamedResponse>();
          final body = StreamController<List<int>>();
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
            f.call(mutation),
            throwsA(
              failure(
                unknown: mutation && phase != 'token',
                code: 'deadline-exceeded',
              ),
            ),
          );
          token.complete('synthetic');
          headers.complete(response(mutation ? ack() : roster()));
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
    test(
      '${mutation ? 'remove' : 'list'} workspace transition suppresses in-flight result',
      () async {
        final f = _Fixture(), gate = Completer<http.StreamedResponse>();
        f.client.handle = (_) => gate.future;
        final pending = f.call(mutation);
        await Future<void>.delayed(Duration.zero);
        final checked = expectLater(
          pending,
          throwsA(failure(unknown: mutation, code: 'session-changed')),
        );
        f.changes.add(null);
        f.current = session(workspace(cafe: 'other'), revision: 1);
        f.changes.add(f.current);
        gate.complete(response(mutation ? ack() : roster()));
        await checked;
        expect(f.client.calls, hasLength(1));
      },
    );
  }
  test(
    'unknown removal plus later definite rejection retains uncertainty and exact payload',
    () async {
      final f = _Fixture(), request = removal();
      f.client.handle = (_) async => throw StateError('PRIVATE');
      await expectLater(
        f.service.remove(request),
        throwsA(failure(unknown: true)),
      );
      expect(f.client.calls, hasLength(1));
      f.client.handle = (_) async =>
          response({'error': 'aborted'}, status: 409);
      await expectLater(
        f.service.remove(request),
        throwsA(failure(unknown: true, code: 'aborted')),
      );
      expect(
        (f.client.calls.first as http.Request).body,
        (f.client.calls.last as http.Request).body,
      );
      f.current = null;
      await expectLater(
        f.service.remove(request),
        throwsA(failure(unknown: true)),
      );
      expect(f.client.calls, hasLength(2));
    },
  );
  test(
    'explicit unchanged replay returns historical result without claiming current target state',
    () async {
      final f = _Fixture(), request = removal();
      expect((await f.service.remove(request)).changed, true);
      f.client.handle = (_) async => response(ack(changed: false));
      expect((await f.service.remove(request)).changed, false);
      expect(f.client.calls, hasLength(2));
      expect(
        jsonDecode(
          (f.client.calls.last as http.Request).body,
        )['expectedGeneration'],
        2,
      );
    },
  );
  test(
    'same request cannot move to another actor episode or dispatch concurrently',
    () async {
      final f = _Fixture(),
          request = removal(),
          gate = Completer<http.StreamedResponse>();
      f.client.handle = (_) => gate.future;
      final first = f.service.remove(request);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        f.service.remove(request),
        throwsA(failure(unknown: true, code: 'request-in-flight')),
      );
      gate.complete(response(ack()));
      await first;
      expect(f.client.calls, hasLength(1));
      f.current = session(f.w, revision: 1);
      await expectLater(
        f.service.remove(request),
        throwsA(failure(code: 'request-context-changed')),
      );
      expect(f.client.calls, hasLength(1));
    },
  );
  for (final mutation in [false, true]) {
    test(
      '${mutation ? 'remove' : 'list'} checks identity after cleanup and bounds failed cancellation',
      () async {
        for (final stall in [false, true]) {
          final f = _Fixture();
          final service = StaffHttpsService(
            endpoint: Uri.parse('https://backend.invalid'),
            projectId: 'velora-spark-test',
            endpointProjectId: 'velora-spark-test',
            client: f.client,
            currentSession: () => f.current,
            idToken: f.token,
            sha256: hash,
            cleanupTimeout: const Duration(milliseconds: 10),
            sessionChanges: CancelStream(f.changes.stream, () async {
              if (stall) {
                return Completer<void>().future;
              }
              f.current = session(f.w, revision: 1);
            }),
          );
          await expectLater(
            mutation ? service.remove(removal()) : service.load(context(f.w)),
            throwsA(failure(unknown: mutation)),
          );
          expect(f.client.closed, false);
        }
      },
    );
  }
}
