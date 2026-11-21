import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';

import '../tool/firestore_runtime_qualification_runner.dart';

const _hash =
    '73844e2174c028696bf5b36f22fbc2a6e2a3f6849ad9848913135e393d173611';

QualificationRequest _request({
  QualificationCase scenario = QualificationCase.ownerBootstrap,
  String project = 'velora-spark-test',
  String database = '(default)',
  String? hash = _hash,
  String? account,
  String? cafe,
  bool authorized = true,
}) {
  final owner = scenario == QualificationCase.ownerBootstrap;
  return QualificationRequest(
    scenario: scenario,
    projectId: project,
    databaseId: database,
    rulesSha256: hash,
    accountAlias: account ?? (owner ? 'synthetic-owner' : 'synthetic-staff'),
    cafeAlias: cafe ?? (owner ? 'synthetic-new-cafe' : 'synthetic-staff-cafe'),
    authorized: authorized,
  );
}

class _App extends Fake implements FirebaseApp {
  @override
  final FirebaseOptions options;
  _App(String project)
    : options = FirebaseOptions(
        apiKey: 'fixture-only',
        appId: 'fixture-only',
        messagingSenderId: 'fixture-only',
        projectId: project,
      );
  @override
  String get name => 'fake-test-app';
}

class _User extends Fake implements User {
  @override
  final String uid;
  _User(this.uid);
  @override
  bool get emailVerified => true;
  @override
  Future<void> reload() async {}
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async {
    expect(forceRefresh, isTrue);
    return _VerifiedToken();
  }
}

class _VerifiedToken extends Fake implements IdTokenResult {
  @override
  Map<String, dynamic> get claims => {'email_verified': true};
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  final FirebaseApp app;
  final String uid;
  int identityReads = 0;
  _Auth(this.app, {this.uid = 'staff-a'});
  @override
  Stream<User?> authStateChanges() => Stream<User?>.multi((controller) {
    // Firebase emits the current user on subscription and keeps listening.
    controller.add(currentUser);
  });

  @override
  User get currentUser {
    identityReads++;
    return _User(uid);
  }
}

// Offline SDK doubles record paths without constructing platform delegates.
// ignore: subtype_of_sealed_class
class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  @override
  final String path;
  _Document(this.path);
  @override
  String get id => path.split('/').last;
}

// ignore: subtype_of_sealed_class
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _Document('cafes/${path ?? 'generated-synthetic-cafe'}');
}

// ignore: subtype_of_sealed_class
class _Snapshot<T extends Object?> extends Fake implements DocumentSnapshot<T> {
  final T? value;
  _Snapshot(this.value);
  @override
  T? data() => value;
}

class _Transaction extends Fake implements Transaction {
  final Map<String, Map<String, dynamic>> documents;
  final List<String> reads;
  final Map<String, Map<String, dynamic>> writes;
  _Transaction(this.documents, this.reads, this.writes);

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> ref,
  ) async {
    reads.add(ref.path);
    return _Snapshot<T>(documents[ref.path] as T?);
  }

  @override
  Transaction set<T>(
    DocumentReference<T> documentReference,
    T data, [
    SetOptions? options,
  ]) {
    writes[documentReference.path] = Map<String, dynamic>.from(data as Map);
    return this;
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  @override
  final FirebaseApp app;
  @override
  final String databaseId;
  final bool retryCallback;
  final String linkedCafe;
  final String? host;
  final reads = <String>[];
  final writes = <String, Map<String, dynamic>>{};
  int transactions = 0;
  _Firestore(
    this.app, {
    this.databaseId = '(default)',
    this.retryCallback = false,
    this.linkedCafe = 'cafe-a',
    this.host,
  });

  @override
  Settings get settings => Settings(host: host);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    expect(collectionPath, 'cafes');
    return _Collection();
  }

  @override
  DocumentReference<Map<String, dynamic>> doc(String documentPath) =>
      _Document(documentPath);

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    transactions++;
    expect(timeout, const Duration(seconds: 10));
    expect(maxAttempts, 1);
    Map<String, dynamic> link(String uid, {String cafe = 'cafe-a'}) => {
      'uid': uid,
      'cafeId': cafe,
      'status': 'active',
      'schemaVersion': 1,
      'membershipGeneration': 7,
    };
    final tx = _Transaction(
      {
        'user_cafe_memberships/staff-a': link('staff-a', cafe: linkedCafe),
        'cafes/cafe-a': {
          'ownerUid': 'owner-a',
          'status': 'active',
          'schemaVersion': 1,
        },
        'cafes/cafe-a/members/staff-a': {...link('staff-a'), 'role': 'staff'},
        'cafes/cafe-a/members/owner-a': {...link('owner-a'), 'role': 'owner'},
        'user_cafe_memberships/owner-a': link('owner-a'),
      },
      reads,
      writes,
    );
    final result = await transactionHandler(tx);
    if (retryCallback) return transactionHandler(tx);
    return result;
  }
}

FirestoreRuntimeQualificationRunner _runner(_Auth auth, _Firestore store) =>
    FirestoreRuntimeQualificationRunner.withTestClients(
      auth: auth,
      firestore: store,
      bootstrapUid: 'bootstrap-owner-a',
      expectedStaff: const CafeWorkspace(
        cafeId: 'cafe-a',
        uid: 'staff-a',
        ownerUid: 'owner-a',
        role: CafeRole.staff,
        membershipGeneration: 7,
      ),
    );

void main() {
  test(
    'rejects target, hash, authorization and fixture errors before execution',
    () async {
      var calls = 0;
      final runner = FirestoreRuntimeQualificationRunner.synthetic((_) async {
        calls++;
        return true;
      });
      for (final (request, expected) in [
        (_request(project: 'velora-73222'), QualificationStatus.wrongTarget),
        (_request(project: 'unknown'), QualificationStatus.wrongTarget),
        (_request(database: 'other'), QualificationStatus.wrongTarget),
        (_request(hash: null), QualificationStatus.wrongRules),
        (_request(hash: 'wrong'), QualificationStatus.wrongRules),
        (_request(authorized: false), QualificationStatus.unauthorized),
        (
          _request(account: 'synthetic-staff'),
          QualificationStatus.invalidFixture,
        ),
        (_request(cafe: 'actual-cafe'), QualificationStatus.invalidFixture),
      ]) {
        expect(await runner.run(request), expected);
      }
      expect(calls, 0);
    },
  );

  test(
    'default runner stays unwired even with otherwise valid authorization',
    () async {
      final runner = FirestoreRuntimeQualificationRunner();
      expect(await runner.run(_request()), QualificationStatus.unwired);
    },
  );

  test(
    'actual client binding mismatch stops before touching identity or Firestore',
    () async {
      final testApp = _App('velora-spark-test');
      final auth = _Auth(testApp);
      for (final store in [
        _Firestore(_App('velora-73222')),
        _Firestore(testApp, databaseId: 'other'),
        _Firestore(testApp, host: 'localhost:8080'),
      ]) {
        expect(
          await _runner(auth, store).run(_request()),
          QualificationStatus.wrongTarget,
        );
        expect(store.transactions, 0);
      }
      expect(auth.identityReads, 0);
    },
  );

  test(
    'Owner uses the canonical bootstrap with one read and three writes',
    () async {
      final app = _App('velora-spark-test');
      final store = _Firestore(app);
      final result = await _runner(
        _Auth(app, uid: 'bootstrap-owner-a'),
        store,
      ).run(_request());
      expect(result, QualificationStatus.passed);
      expect(store.transactions, 1);
      expect(store.reads, ['user_cafe_memberships/bootstrap-owner-a']);
      expect(store.writes.keys, [
        'cafes/generated-synthetic-cafe',
        'cafes/generated-synthetic-cafe/members/bootstrap-owner-a',
        'user_cafe_memberships/bootstrap-owner-a',
      ]);
      expect(
        store.writes.values.every(
          (data) =>
              data['createdAt'] is FieldValue &&
              data['updatedAt'] is FieldValue,
        ),
        isTrue,
      );
    },
  );

  test('one attempt per phase and no concurrent or third operation', () async {
    const staff = QualificationCase.staffResolver;
    final first = Completer<bool>();
    final calls = <QualificationCase>[];
    final runner = FirestoreRuntimeQualificationRunner.synthetic((
      scenario,
    ) async {
      calls.add(scenario);
      return scenario == staff ? true : first.future;
    });
    final owner = runner.run(_request());
    expect(
      await runner.run(_request(scenario: staff)),
      QualificationStatus.budgetExhausted,
    );
    first.complete(true);
    expect(await owner, QualificationStatus.passed);
    expect(await runner.run(_request()), QualificationStatus.budgetExhausted);
    expect(
      await runner.run(_request(scenario: staff)),
      QualificationStatus.passed,
    );
    expect(
      await runner.run(_request(scenario: staff)),
      QualificationStatus.budgetExhausted,
    );
    expect(calls, QualificationCase.values);
  });

  test('timeout halts the runner even if work finishes late', () async {
    final pending = Completer<bool>();
    final runner = FirestoreRuntimeQualificationRunner.synthetic(
      (_) => pending.future,
      timeout: const Duration(milliseconds: 10),
    );
    expect(await runner.run(_request()), QualificationStatus.inconclusive);
    pending.complete(true);
    expect(
      await runner.run(_request(scenario: QualificationCase.staffResolver)),
      QualificationStatus.budgetExhausted,
    );
  });

  test('errors and fixture information are absent from results', () async {
    final runner = FirestoreRuntimeQualificationRunner.synthetic(
      (_) async =>
          throw StateError('private-email token raw backend exception'),
    );
    final result = await runner.run(_request());
    expect(result.name, 'inconclusive');
    expect(await runner.run(_request()), QualificationStatus.budgetExhausted);
  });

  for (final retry in [false, true]) {
    test(
      'Staff uses one canonical five-read transaction, retry=$retry',
      () async {
        final app = _App('velora-spark-test');
        final store = _Firestore(app, retryCallback: retry);
        final result = await _runner(
          _Auth(app),
          store,
        ).run(_request(scenario: QualificationCase.staffResolver));
        expect(
          result,
          retry ? QualificationStatus.inconclusive : QualificationStatus.passed,
        );
        expect(store.transactions, 1);
        expect(store.reads, [
          'user_cafe_memberships/staff-a',
          'cafes/cafe-a',
          'cafes/cafe-a/members/staff-a',
          'cafes/cafe-a/members/owner-a',
          'user_cafe_memberships/owner-a',
        ]);
      },
    );
  }

  test(
    'Staff fixture cannot read a different cafe selected by the mapping',
    () async {
      final app = _App('velora-spark-test');
      final store = _Firestore(app, linkedCafe: 'foreign-cafe');
      expect(
        await _runner(
          _Auth(app),
          store,
        ).run(_request(scenario: QualificationCase.staffResolver)),
        QualificationStatus.inconclusive,
      );
      expect(store.reads, ['user_cafe_memberships/staff-a']);
    },
  );
}
