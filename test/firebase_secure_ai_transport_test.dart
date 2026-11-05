import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/firebase_secure_ai_transport.dart';
import 'package:velora/services/secure_ai_service.dart';
import 'secure_ai_service_test.dart' as support;

class _Result<T> extends Fake implements HttpsCallableResult<T> {
  @override
  final T data;
  _Result(this.data);
}

class _SdkError extends FirebaseFunctionsException {
  _SdkError(String code, Object? details)
    : super(code: code, message: 'private provider/key/path', details: details);
}

class _Functions extends Fake implements FirebaseFunctions {
  final Map<String, dynamic> fixture;
  int references = 0;
  int invocations = 0;
  _Functions(this.fixture);
  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) {
    references++;
    expect(options?.timeout, const Duration(seconds: 30));
    return _Callable(this, name);
  }
}

class _Callable extends Fake implements HttpsCallable {
  final _Functions owner;
  final String name;
  _Callable(this.owner, this.name);
  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async {
    owner.invocations++;
    final stage = parameters['operation'] as String;
    expect(name, owner.fixture['names'][stage]);
    return _Result<T>(owner.fixture['${stage}Response'] as T);
  }
}

void main() {
  final fixture =
      jsonDecode(
            File(
              'test/fixtures/secure_ai_callable_contract.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  Map<String, Object> request(String operation) =>
      Map<String, Object>.from(fixture['${operation}Request'] as Map);
  test('shared names and response-data limit match backend', () {
    expect(issueWorkspaceAiTicket, fixture['names']['issue']);
    expect(generateWorkspaceAiRecipes, fixture['names']['generate']);
    expect(secureAiMaxResponseBytes, fixture['maxResponseBytes']);
  });
  test(
    'actual SDK result interface is unwrapped once for both operations',
    () async {
      final calls = <String>[];
      final transport = FirebaseSecureAiTransport(
        enabled: true,
        invoke: (name, data) async {
          calls.add(name);
          return _Result<dynamic>(fixture['${data['operation']}Response']);
        },
      );
      expect(await transport.call(request('issue')), fixture['issueResponse']);
      expect(
        await transport.call(request('generate')),
        fixture['generateResponse'],
      );
      expect(calls, [issueWorkspaceAiTicket, generateWorkspaceAiRecipes]);
    },
  );
  test(
    'fromFunctions uses injected fake SDK and never obtains a global instance',
    () async {
      final functions = _Functions(fixture);
      final disabled = FirebaseSecureAiTransport.fromFunctions(functions);
      expect(functions.references, 0);
      expect(disabled.available, false);
      await expectLater(
        disabled.call(request('issue')),
        throwsA(isA<SecureAiException>()),
      );
      expect(functions.invocations, 0);
      final transport = FirebaseSecureAiTransport.fromFunctions(
        functions,
        enabled: true,
      );
      final current = support.session();
      final service = SecureAiService(
        currentSession: () => current,
        transport: transport,
      );
      final result = await service.generate();
      expect(result.recipes.single.title, 'Sample dish');
      expect(result.isDemo, false);
      expect(functions.invocations, 2);
      expect(functions.references, 2);
    },
  );
  test(
    'default injected adapter is disabled as well as default service transport',
    () async {
      var calls = 0;
      final transport = FirebaseSecureAiTransport(
        invoke: (_, _) async {
          calls++;
          return _Result<dynamic>(null);
        },
      );
      await expectLater(
        transport.call(request('issue')),
        throwsA(isA<SecureAiException>()),
      );
      expect(calls, 0);
      expect(SecureAiService(currentSession: () => null).available, false);
    },
  );
  for (final raw in [
    null,
    [],
    'invalid',
    123,
    {'data': fixture['issueResponse']},
  ]) {
    test('invalid/missing SDK data envelope fails closed $raw', () async {
      final transport = FirebaseSecureAiTransport(
        enabled: true,
        invoke: (_, _) async => _Result<dynamic>(raw),
      );
      final current = support.session();
      final service = SecureAiService(
        currentSession: () => current,
        transport: transport,
      );
      await expectLater(
        service.generate(),
        throwsA(support.failure(SecureAiFailure.invalidResponse)),
      );
    });
  }
  for (final entry in fixture['errors'] as List) {
    test(
      'shared SDK error ${entry['code']}/${entry['reason']} maps without secret text',
      () async {
        var calls = 0;
        final current = support.session();
        final transport = FirebaseSecureAiTransport(
          enabled: true,
          invoke: (_, _) async {
            calls++;
            throw _SdkError(entry['code'] as String, {
              'reason': entry['reason'],
            });
          },
        );
        final service = SecureAiService(
          currentSession: () => current,
          transport: transport,
        );
        await expectLater(
          service.generate(),
          throwsA(
            predicate(
              (error) =>
                  error is SecureAiException &&
                  error.failure.name == entry['failure'] &&
                  !error.toString().contains('private'),
            ),
          ),
        );
        expect(calls, 1);
      },
    );
  }
  test(
    'unreviewed details cannot override SDK code or expose provider text',
    () async {
      final transport = FirebaseSecureAiTransport(
        enabled: true,
        invoke: (_, _) async => throw _SdkError('unavailable', {
          'reason': 'account-disabled',
          'secret': 'private',
        }),
      );
      await expectLater(
        transport.call(request('issue')),
        throwsA(
          predicate(
            (error) =>
                error is SecureAiTransportException &&
                error.code == 'unavailable' &&
                error.reason == null,
          ),
        ),
      );
    },
  );
  test('unknown SDK code is sanitized', () async {
    final transport = FirebaseSecureAiTransport(
      enabled: true,
      invoke: (_, _) async => throw _SdkError('private-code', 'private'),
    );
    await expectLater(
      transport.call(request('issue')),
      throwsA(
        predicate(
          (error) =>
              error is SecureAiTransportException &&
              error.code == 'unavailable' &&
              error.reason == null,
        ),
      ),
    );
  });
  test('unsupported request fields and JSON types never invoke SDK', () async {
    var calls = 0;
    final transport = FirebaseSecureAiTransport(
      enabled: true,
      invoke: (_, _) async {
        calls++;
        return _Result<dynamic>(null);
      },
    );
    for (final data in [
      {...request('issue'), 'payloadDigest': 'forged'},
      {...request('issue'), 'maxRecipes': '1'},
      {...request('issue'), 'operation': 'other'},
      {...request('generate'), 'ticketId': 'bad'},
    ]) {
      await expectLater(
        transport.call(data),
        throwsA(isA<SecureAiTransportException>()),
      );
    }
    expect(calls, 0);
  });
  test(
    'UTF-8 exact response-data boundary and one byte over match backend',
    () {
      final overhead = utf8.encode(jsonEncode({'padding': ''})).length;
      final exact = {
        'padding': 'é' * ((secureAiMaxResponseBytes - overhead) ~/ 2),
      };
      expect(secureAiJsonBytes(exact), secureAiMaxResponseBytes);
      expect(() => validateSecureAiResponseBytes(exact), returnsNormally);
      expect(
        () =>
            validateSecureAiResponseBytes({'padding': '${exact['padding']}a'}),
        throwsA(isA<SecureAiException>()),
      );
      expect(
        () => validateSecureAiResponseBytes({'value': '🥐 café'}),
        returnsNormally,
      );
      for (final raw in [
        double.nan,
        {'value': double.infinity},
        {'value': String.fromCharCode(0xd800)},
      ]) {
        expect(
          () => validateSecureAiResponseBytes(raw),
          throwsA(isA<SecureAiException>()),
        );
      }
      expect(
        secureAiJsonBytes({'value': 1.0}),
        secureAiJsonBytes({'value': 1}),
      );
    },
  );
  test('SDK timeout/lost response never reissues or redispatches', () async {
    var calls = 0;
    final current = support.session();
    final pending = Completer<HttpsCallableResult<dynamic>>();
    final transport = FirebaseSecureAiTransport(
      enabled: true,
      invoke: (_, data) async {
        calls++;
        if (data['operation'] == 'issue') {
          return _Result<dynamic>(fixture['issueResponse']);
        }
        return await pending.future;
      },
    );
    final service = SecureAiService(
      currentSession: () => current,
      transport: transport,
      timeout: const Duration(milliseconds: 5),
    );
    await expectLater(
      service.generate(),
      throwsA(support.failure(SecureAiFailure.timeout)),
    );
    pending.complete(_Result<dynamic>(fixture['generateResponse']));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
  });
  test('invoker TimeoutException is typed without retry', () async {
    var calls = 0;
    final transport = FirebaseSecureAiTransport(
      enabled: true,
      invoke: (_, _) async {
        calls++;
        throw TimeoutException('private transport details');
      },
    );
    await expectLater(
      transport.call(request('issue')),
      throwsA(
        predicate(
          (error) =>
              error is SecureAiTransportException &&
              error.code == 'deadline-exceeded',
        ),
      ),
    );
    expect(calls, 1);
  });
}
