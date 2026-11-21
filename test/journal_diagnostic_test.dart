import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/journal_diagnostic/main.dart';

import 'mutation_recovery_service_test.dart' show FakeMutationPersistence;

class _App extends Fake implements FirebaseApp {
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'synthetic',
    appId: 'synthetic',
    messagingSenderId: 'synthetic',
    projectId: 'velora-spark-test',
  );
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth({this.verified = true});
  final bool verified;
  @override
  final FirebaseApp app = _App();
  @override
  late final User currentUser = _User(verified);
  @override
  Stream<User?> authStateChanges() => Stream<User?>.multi((events) {
    events.add(currentUser);
  });
}

class _User extends Fake implements User {
  _User(this.emailVerified);
  @override
  final bool emailVerified;
  @override
  String get uid => 'synthetic-journal-owner';
  @override
  String get email => 'synthetic@example.invalid';

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return [
      encode({'alg': 'RS256', 'kid': 'fake'}),
      encode({
        'sub': uid,
        'email': email,
        'email_verified': emailVerified,
        'aud': 'velora-spark-test',
        'iss': 'https://securetoken.google.com/velora-spark-test',
        'iat': now,
        'auth_time': now,
        'exp': now + 500,
      }),
      'c2VjcmV0',
    ].join('.');
  }
}

void main() {
  late Directory root;
  late DiagnosticTrace trace;
  late FakeMutationPersistence persistence;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('velora-diagnostic-test-');
    trace = DiagnosticTrace();
    persistence = FakeMutationPersistence();
  });

  tearDown(() async {
    trace.dispose();
    await for (final entry in root.list(followLinks: false)) {
      await entry.delete();
    }
    await root.delete();
  });

  JournalDiagnostic runner({
    FirebaseAuth? auth,
    Future<Directory> Function()? directory,
    DiagnosticTrace? output,
  }) => JournalDiagnostic(
    trace: output ?? trace,
    directory: directory ?? () async => root,
    persistence: (_) => persistence,
    auth: auth ?? _Auth(),
  );

  File receipt() => File('${root.path}/synthetic-stock-receipt.json');

  bool has(DiagnosticStage stage, String outcome) =>
      trace.events.any((event) => event.endsWith(' ${stage.code} $outcome'));

  for (final stage in DiagnosticStage.values) {
    test(
      '${stage.code} reports entry, acknowledgement, and sanitized failure',
      () async {
        expect(await trace.stage(stage, () async => 1), 1);
        await expectLater(
          trace.stage(stage, () async => throw StateError('secret file path')),
          throwsStateError,
        );
        expect(trace.events, [
          '1 ${stage.code} ENTER',
          '2 ${stage.code} OK',
          '3 ${stage.code} ENTER',
          '4 ${stage.code} FAIL UNAVAILABLE',
        ]);
      },
    );
  }

  test('timeout classified without exposing details', () async {
    await expectLater(
      trace.stage(
        DiagnosticStage.directory,
        () async => throw TimeoutException('secret'),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(
      has(DiagnosticStage.directory, 'FAIL TIMEOUT'),
      isTrue,
      reason: trace.events.join(", "),
    );
  });

  test(
    'one dispatch follows both commit acknowledgements and leaves unknown',
    () async {
      final diagnostic = runner();
      expect(await diagnostic.canPrepare(), isTrue);
      expect(await diagnostic.prepare(), isTrue);
      final events = trace.events
          .map((e) => e.substring(e.indexOf(' ') + 1))
          .toList();
      const order = [
        'DIRECTORY OK',
        'ATTEMPT OK',
        'SQLITE_SNAPSHOT OK',
        'FRESH_STATE OK',
        'SESSION_BIND OK',
        'JOURNAL_PREPARE OK',
        'DISPATCH_MARKER OK',
        'HANDLER_ENTRY ENTER',
        'HANDLER_ENTRY OK',
        'RECEIPT_CREATE OK',
        'RECEIPT_FLUSH OK',
        'JOURNAL_FINISH OK',
        'FINAL_VERIFY OK',
        'CLOSE OK',
      ];
      var previous = -1;
      for (final event in order) {
        final index = events.indexOf(event);
        expect(index, greaterThan(previous), reason: event);
        previous = index;
      }
      expect(events.where((e) => e == 'HANDLER_ENTRY ENTER'), hasLength(1));
      final stored = persistence.values.values.single as Map;
      expect(stored['state'], 'unknown');
      expect(stored['everUncertain'], isTrue);
      expect(persistence.writes, 3);
      final saved = await receipt().readAsString();
      expect((jsonDecode(saved) as Map)['dispatches'], 1);
      expect(saved, isNot(contains('authorization')));
      expect(saved, isNot(contains('c2VjcmV0')));
      expect(await diagnostic.prepare(), isFalse);
      final freshTrace = DiagnosticTrace();
      addTearDown(freshTrace.dispose);
      final restartedRunner = runner(output: freshTrace);
      expect(await restartedRunner.canPrepare(), isFalse);
      expect(await restartedRunner.prepare(), isFalse);
      expect(freshTrace.events.last, endsWith('ATTEMPT FAIL REJECTED'));
      expect(persistence.writes, 3);
      expect(await receipt().readAsString(), saved);
    },
  );

  test('private directory failure leaves storage untouched', () async {
    final diagnostic = runner(
      directory: () async => throw StateError('private'),
    );
    expect(await diagnostic.prepare(), isFalse);
    expect(await diagnostic.prepare(), isFalse);
    expect(trace.events.last, endsWith('DIRECTORY FAIL UNAVAILABLE'));
    expect(await root.list().toList(), isEmpty);
    expect(persistence.writes, 0);
  });

  test('snapshot failure leaves marker but never prepares journal', () async {
    persistence.failRead = true;
    expect(await runner().prepare(), isFalse);
    expect(trace.events.last, endsWith('SQLITE_SNAPSHOT FAIL UNAVAILABLE'));
    expect(await File('${root.path}/prepare-attempt-v1').exists(), isTrue);
    expect(await runner().canPrepare(), isFalse);
    expect(persistence.writes, 0);
  });

  test('pre-existing receipt is never overwritten', () async {
    await receipt().writeAsString('preserved');
    expect(await runner().prepare(), isFalse);
    expect(trace.events.last, endsWith('FRESH_STATE FAIL REJECTED'));
    expect(await receipt().readAsString(), 'preserved');
    expect(persistence.writes, 0);
  });

  test('unverified synthetic session blocks before persistence', () async {
    expect(await runner(auth: _Auth(verified: false)).prepare(), isFalse);
    expect(
      has(DiagnosticStage.sessionBind, 'FAIL REJECTED'),
      isTrue,
      reason: trace.events.join(", "),
    );
    expect(persistence.writes, 0);
  });

  for (final write in [1, 2]) {
    test(
      'lost acknowledgement at journal write $write never dispatches',
      () async {
        persistence.beforeWrite = (count) async {
          persistence.lostAck = count == write;
        };
        final diagnostic = runner();
        expect(await diagnostic.prepare(), isFalse);
        expect(
          has(
            write == 1
                ? DiagnosticStage.journalPrepare
                : DiagnosticStage.dispatchMarker,
            'FAIL OUTCOME_UNCERTAIN',
          ),
          isTrue,
          reason: trace.events.join(", "),
        );
        expect(has(DiagnosticStage.handlerEntry, 'ENTER'), isFalse);
        expect(await receipt().exists(), isFalse);
        expect(await diagnostic.prepare(), isFalse);
        expect(await runner().canPrepare(), isFalse);
      },
    );
  }

  test(
    'receipt collision after handler entry gives no flush acknowledgement',
    () async {
      persistence.beforeWrite = (count) async {
        if (count == 2) await receipt().writeAsString('collision');
      };
      expect(await runner().prepare(), isFalse);
      expect(
        has(DiagnosticStage.handlerEntry, 'OK'),
        isTrue,
        reason: trace.events.join(", "),
      );
      expect(
        has(DiagnosticStage.receiptCreate, 'FAIL OUTCOME_UNCERTAIN'),
        isTrue,
        reason: trace.events.join(", "),
      );
      expect(has(DiagnosticStage.receiptFlush, 'ENTER'), isFalse);
      expect(await receipt().readAsString(), 'collision');
    },
  );

  test('final verification failure after flush stays blocked', () async {
    persistence.beforeWrite = (count) async {
      if (count == 3) {
        await receipt().writeAsString('corrupted synthetic evidence');
      }
    };
    expect(await runner().prepare(), isFalse);
    expect(
      has(DiagnosticStage.receiptFlush, 'OK'),
      isTrue,
      reason: trace.events.join(", "),
    );
    expect(
      has(DiagnosticStage.finalVerify, 'FAIL REJECTED'),
      isTrue,
      reason: trace.events.join(", "),
    );
    expect(await runner().canPrepare(), isFalse);
  });
}
