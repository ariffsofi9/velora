import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/menu_https_transport.dart';
import 'package:velora/services/workspace_session.dart';
import 'workspace_inventory_https_transport_test.dart' show CancelStream;

const key = 'menu-key-0000001';
// SHA-256 fixture computed independently using Node's crypto implementation.
const digest =
    '1dbb7c78497956ce3e888d99ade660f8d2a7c67a2e88ad6089bdd48a71228e0a';
String hash(String input) {
  expect(input, 'owner\u0000cafe\u0000$key');
  return digest;
}

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
MenuHttpsSession session(
  WorkspaceSession w, {
  int revision = 0,
  String project = 'velora-spark-test',
  bool verified = true,
  String? uid,
}) => MenuHttpsSession(
  projectId: project,
  uid: uid ?? w.uid,
  revision: revision,
  emailVerified: verified,
  workspace: w,
);
Map<String, Object> item({String id = 'a', bool archived = false}) => {
  'id': id,
  'cafeId': 'cafe',
  'name': 'Tea',
  'category': 'Drinks',
  'priceMinor': 350,
  'currency': 'MYR',
  'isAvailable': true,
  'isArchived': archived,
  'version': 4,
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': '2026-01-01T00:00:00.000Z',
  'createdBy': 'owner',
  'updatedBy': 'owner',
};
const operations = {
  'createMenuItem': 'create',
  'getMenuItem': 'get',
  'listMenuItems': 'list',
  'updateMenuItem': 'update',
  'setMenuItemLifecycle': 'lifecycle',
};
Map<String, Object> data(String name) => switch (name) {
  'getMenuItem' => {'itemId': 'a'},
  'listMenuItems' => {},
  _ => {
    'expectedCafeId': 'cafe',
    'expectedMembershipGeneration': 7,
    'idempotencyKey': key,
    if (name == 'createMenuItem') ...{
      'name': 'Tea',
      'category': 'Drinks',
      'priceMinor': 350,
      'isAvailable': true,
    } else ...{
      'itemId': 'a',
      'expectedVersion': 4,
      if (name == 'updateMenuItem')
        'isAvailable': false
      else
        'action': 'archive',
    },
  },
};
Map<String, Object?> reply(String op, {bool changed = true}) => switch (op) {
  'get' => {'item': item()},
  'list' => {
    'cafeId': 'cafe',
    'items': [item()],
    'nextCursor': null,
  },
  _ => {
    'cafeId': 'cafe',
    'itemId': op == 'create' ? 'menu_$digest' : 'a',
    'version': op == 'create' ? 1 : 5,
    'changed': changed,
  },
};
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
  Future<http.StreamedResponse> Function(http.BaseRequest) handle = (r) async =>
      response(reply(r.url.path.split('/').last));
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handle(request);
  }

  @override
  void close() => closed = true;
}

class _Fixture {
  final _Client client = _Client();
  final changes = StreamController<MenuHttpsSession?>.broadcast(sync: true);
  final WorkspaceSession w;
  final Object scope = Object();
  late MenuHttpsSession? current;
  late final MenuHttpsTransport transport;
  Future<String?> Function(MenuHttpsSession) token = (_) async =>
      'synthetic.token.value';
  _Fixture({
    CafeRole role = CafeRole.owner,
    Duration timeout = const Duration(seconds: 1),
    int maxBytes = 262144,
  }) : w = workspace(role: role) {
    current = session(w);
    transport = build(timeout: timeout, maxBytes: maxBytes);
    addTearDown(changes.close);
  }
  MenuHttpsTransport build({
    Duration timeout = const Duration(seconds: 1),
    int maxBytes = 262144,
    Stream<MenuHttpsSession?>? stream,
    String Function(String)? sha,
  }) => MenuHttpsTransport(
    endpoint: Uri.parse('https://backend.invalid'),
    projectId: 'velora-spark-test',
    endpointProjectId: 'velora-spark-test',
    client: client,
    currentSession: () => current,
    sessionChanges: stream ?? changes.stream,
    idToken: (s) => token(s),
    sha256: sha ?? hash,
    sessionScope: scope,
    timeout: timeout,
    cleanupTimeout: const Duration(milliseconds: 10),
    maxResponseBytes: maxBytes,
  );
}

Matcher failure({bool unknown = false, String? code}) =>
    isA<MenuHttpsException>()
        .having((e) => e.outcomeUnknown, 'uncertainty', unknown)
        .having((e) => code == null || e.code == code, 'code', true)
        .having((e) => e.toString().contains('PRIVATE'), 'safe error', false);

void main() {
  test('inert configuration requires TEST project and safe HTTPS origin', () {
    final f = _Fixture();
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
        () => MenuHttpsTransport(
          endpoint: Uri.parse(url),
          projectId: 'velora-spark-test',
          endpointProjectId: 'velora-spark-test',
          client: f.client,
          currentSession: () => f.current,
          sessionChanges: f.changes.stream,
          idToken: f.token,
          sha256: hash,
          sessionScope: f.scope,
        ),
        throwsA(failure()),
      );
    }
    expect(
      () => MenuHttpsTransport(
        endpoint: Uri.parse('https://backend.invalid'),
        projectId: 'velora-73222',
        endpointProjectId: 'velora-73222',
        client: f.client,
        currentSession: () => f.current,
        sessionChanges: f.changes.stream,
        idToken: f.token,
        sha256: hash,
        sessionScope: f.scope,
      ),
      throwsA(failure()),
    );
  });
  for (final entry in operations.entries) {
    test(
      '${entry.key} maps exact route, authenticated headers and unchanged fields',
      () async {
        final f = _Fixture(), input = data(entry.key);
        final result = await f.transport.call(entry.key, input);
        expect(result, reply(entry.value));
        final sent = f.client.calls.single as http.Request;
        expect(sent.method, 'POST');
        expect(
          sent.url.toString(),
          'https://backend.invalid/menu/${entry.value}',
        );
        expect(sent.headers['authorization'], 'Bearer synthetic.token.value');
        expect(sent.headers['content-type'], startsWith('application/json'));
        expect(jsonDecode(sent.body), input);
        expect(sent.followRedirects, false);
        expect(sent.maxRedirects, 0);
        expect(f.client.closed, false);
      },
    );
  }
  test(
    'Staff can get/list and update availability only; mixed fields remain forbidden',
    () async {
      final f = _Fixture(role: CafeRole.staff);
      for (final op in ['getMenuItem', 'listMenuItems', 'updateMenuItem']) {
        await f.transport.call(op, data(op));
      }
      for (final op in ['createMenuItem', 'setMenuItemLifecycle']) {
        await expectLater(
          f.transport.call(op, data(op)),
          throwsA(failure(code: 'permission-denied')),
        );
      }
      await expectLater(
        f.transport.call('updateMenuItem', {
          ...data('updateMenuItem'),
          'name': 'Tea',
        }),
        throwsA(failure(code: 'permission-denied')),
      );
      expect(f.client.calls, hasLength(3));
    },
  );
  for (final kind in [
    'missing',
    'uid',
    'project',
    'revision',
    'unverified',
    'invalidated',
  ]) {
    test('$kind context fails closed', () async {
      final f = _Fixture();
      f.current = switch (kind) {
        'missing' => null,
        'uid' => session(f.w, uid: 'other'),
        'project' => session(f.w, project: 'velora-73222'),
        'revision' => session(f.w, revision: -1),
        'unverified' => session(f.w, verified: false),
        _ => session(f.w),
      };
      if (kind == 'invalidated') f.w.invalidate();
      await expectLater(
        f.transport.call('listMenuItems', {}),
        throwsA(failure()),
      );
      await expectLater(
        f.transport.call('createMenuItem', data('createMenuItem')),
        throwsA(failure()),
      );
      expect(f.client.calls, isEmpty);
    });
  }
  test(
    'unsupported operations/forged authority/stale expectations/invalid money cannot dispatch',
    () async {
      final f = _Fixture();
      await expectLater(
        f.transport.call('/menu/reconcile', {}),
        throwsA(failure()),
      );
      for (final patch in [
        {'actorUid': 'other'},
        {'currency': 'USD'},
        {'priceMinor': -1},
        {'priceMinor': 1.5},
        {'expectedCafeId': 'other'},
        {'expectedMembershipGeneration': 0},
      ]) {
        await expectLater(
          f.transport.call('createMenuItem', {
            ...data('createMenuItem'),
            ...patch,
          }),
          throwsA(failure()),
        );
      }
      for (final input in [
        {'limit': 0},
        {'limit': 51},
        {'cursor': '../other'},
        {'includeArchived': 'true'},
        {'cafeId': 'other'},
      ]) {
        await expectLater(
          f.transport.call('listMenuItems', input),
          throwsA(failure()),
        );
      }
      expect(f.client.calls, isEmpty);
    },
  );
  test(
    'pagination binds limit, cursor, ID ordering and archived filter to scoped response',
    () async {
      final f = _Fixture();
      f.client.handle = (_) async => response({
        'cafeId': 'cafe',
        'items': [item(id: 'b'), item(id: 'c')],
        'nextCursor': 'c',
      });
      await f.transport.call('listMenuItems', {
        'limit': 2,
        'cursor': 'a',
        'includeArchived': false,
      });
      expect(jsonDecode((f.client.calls.single as http.Request).body), {
        'limit': 2,
        'cursor': 'a',
        'includeArchived': false,
      });
      f.client.handle = (_) async => response({
        'cafeId': 'cafe',
        'items': [item(archived: true)],
        'nextCursor': null,
      });
      await f.transport.call('listMenuItems', {'includeArchived': true});
      await expectLater(
        f.transport.call('listMenuItems', {}),
        throwsA(failure()),
      );
      f.client.handle = (_) async => response({'item': item(archived: true)});
      await f.transport.call('getMenuItem', {'itemId': 'a'});
    },
  );
  for (final kind in [
    'duplicate',
    'order',
    'before-cursor',
    'next-cursor',
    'short-page',
    'overflow',
    'foreign',
    'missing',
  ]) {
    test('malformed pagination $kind is rejected', () async {
      final f = _Fixture();
      final rows = kind == 'order'
          ? [item(id: 'c'), item(id: 'b')]
          : kind == 'duplicate'
          ? [item(id: 'b'), item(id: 'b')]
          : kind == 'overflow'
          ? [item(id: 'b'), item(id: 'c'), item(id: 'd')]
          : kind == 'short-page'
          ? [item(id: 'b')]
          : [item(id: 'b'), item(id: 'c')];
      final result = <String, Object?>{
        'cafeId': kind == 'foreign' ? 'other' : 'cafe',
        'items': rows,
        'nextCursor': kind == 'next-cursor'
            ? 'z'
            : kind == 'short-page'
            ? 'b'
            : 'c',
      };
      if (kind == 'missing') result.remove('nextCursor');
      f.client.handle = (_) async => response(result);
      await expectLater(
        f.transport.call('listMenuItems', {
          'limit': 2,
          'cursor': kind == 'before-cursor' ? 'c' : 'a',
        }),
        throwsA(failure()),
      );
    });
  }
  for (final patch in [
    {'currency': 'USD'},
    {'priceMinor': 1.5},
    {'version': 0},
    {'cafeId': 'other'},
    {'id': 'other'},
    {'updatedAt': '2026-01-01'},
    {'extra': 'PRIVATE'},
    {'name': 'Not  normalized'},
  ]) {
    test('malformed get item is rejected: $patch', () async {
      final f = _Fixture();
      f.client.handle = (_) async => response({
        'item': {...item(), ...patch},
      });
      await expectLater(
        f.transport.call('getMenuItem', {'itemId': 'a'}),
        throwsA(failure(code: 'invalid-response')),
      );
    });
  }
  for (final op in [
    'createMenuItem',
    'updateMenuItem',
    'setMenuItemLifecycle',
  ]) {
    for (final patch in [
      {'cafeId': 'other'},
      {'itemId': 'other'},
      {'version': 99},
      {'changed': 'true'},
      {'extra': 'PRIVATE'},
    ]) {
      test('$op malformed acknowledgement stays unknown: $patch', () async {
        final f = _Fixture();
        f.client.handle = (_) async =>
            response({...reply(operations[op]!), ...patch});
        await expectLater(
          f.transport.call(op, data(op)),
          throwsA(failure(unknown: true)),
        );
        expect(f.client.calls, hasLength(1));
      });
    }
    test(
      '$op historical acknowledgement retains original result version',
      () async {
        final f = _Fixture();
        f.client.handle = (_) async =>
            response(reply(operations[op]!, changed: false));
        expect((await f.transport.call(op, data(op)))['changed'], false);
        expect(f.client.calls, hasLength(1));
      },
    );
  }
  for (final op in ['listMenuItems', 'updateMenuItem']) {
    final mutation = op == 'updateMenuItem';
    for (final entry in {
      'unauthenticated': 401,
      'permission-denied': 403,
      'aborted': 409,
      'already-exists': 409,
      'failed-precondition': 409,
      'invalid-argument': 400,
      'not-found': 404,
    }.entries) {
      test(
        '$op normalizes canonical ${entry.key} without unknown dispatch',
        () async {
          final f = _Fixture();
          f.client.handle = (_) async =>
              response({'error': entry.key}, status: entry.value);
          await expectLater(
            f.transport.call(op, data(op)),
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
      'type',
      'redirect',
      'size',
      'unknown',
      'forged',
    ]) {
      test(
        '$op $kind failure never retries and preserves mutation uncertainty',
        () async {
          final f = _Fixture(maxBytes: 1000);
          f.client.handle = (_) async {
            if (kind == 'network') throw StateError('PRIVATE');
            return switch (kind) {
              'json' => response(null, raw: '{PRIVATE'),
              'utf8' => http.StreamedResponse(
                Stream.value([255]),
                200,
                headers: {'content-type': 'application/json'},
              ),
              'type' => response({}, type: 'text/html'),
              'redirect' => response({}, status: 302),
              'size' => response(null, raw: 'x' * 1001),
              'unknown' => response({
                'error': 'unavailable',
                'outcomeUnknown': true,
              }, status: 503),
              _ => response({
                'error': 'permission-denied',
                'details': 'PRIVATE',
              }, status: 403),
            };
          };
          await expectLater(
            f.transport.call(op, data(op)),
            throwsA(failure(unknown: mutation)),
          );
          expect(f.client.calls, hasLength(1));
        },
      );
    }
    for (final phase in ['token', 'headers', 'body']) {
      test(
        '$op $phase timeout is bounded and late work cannot publish',
        () async {
          final f = _Fixture(timeout: const Duration(milliseconds: 15));
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
            f.transport.call(op, data(op)),
            throwsA(
              failure(
                unknown: mutation && phase != 'token',
                code: 'deadline-exceeded',
              ),
            ),
          );
          token.complete('synthetic');
          headers.complete(response(reply(operations[op]!)));
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
    test('$op session invalidation withholds late result', () async {
      final f = _Fixture(), gate = Completer<http.StreamedResponse>();
      f.client.handle = (_) => gate.future;
      final pending = f.transport.call(op, data(op));
      await Future<void>.delayed(Duration.zero);
      final checked = expectLater(
        pending,
        throwsA(failure(unknown: mutation, code: 'session-changed')),
      );
      f.w.invalidate();
      f.changes.add(null);
      gate.complete(response(reply(operations[op]!)));
      await checked;
    });
  }
  test(
    'scope retains uncertainty across reconstruction, rejection and logout',
    () async {
      final f = _Fixture(), input = data('updateMenuItem');
      f.client.handle = (_) async => throw StateError('PRIVATE');
      await expectLater(
        f.transport.call('updateMenuItem', input),
        throwsA(failure(unknown: true)),
      );
      f.client.handle = (_) async =>
          response({'error': 'aborted'}, status: 409);
      await expectLater(
        f.build().call('updateMenuItem', {...input}),
        throwsA(failure(unknown: true, code: 'aborted')),
      );
      f.current = null;
      await expectLater(
        f.build().call('updateMenuItem', {...input}),
        throwsA(failure(unknown: true)),
      );
      expect(f.client.calls, hasLength(2));
    },
  );
  test(
    'same key cannot change operation/payload/actor episode or dispatch concurrently',
    () async {
      final f = _Fixture(),
          input = data('updateMenuItem'),
          gate = Completer<http.StreamedResponse>();
      f.client.handle = (_) => gate.future;
      final first = f.transport.call('updateMenuItem', input);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        f.build().call('updateMenuItem', {...input}),
        throwsA(failure(unknown: true, code: 'request-in-flight')),
      );
      gate.complete(response(reply('update')));
      await first;
      await expectLater(
        f.build().call('updateMenuItem', {...input, 'isAvailable': true}),
        throwsA(failure(code: 'already-exists')),
      );
      await expectLater(
        f.build().call('setMenuItemLifecycle', data('setMenuItemLifecycle')),
        throwsA(failure(code: 'already-exists')),
      );
      f.current = session(f.w, revision: 1);
      await expectLater(
        f.build().call('updateMenuItem', input),
        throwsA(failure(code: 'already-exists')),
      );
      expect(f.client.calls, hasLength(1));
    },
  );
  test(
    'caller map changes cannot change an in-flight payload; explicit unchanged replay is not automatic',
    () async {
      final f = _Fixture(),
          input = data('updateMenuItem'),
          gate = Completer<String?>();
      f.token = (_) => gate.future;
      final pending = f.transport.call('updateMenuItem', input);
      input['isAvailable'] = true;
      gate.complete('synthetic');
      await pending;
      expect(
        jsonDecode((f.client.calls.single as http.Request).body)['isAvailable'],
        false,
      );
      f.client.handle = (_) async => response(reply('update', changed: false));
      expect(
        (await f.transport.call(
          'updateMenuItem',
          data('updateMenuItem'),
        ))['changed'],
        false,
      );
      expect(f.client.calls, hasLength(2));
    },
  );
  test(
    'cleanup identity changes/stalls cannot publish successful mutation',
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
          transport.call('updateMenuItem', data('updateMenuItem')),
          throwsA(failure(unknown: true)),
        );
        expect(f.client.closed, false);
      }
    },
  );
}
