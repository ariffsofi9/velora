import 'package:flutter/foundation.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/secure_ai_service.dart';
import 'package:velora/services/workspace_session.dart';

WorkspaceSession session([String cafe = 'a', int generation = 0]) =>
    WorkspaceSession.fromVerified(
      CafeWorkspace(
        cafeId: cafe,
        uid: 'staff',
        ownerUid: 'owner',
        role: CafeRole.staff,
        membershipGeneration: generation,
      ),
    );
final ticket = 'a' * 64;
Map<String, Object> issued() => {
  'schemaVersion': 2,
  'ticketId': ticket,
  'expiresAt': 1900000000000,
};
Map<String, Object> result() => {
  'schemaVersion': 2,
  'provider': 'groq',
  'ticketId': ticket,
  'status': 'ok',
  'inventorySelection': {'eligibleCount': 1, 'usedCount': 1},
  'recipes': [
    {
      'title': 'Mock dish',
      'ingredients': [
        {'itemId': 'egg', 'quantity': 1, 'unit': 'pcs'},
      ],
      'steps': ['Cook safely.'],
      'whyRecommended': 'Uses stock.',
    },
  ],
};
Matcher failure(SecureAiFailure value) =>
    isA<SecureAiException>().having((e) => e.failure, 'failure', value);

final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

AndroidPilotPolicy _pilotPolicy(bool invalid) => AndroidPilotPolicy.parse(
  invalid
      ? {'VELORA_ANDROID_READ_ONLY_PILOT': 'false'}
      : {
          'VELORA_ANDROID_READ_ONLY_PILOT': 'true',
          'VELORA_FIREBASE_PROJECT': AndroidPilotPolicy.approvedProject,
          'VELORA_ANDROID_PILOT_BINDINGS': '[["owner","cafe"]]',
        },
  isWeb: false,
  platform: TargetPlatform.android,
);

class _ProbeTransport implements SecureAiTransport {
  int availabilityReads = 0, demoReads = 0, calls = 0;
  @override
  bool get available {
    availabilityReads++;
    return true;
  }

  @override
  bool get isDemo {
    demoReads++;
    return true;
  }

  @override
  Future<Object?> call(Map<String, Object> data) async {
    calls++;
    throw StateError('Unexpected external side effect');
  }
}

void main() {
  for (final invalid in [false, true]) {
    for (final max in [-1, 1, 3]) {
      test(
        'AI service invalid=$invalid max=$max rejects before providers and unrestricted dependency',
        () async {
          var providers = 0;
          final dependency = _ProbeTransport(), policy = _pilotPolicy(invalid);
          final service = SecureAiService(
            pilotPolicy: policy,
            currentSession: () {
              providers++;
              return session();
            },
            transport: dependency,
          );
          expect(service.pilotPolicy, same(policy));
          expect(service.available, false);
          expect(service.isDemo, false);
          expect(service.currentSession(), isNull);
          final captured = service.generate;
          await expectLater(
            captured(maxRecipes: max),
            throwsA(isA<SecureAiPilotPolicyException>()),
          );
          await expectLater(
            captured(maxRecipes: max),
            throwsA(failure(SecureAiFailure.denied)),
          );
          expect(providers, 0);
          expect(dependency.availabilityReads, 0);
          expect(dependency.demoReads, 0);
          expect(dependency.calls, 0);
        },
      );
    }
    test(
      'AI policy invalid=$invalid preserves default unavailable transport without provider lookup',
      () async {
        var providers = 0;
        final service = SecureAiService(
          pilotPolicy: _pilotPolicy(invalid),
          currentSession: () {
            providers++;
            throw StateError('Unexpected provider access');
          },
        );
        expect(service.available, false);
        expect(service.currentSession(), isNull);
        await expectLater(
          service.generate(),
          throwsA(failure(SecureAiFailure.denied)),
        );
        expect(providers, 0);
      },
    );
  }

  test(
    'valid mock sends only exact backend fields and labels result demo',
    () async {
      final current = session();
      final requests = <Map<String, Object>>[];
      final service = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => current,
        transport: MockSecureAiTransport((data) async {
          requests.add(data);
          return data['operation'] == 'issue' ? issued() : result();
        }),
      );
      final response = await service.generate();
      expect(response.isDemo, true);
      expect(response.recipes.single.title, 'Mock dish');
      expect(requests, [
        {
          'operation': 'issue',
          'expectedCafeId': 'a',
          'expectedMembershipGeneration': 0,
          'maxRecipes': 1,
        },
        {
          'operation': 'generate',
          'expectedCafeId': 'a',
          'expectedMembershipGeneration': 0,
          'maxRecipes': 1,
          'ticketId': ticket,
        },
      ]);
    },
  );
  test('default unavailable transport cannot invoke Firebase', () async {
    final s = SecureAiService(
      pilotPolicy: _normalPolicy,
      currentSession: () => session(),
    );
    expect(s.available, false);
    await expectLater(
      s.generate(),
      throwsA(failure(SecureAiFailure.unavailable)),
    );
  });
  test('missing/inactive workspace prevents issuance', () async {
    var calls = 0;
    final current = session()..invalidate();
    for (final candidate in [null, current]) {
      final s = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => candidate,
        transport: MockSecureAiTransport((_) async {
          calls++;
          return issued();
        }),
      );
      await expectLater(
        s.generate(),
        throwsA(failure(SecureAiFailure.workspaceChanged)),
      );
    }
    expect(calls, 0);
  });
  test(
    'switch while ticket issuance pending never sends generation request',
    () async {
      WorkspaceSession? current = session();
      final pending = Completer<Object?>();
      var calls = 0;
      final s = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => current,
        transport: MockSecureAiTransport((_) {
          calls++;
          return pending.future;
        }),
      );
      final request = s.generate();
      current = session('b');
      pending.complete(issued());
      await expectLater(
        request,
        throwsA(failure(SecureAiFailure.workspaceChanged)),
      );
      expect(calls, 1);
    },
  );
  for (final change in [
    'switch',
    'invalidate',
    'same workspace new generation',
    'new session same fields',
  ]) {
    test('$change during generation discards late response', () async {
      WorkspaceSession current = session();
      final pending = Completer<Object?>();
      final started = Completer<void>();
      final s = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => current,
        transport: MockSecureAiTransport((data) async {
          if (data['operation'] == 'issue') return issued();
          started.complete();
          return pending.future;
        }),
      );
      final request = s.generate();
      await started.future;
      if (change == 'invalidate') {
        current.invalidate();
      } else {
        current = change == 'switch'
            ? session('b')
            : change == 'same workspace new generation'
            ? session('a', 2)
            : session();
      }
      pending.complete(result());
      await expectLater(
        request,
        throwsA(failure(SecureAiFailure.workspaceChanged)),
      );
    });
  }
  for (final entry in {
    'resource-exhausted': SecureAiFailure.quota,
    'unavailable': SecureAiFailure.unavailable,
    'deadline-exceeded': SecureAiFailure.timeout,
    'permission-denied': SecureAiFailure.denied,
    'already-exists': SecureAiFailure.replayed,
  }.entries) {
    test('safe ${entry.key} mapping without retry', () async {
      final current = session();
      var calls = 0;
      final s = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => current,
        transport: MockSecureAiTransport((_) async {
          calls++;
          throw SecureAiTransportException(entry.key);
        }),
      );
      await expectLater(s.generate(), throwsA(failure(entry.value)));
      expect(calls, 1);
    });
  }
  test('timeout during issue does not later dispatch or retry', () async {
    final current = session();
    final pending = Completer<Object?>();
    var calls = 0;
    final s = SecureAiService(
      pilotPolicy: _normalPolicy,
      currentSession: () => current,
      timeout: const Duration(milliseconds: 5),
      transport: MockSecureAiTransport((_) {
        calls++;
        return pending.future;
      }),
    );
    await expectLater(s.generate(), throwsA(failure(SecureAiFailure.timeout)));
    pending.complete(issued());
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
  });
  test('duplicate taps in service do not issue another ticket', () async {
    final current = session();
    final pending = Completer<Object?>();
    var calls = 0;
    final s = SecureAiService(
      pilotPolicy: _normalPolicy,
      currentSession: () => current,
      transport: MockSecureAiTransport((data) async {
        calls++;
        if (data['operation'] == 'issue') return await pending.future;
        return result();
      }),
    );
    final first = s.generate();
    await expectLater(s.generate(), throwsA(failure(SecureAiFailure.busy)));
    pending.complete(issued());
    await first;
    expect(calls, 2);
  });
  for (final malformed in [
    'schema',
    'ticket',
    'extra',
    'quantity',
    'steps',
    'secret',
    'selection',
    'oversized',
  ]) {
    test('invalid $malformed response is never displayed', () async {
      final current = session();
      final data = result();
      if (malformed == 'schema') data['schemaVersion'] = 1;
      if (malformed == 'ticket') data['ticketId'] = 'b' * 64;
      if (malformed == 'extra') {
        data['providerHeaders'] = {'private': 'details'};
      }
      final recipe = (data['recipes'] as List).single as Map;
      if (malformed == 'quantity') {
        (recipe['ingredients'] as List).single['quantity'] = -1;
      }
      if (malformed == 'steps') recipe['steps'] = [];
      if (malformed == 'secret') recipe['title'] = 'gsk_${'x' * 30}';
      if (malformed == 'selection') {
        data['inventorySelection'] = {'eligibleCount': 1, 'usedCount': 21};
      }
      if (malformed == 'oversized') recipe['title'] = 'x' * 66000;
      final s = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => current,
        transport: MockSecureAiTransport(
          (request) async => request['operation'] == 'issue' ? issued() : data,
        ),
      );
      await expectLater(
        s.generate(),
        throwsA(failure(SecureAiFailure.invalidResponse)),
      );
    });
  }
  test('invalid ticket response prevents generate stage', () async {
    final current = session();
    var calls = 0;
    final s = SecureAiService(
      pilotPolicy: _normalPolicy,
      currentSession: () => current,
      transport: MockSecureAiTransport((_) async {
        calls++;
        return {...issued(), 'ticketId': 'bad'};
      }),
    );
    await expectLater(
      s.generate(),
      throwsA(failure(SecureAiFailure.invalidResponse)),
    );
    expect(calls, 1);
  });
  test('raw exceptions are sanitized', () async {
    final current = session();
    final s = SecureAiService(
      pilotPolicy: _normalPolicy,
      currentSession: () => current,
      transport: MockSecureAiTransport(
        (_) async => throw StateError('private account/provider details'),
      ),
    );
    await expectLater(
      s.generate(),
      throwsA(
        predicate(
          (e) => e is SecureAiException && !e.toString().contains('private'),
        ),
      ),
    );
  });
  test('legacy Flutter provider has no direct endpoint or HTTP transport', () {
    final legacy = File('lib/logic/groq_service.dart').readAsStringSync();
    expect(legacy, isNot(contains('api.groq.com')));
    expect(legacy, isNot(contains('http')));
    final service = File(
      'lib/services/secure_ai_service.dart',
    ).readAsStringSync();
    expect(service, isNot(contains('cloud_functions')));
    expect(service, isNot(contains('api.groq.com')));
  });
  test(
    'generation timeout does not issue another ticket or replay lost response',
    () async {
      final current = session();
      var calls = 0;
      final pending = Completer<Object?>();
      final s = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => current,
        timeout: const Duration(milliseconds: 5),
        transport: MockSecureAiTransport((data) async {
          calls++;
          if (data['operation'] == 'issue') return issued();
          return await pending.future;
        }),
      );
      await expectLater(
        s.generate(),
        throwsA(failure(SecureAiFailure.timeout)),
      );
      pending.complete(result());
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
    },
  );
  test(
    'empty fresh response is represented without invented recipes',
    () async {
      final current = session();
      final data = result();
      data['recipes'] = [];
      data['status'] = 'no_suggestions';
      final s = SecureAiService(
        pilotPolicy: _normalPolicy,
        currentSession: () => current,
        transport: MockSecureAiTransport(
          (request) async => request['operation'] == 'issue' ? issued() : data,
        ),
      );
      expect((await s.generate()).recipes, isEmpty);
    },
  );
}
