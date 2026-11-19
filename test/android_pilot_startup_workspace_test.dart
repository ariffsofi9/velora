// Synthetic SDK/store boundaries only. No Firebase initialization or network.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/main.dart' as app;
import 'package:velora/screens/auth/forgot_password_page.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/signup_page.dart';
import 'package:velora/screens/auth/splash_page.dart';
import 'package:velora/screens/auth/welcome_page.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'package:velora/screens/auth/workspace_session_boundary.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/services/auth_service.dart';
import 'package:velora/services/firebase_startup_config.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_store.dart';

Map<String, String> configuration() => {
  AndroidPilotPolicy.modeKey: 'true',
  AndroidPilotPolicy.projectKey: AndroidPilotPolicy.approvedProject,
  AndroidPilotPolicy.bindingsKey: jsonEncode([
    ['synthetic-owner', 'synthetic-cafe'],
    ['synthetic-staff', 'synthetic-cafe'],
  ]),
};
AndroidPilotPolicy parse(Map<String, String> values) =>
    AndroidPilotPolicy.parse(
      values,
      isWeb: false,
      platform: TargetPlatform.android,
    );

class _User extends Fake implements User {
  @override
  final String uid;
  @override
  final bool emailVerified;
  _User({this.uid = 'synthetic-owner', this.emailVerified = true});
  @override
  String get email => 'synthetic@example.test';
}

class _Credential extends Fake implements UserCredential {
  @override
  final User user;
  _Credential(this.user);
}

class _Auth extends Fake implements FirebaseAuth {
  User? user;
  int signIns = 0, creates = 0, emails = 0, signOuts = 0, listeners = 0;
  Completer<void>? resetPending;
  late final changes = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => user;
  void replace(User? next) {
    user = next;
    changes.add(next);
  }

  @override
  Stream<User?> authStateChanges() => Stream<User?>.multi((controller) {
    listeners++;
    final sub = changes.stream.listen(
      controller.addSync,
      onError: controller.addErrorSync,
      onDone: controller.closeSync,
    );
    controller.onCancel = () {
      listeners--;
      unawaited(sub.cancel());
    };
    controller.addSync(user);
  });
  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    signIns++;
    final next = _User();
    replace(next);
    return _Credential(next);
  }

  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    creates++;
    throw StateError('Registration must not dispatch');
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    ActionCodeSettings? actionCodeSettings,
  }) async {
    emails++;
    await resetPending?.future;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    replace(null);
  }
}

class _Record {
  Map<String, dynamic>? data;
  Object? error;
  Completer<void>? pending;
  late final changed = StreamController<void>.broadcast(sync: true);
  _Record(this.data);
}

class _Metadata extends Fake implements SnapshotMetadata {
  final bool cached;
  _Metadata(this.cached);
  @override
  bool get isFromCache => cached;
  @override
  bool get hasPendingWrites => false;
}

class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  @override
  final String id;
  final Map<String, dynamic>? value;
  final bool cached;
  _Snapshot(String path, this.value, {this.cached = false})
    : id = path.split('/').last;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
  @override
  SnapshotMetadata get metadata => _Metadata(cached);
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _Database db;
  @override
  final String path;
  _Document(this.db, this.path);
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    db.reads.add((path, options?.source));
    final record = db.record(path);
    await record.pending?.future;
    if (record.error != null) throw record.error!;
    return _Snapshot(path, record.data);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    db.writes++;
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    db.writes++;
  }

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => Stream<DocumentSnapshot<Map<String, dynamic>>>.multi((controller) {
    final record = db.record(path);
    final sub = record.changed.stream.listen(
      (_) => controller.addSync(
        _Snapshot(path, record.data, cached: db.cacheAuthority),
      ),
    );
    controller.onCancel = sub.cancel;
    controller.addSync(_Snapshot(path, record.data, cached: db.cacheAuthority));
  });
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _Database db;
  @override
  final String path;
  _Collection(this.db, this.path);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _Document(db, '${this.path}/$path');
}

class _Database extends Fake implements FirebaseFirestore {
  bool cacheAuthority = false;
  final records = <String, _Record>{};
  final reads = <(String, Source?)>[];
  int writes = 0;
  _Record record(String path) => records.putIfAbsent(path, () => _Record(null));
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);
  @override
  DocumentReference<Map<String, dynamic>> doc(String path) =>
      _Document(this, path);
}

class _Store implements WorkspaceStore, WorkspaceReader {
  final _Database db;
  Completer<void>? pending;
  int transactions = 0;
  final paths = <String>[];
  _Store(this.db);
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(WorkspaceReader reader) read,
  ) async {
    transactions++;
    await pending?.future;
    return read(this);
  }

  @override
  Future<Map<String, dynamic>?> readDocument(String path) async {
    paths.add(path);
    return db.record(path).data;
  }
}

class _Fixture {
  final auth = _Auth();
  final db = _Database();
  late final _Store store = _Store(db);
  late final WorkspaceResolver resolver = WorkspaceResolver(
    auth: auth,
    store: store,
    debugLog: (_) {},
  );
  late final AndroidPilotAuthDependencies dependencies;
  _Fixture({AndroidPilotPolicy? policy, bool staff = false}) {
    final uid = staff ? 'synthetic-staff' : 'synthetic-owner';
    auth.user = _User(uid: uid);
    final timestamp = Timestamp.fromMillisecondsSinceEpoch(1000);
    for (final actor in ['synthetic-owner', 'synthetic-staff']) {
      db.record('users/$actor').data = {
        'username': 'Synthetic User',
        'email': 'synthetic@example.test',
        'photoUrl': '',
        'role': 'owner',
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };
      final link = <String, dynamic>{
        'uid': actor,
        'cafeId': 'synthetic-cafe',
        'status': 'active',
        'schemaVersion': 1,
        'membershipGeneration': 7,
      };
      db.record('user_cafe_memberships/$actor').data = Map.of(link);
      db.record('cafes/synthetic-cafe/members/$actor').data = {
        ...link,
        'role': actor == 'synthetic-owner' ? 'owner' : 'staff',
      };
    }
    db.record('cafes/synthetic-cafe').data = {
      'ownerUid': 'synthetic-owner',
      'status': 'active',
      'schemaVersion': 1,
    };
    dependencies = AndroidPilotAuthDependencies(
      policy: policy ?? parse(configuration()),
      firebaseAuth: auth,
      firestore: db,
      resolver: resolver,
    );
  }
  Future<void> close() async {
    await auth.changes.close();
    for (final record in db.records.values) {
      await record.changed.close();
    }
  }

  void expectReadOnly() {
    expect(db.writes, 0);
    expect(auth.creates, 0);
    expect(auth.emails, 0);
    expect(
      db.reads.every(
        (read) => read.$1.startsWith('users/') && read.$2 == Source.server,
      ),
      isTrue,
    );
  }
}

void pilotTest(String name, WidgetTesterCallback body) =>
    testWidgets(name, body, timeout: const Timeout(Duration(seconds: 40)));

Future<void> frames(WidgetTester tester) async {
  // SDK-shaped stream cancellation can complete on the real event loop.
  // Drain bounded event turns and advance route animations, never a read's
  // 15-second deadline. Pending reads remain controlled by their Completers.
  for (var turn = 0; turn < 6; turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _gate(_Fixture f, {GlobalKey<NavigatorState>? navigatorKey}) =>
    AndroidPilotAuthScope(
      dependencies: f.dependencies,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: WorkspaceGate(
          homeBuilder: (_, session) => Scaffold(
            body: Text(
              'Protected ${session.uid} ${session.membershipGeneration}',
            ),
          ),
          setupBuilder: (_) => const Scaffold(body: Text('Forbidden setup')),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture f;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    f = _Fixture();
  });
  tearDown(() async {
    await f.close();
  });

  for (final invalid in [false, true]) {
    for (final injectUnrestricted in [false, true]) {
      pilotTest(
        'direct password reset invalid=$invalid injected=$injectUnrestricted dispatches zero emails',
        (tester) async {
          final dependencies = invalid
              ? _Fixture(policy: parse({AndroidPilotPolicy.modeKey: 'false'}))
              : f;
          if (invalid) addTearDown(dependencies.close);
          await tester.pumpWidget(
            AndroidPilotAuthScope(
              dependencies: dependencies.dependencies,
              child: MaterialApp(
                home: ForgotPasswordPage(
                  initialEmail: 'synthetic@example.test',
                  authService: injectUnrestricted
                      ? AuthService(auth: f.auth)
                      : null,
                ),
              ),
            ),
          );
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          expect(
            find.textContaining('Password reset is unavailable'),
            findsOneWidget,
          );
          // Invoke the actual field handler despite the disabled field/button.
          final submit = tester
              .widget<TextField>(find.byType(TextField))
              .onSubmitted!;
          submit('synthetic@example.test');
          submit('synthetic@example.test');
          await tester.pump();
          expect(f.auth.emails, 0);
          expect(dependencies.auth.emails, 0);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    pilotTest(
      'captured normal reset callback rejects later invalid=$invalid scope',
      (tester) async {
        AndroidPilotAuthDependencies? scope;
        late StateSetter update;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              final child = MaterialApp(
                home: ForgotPasswordPage(
                  authService: AuthService(auth: f.auth),
                  initialEmail: 'synthetic@example.test',
                ),
              );
              // Keep the same scope/Navigator shape while replacing dependencies.
              return AndroidPilotAuthScope(
                dependencies:
                    scope ??
                    AndroidPilotAuthDependencies(
                      policy: parse({}),
                      firebaseAuth: f.auth,
                    ),
                child: child,
              );
            },
          ),
        );
        final callback = tester
            .widget<FilledButton>(find.byType(FilledButton))
            .onPressed!;
        final replacement = invalid
            ? _Fixture(policy: parse({AndroidPilotPolicy.modeKey: 'false'}))
            : f;
        if (invalid) addTearDown(replacement.close);
        update(() => scope = replacement.dependencies);
        await tester.pump();
        callback();
        callback();
        await tester.pump();
        expect(f.auth.emails, 0);
        expect(replacement.auth.emails, 0);
        expect(
          find.textContaining('Password reset is unavailable'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  pilotTest('normal direct reset dispatches once during reentry and cooldown', (
    tester,
  ) async {
    f.auth.resetPending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: ForgotPasswordPage(
          initialEmail: 'synthetic@example.test',
          authService: AuthService(auth: f.auth),
        ),
      ),
    );
    final callback = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    callback();
    callback();
    expect(f.auth.emails, 1);
    f.auth.resetPending!.complete();
    await tester.pump();
    expect(find.text(ForgotPasswordPage.confirmationMessage), findsOneWidget);
    callback();
    expect(f.auth.emails, 1);
    await tester.pumpWidget(const SizedBox());
    callback();
    expect(f.auth.emails, 1);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['restricted', 'invalid', 'session', 'dispose']) {
    pilotTest('pending reset ignores stale completion after $change', (
      tester,
    ) async {
      final normal = AndroidPilotAuthDependencies(
        policy: parse({}),
        firebaseAuth: f.auth,
      );
      var scope = normal;
      late StateSetter update;
      f.auth.resetPending = Completer<void>();
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AndroidPilotAuthScope(
              dependencies: scope,
              child: const MaterialApp(
                home: ForgotPasswordPage(
                  initialEmail: 'synthetic@example.test',
                ),
              ),
            );
          },
        ),
      );
      final callback = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      callback();
      callback();
      expect(f.auth.emails, 1);
      // Deliver the stream's initial identity before replacing the session.
      // The reset itself stays pending on the controlled Completer.
      await tester.pump();
      if (change == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else if (change == 'session') {
        f.auth.replace(_User()); // Same UID, different authenticated object.
      } else {
        final replacement = change == 'invalid'
            ? _Fixture(policy: parse({AndroidPilotPolicy.modeKey: 'false'}))
            : f;
        if (change == 'invalid') addTearDown(replacement.close);
        update(() => scope = replacement.dependencies);
        await tester.pump();
        callback();
        expect(f.auth.emails, 1);
      }
      f.auth.resetPending!.complete();
      await tester.pump();
      expect(find.text(ForgotPasswordPage.confirmationMessage), findsNothing);
      expect(f.auth.emails, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final bad in [
    {AndroidPilotPolicy.modeKey: 'false'},
    {AndroidPilotPolicy.modeKey: 'true'},
    {...configuration(), AndroidPilotPolicy.bindingsKey: 'not-json'},
    {...configuration(), 'USE_FIREBASE_EMULATORS': 'false'},
    {...configuration(), AndroidPilotPolicy.projectKey: 'synthetic-other'},
  ]) {
    test(
      'invalid startup fixture ${bad.hashCode} cannot invoke initializer',
      () async {
        var calls = 0;
        await expectLater(
          app.initializeVeloraFirebase(
            policy: parse(bad),
            configuration: const FirebaseStartupConfig(
              cloudProject: AndroidPilotPolicy.approvedProject,
            ),
            isWeb: false,
            platform: TargetPlatform.android,
            initialize: (_) async {
              calls++;
            },
          ),
          throwsA(isA<FirebaseConfigurationException>()),
        );
        expect(calls, 0);
      },
    );
  }
  for (final (isWeb, platform, project, flavor) in [
    (true, TargetPlatform.android, AndroidPilotPolicy.approvedProject, null),
    (false, TargetPlatform.iOS, AndroidPilotPolicy.approvedProject, null),
    (false, TargetPlatform.android, 'velora-spark-test', null),
    (
      false,
      TargetPlatform.android,
      AndroidPilotPolicy.approvedProject,
      'staging',
    ),
  ]) {
    test(
      'runtime project/platform binding must match the validated policy $isWeb/$platform/$project/$flavor',
      () async {
        var calls = 0;
        await expectLater(
          app.initializeVeloraFirebase(
            policy: parse(configuration()),
            configuration: FirebaseStartupConfig(cloudProject: project),
            isWeb: isWeb,
            platform: platform,
            androidFlavor: flavor,
            initialize: (_) async {
              calls++;
            },
          ),
          throwsA(isA<FirebaseConfigurationException>()),
        );
        expect(calls, 0);
      },
    );
  }
  for (final values in [<String, String>{}, configuration()]) {
    test(
      'admitted startup invokes only its synthetic initializer ${values.isEmpty}',
      () async {
        final projects = <String>[];
        await app.initializeVeloraFirebase(
          policy: parse(values),
          configuration: const FirebaseStartupConfig(
            cloudProject: AndroidPilotPolicy.approvedProject,
          ),
          isWeb: false,
          platform: TargetPlatform.android,
          initialize: (options) async {
            projects.add(options.projectId);
          },
        );
        expect(projects, [AndroidPilotPolicy.approvedProject]);
      },
    );
  }

  pilotTest('normal app keeps Splash and existing named routes', (
    tester,
  ) async {
    await tester.pumpWidget(const app.VeloraApp());
    expect(tester.widget<SplashPage>(find.byType(SplashPage)).pilot, isNull);
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      material.routes!.keys,
      containsAll([
        '/login',
        '/home',
        '/business-setup',
        '/add-item',
        '/suggestions',
        '/alerts',
      ]),
    );
    expect(material.onGenerateInitialRoutes, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(
      const Duration(seconds: 3),
    ); // Drain the existing splash timer after unmount.
  });
  pilotTest('invalid root policy blocks even the authentication entry', (
    tester,
  ) async {
    final invalid = _Fixture(
      policy: parse({AndroidPilotPolicy.modeKey: 'false'}),
    );
    await tester.pumpWidget(app.VeloraApp(pilot: invalid.dependencies));
    expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
    expect(find.byType(SplashPage), findsNothing);
    expect(invalid.db.reads, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await invalid.close();
  });
  pilotTest(
    'Splash to Welcome to Login retains the identical policy and blocks links',
    (tester) async {
      f.auth.user = null;
      await tester.pumpWidget(app.VeloraApp(pilot: f.dependencies));
      expect(
        tester.widget<SplashPage>(find.byType(SplashPage)).pilot,
        same(f.dependencies),
      );
      await tester.pump(const Duration(seconds: 3));
      await frames(tester);
      expect(
        tester.widget<WelcomePage>(find.byType(WelcomePage)).pilot,
        same(f.dependencies),
      );
      await tester.ensureVisible(find.text('Get Started'));
      await tester.tap(find.text('Get Started'));
      await frames(tester);
      expect(
        tester.widget<LoginPage>(find.byType(LoginPage)).pilot,
        same(f.dependencies),
      );
      for (final label in ['Sign up', 'Forgot Password?']) {
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byType(TextButton),
        );
        expect(tester.widget<TextButton>(button).onPressed, isNull);
      }
      expect(find.byType(SignUpPage), findsNothing);
      expect(find.byType(ForgotPasswordPage), findsNothing);
      f.expectReadOnly();
      await tester.pumpWidget(const SizedBox());
    },
  );
  pilotTest(
    'direct SignUp under scope is blocked without constructing normal auth',
    (tester) async {
      await tester.pumpWidget(
        AndroidPilotAuthScope(
          dependencies: f.dependencies,
          child: const MaterialApp(home: SignUpPage()),
        ),
      );
      expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
      expect(find.text('Create Account'), findsNothing);
      expect(f.db.reads, isEmpty);
      f.expectReadOnly();
      await tester.pumpWidget(const SizedBox());
    },
  );

  pilotTest('restored Splash enters the configured canonical boundary', (
    tester,
  ) async {
    f.db.cacheAuthority = true; // Hold real Home behind server authority.
    await tester.pumpWidget(app.VeloraApp(pilot: f.dependencies));
    await tester.pump(const Duration(seconds: 3));
    await frames(tester);
    expect(find.byType(SplashPage), findsNothing);
    final boundary = tester.widget<WorkspaceSessionBoundary>(
      find.byType(WorkspaceSessionBoundary),
    );
    expect(boundary.pilot, same(f.dependencies));
    expect(boundary.session.uid, 'synthetic-owner');
    expect(f.store.transactions, 1);
    expect(
      f.db.reads.length,
      greaterThanOrEqualTo(2),
    ); // Restore + gate eligibility.
    f.expectReadOnly();
    await tester.pumpWidget(const SizedBox());
  });

  for (final page in <Widget>[
    const LoginPage(),
    const SignUpPage(),
    const WelcomePage(),
    const WorkspaceGate(),
  ]) {
    pilotTest(
      'invalid scoped policy cannot fall back through ${page.runtimeType}',
      (tester) async {
        final invalid = _Fixture(
          policy: parse({AndroidPilotPolicy.modeKey: 'false'}),
        );
        await tester.pumpWidget(
          AndroidPilotAuthScope(
            dependencies: invalid.dependencies,
            child: MaterialApp(home: page),
          ),
        );
        await frames(tester);
        expect(invalid.db.reads, isEmpty);
        expect(invalid.store.transactions, 0);
        expect(invalid.auth.signIns, 0);
        expect(find.textContaining('Protected '), findsNothing);
        expect(find.text('Create Account'), findsNothing);
        invalid.expectReadOnly();
        await tester.pumpWidget(const SizedBox());
        await invalid.close();
      },
    );
  }

  for (final name in [
    '/business-setup',
    '/add-item',
    '/suggestions',
    '/alerts',
    '/signup',
    '/reset',
    '/unknown',
  ]) {
    pilotTest(
      'restricted named route $name is denied before feature construction',
      (tester) async {
        await tester.pumpWidget(app.VeloraApp(pilot: f.dependencies));
        final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
        final initial = material.onGenerateInitialRoutes!(name);
        expect(initial, hasLength(1));
        expect(
          (initial.single as MaterialPageRoute).builder(
            tester.element(find.byType(SplashPage)),
          ),
          isA<PilotAccessBlockedPage>(),
        );
        Navigator.of(tester.element(find.byType(SplashPage))).pushNamed(name);
        await frames(tester);
        expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
        f.expectReadOnly();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      },
    );
  }

  for (final staff in [false, true]) {
    pilotTest(
      'restored ${staff ? 'Staff' : 'Owner'} requires canonical membership and server profile',
      (tester) async {
        final active = _Fixture(staff: staff);
        await tester.pumpWidget(_gate(active));
        await frames(tester);
        expect(
          find.text('Protected ${active.auth.user!.uid} 7'),
          findsOneWidget,
          reason:
              'reads=${active.db.reads}; transactions=${active.store.transactions}; '
              'listeners=${active.auth.listeners}; visible=${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}',
        );
        expect(find.text('Forbidden setup'), findsNothing);
        expect(
          active.store.transactions,
          greaterThanOrEqualTo(2),
        ); // Gate + actual boundary.
        expect(
          active.store.paths,
          contains('user_cafe_memberships/${active.auth.user!.uid}'),
        );
        active.expectReadOnly();
        await tester.pumpWidget(const SizedBox());
        expect(active.auth.listeners, 0);
        await active.close();
      },
    );
  }
  for (final failure in [
    'missing-profile',
    'unavailable-profile',
    'invalid-profile',
    'unverified',
    'unapproved',
    'missing-membership',
    'canonical-uid-mismatch',
    'generation',
    'wrong-cafe',
    'signed-out',
  ]) {
    pilotTest(
      'gate rejects $failure without setup, repair or protected content',
      (tester) async {
        switch (failure) {
          case 'missing-profile':
            f.db.record('users/synthetic-owner').data = null;
          case 'unavailable-profile':
            f.db.record('users/synthetic-owner').error = StateError(
              'synthetic-offline',
            );
          case 'invalid-profile':
            f.db.record('users/synthetic-owner').data!.remove('username');
          case 'unverified':
            f.auth.user = _User(emailVerified: false);
          case 'unapproved':
            f.auth.user = _User(uid: 'synthetic-other');
          case 'missing-membership':
            f.db.record('user_cafe_memberships/synthetic-owner').data = null;
          case 'canonical-uid-mismatch':
            f.db.record('user_cafe_memberships/synthetic-owner').data!['uid'] =
                'synthetic-other';
          case 'generation':
            f.db
                    .record('cafes/synthetic-cafe/members/synthetic-owner')
                    .data!['membershipGeneration'] =
                8;
          case 'wrong-cafe':
            // Keep canonical records valid, but bind the policy to a different café.
            final changed = configuration()
              ..[AndroidPilotPolicy.bindingsKey] = jsonEncode([
                ['synthetic-owner', 'synthetic-other-cafe'],
              ]);
            await f.close();
            f = _Fixture(policy: parse(changed));
          case 'signed-out':
            f.auth.user = null;
        }
        await tester.pumpWidget(_gate(f));
        await frames(tester);
        expect(find.textContaining('Protected '), findsNothing);
        expect(find.text('Forbidden setup'), findsNothing);
        expect(find.byKey(const ValueKey('workspace-retry')), findsOneWidget);
        f.expectReadOnly();
        if ([
          'missing-profile',
          'unavailable-profile',
          'invalid-profile',
          'unapproved',
          'unverified',
          'signed-out',
        ].contains(failure)) {
          expect(f.store.transactions, 0);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final replacement in ['same-uid', 'other-uid', 'logout']) {
    pilotTest('$replacement during canonical read cannot publish late Home', (
      tester,
    ) async {
      f.store.pending = Completer<void>();
      await tester.pumpWidget(_gate(f));
      await frames(tester);
      expect(f.store.transactions, 1);
      f.auth.replace(
        replacement == 'logout'
            ? null
            : _User(
                uid: replacement == 'same-uid'
                    ? 'synthetic-owner'
                    : 'synthetic-staff',
              ),
      );
      f.store.pending!.complete();
      await frames(tester);
      expect(find.textContaining('Protected '), findsNothing);
      expect(find.byKey(const ValueKey('workspace-retry')), findsOneWidget);
      f.expectReadOnly();
      await tester.pumpWidget(const SizedBox());
    });
  }
  pilotTest(
    'replacement during profile read is rejected before canonical dispatch',
    (tester) async {
      final profile = f.db.record('users/synthetic-owner')
        ..pending = Completer<void>();
      await tester.pumpWidget(_gate(f));
      await tester.pump();
      expect(f.db.reads, isNotEmpty);
      f.auth.replace(_User());
      profile.pending!.complete();
      await frames(tester);
      expect(find.textContaining('Protected '), findsNothing);
      expect(f.store.transactions, 0);
      f.expectReadOnly();
      await tester.pumpWidget(const SizedBox());
    },
  );
  pilotTest('unmounted gate cannot navigate on late results', (tester) async {
    f.store.pending = Completer<void>();
    await tester.pumpWidget(_gate(f));
    await frames(tester);
    await tester.pumpWidget(const MaterialApp(home: Text('Replacement root')));
    f.store.pending!.complete();
    await frames(tester);
    expect(find.text('Replacement root'), findsOneWidget);
    expect(find.textContaining('Protected '), findsNothing);
    f.expectReadOnly();
    await tester.pumpWidget(const SizedBox());
  });
  pilotTest('blocked gate logout clears the stack and keeps configured Login', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      AndroidPilotAuthScope(
        dependencies: f.dependencies,
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Text('Old root'),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const WorkspaceGate(initiallyBlocked: true),
      ),
    );
    await frames(tester);
    await tester.tap(find.byKey(const ValueKey('pilot-logout')));
    await frames(tester);
    expect(f.auth.user, isNull);
    expect(navigator.currentState!.canPop(), isFalse);
    expect(
      tester.widget<LoginPage>(find.byType(LoginPage)).pilot,
      same(f.dependencies),
    );
    expect(find.text('Old root'), findsNothing);
    f.expectReadOnly();
    await tester.pumpWidget(const SizedBox());
  });

  for (final invalidation in ['logout', 'same-uid', 'membership']) {
    pilotTest('boundary $invalidation removes detail stack and retains policy', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_gate(f, navigatorKey: navigator));
      await frames(tester);
      expect(find.textContaining('Protected '), findsOneWidget);
      final boundary = tester.widget<WorkspaceSessionBoundary>(
        find.byType(WorkspaceSessionBoundary),
      );
      final boundaryElement = tester.element(
        find.byType(WorkspaceSessionBoundary),
      );
      expect(boundary.session.isActive, isTrue);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Protected detail')),
        ),
      );
      await frames(tester);
      expect(
        boundary.session.isActive,
        isTrue,
        reason: 'Pushing a detail must not dispose its protected boundary',
      );
      switch (invalidation) {
        case 'logout':
          await f.dependencies.authService.signOut();
        case 'same-uid':
          f.auth.replace(_User());
        case 'membership':
          final record = f.db.record(
            'cafes/synthetic-cafe/members/synthetic-owner',
          );
          record.data!['membershipGeneration'] = 8;
          record.changed.add(null);
      }
      await frames(tester);
      expect(boundary.session.isActive, isFalse);
      expect(
        find.textContaining('Protected '),
        findsNothing,
        reason:
            'boundary mounted=${boundaryElement.mounted}; '
            'offstage boundaries=${find.byType(WorkspaceSessionBoundary, skipOffstage: false).evaluate().length}; '
            'canPop=${navigator.currentState!.canPop()}',
      );
      expect(navigator.currentState!.canPop(), isFalse);
      if (invalidation == 'logout') {
        expect(
          tester.widget<LoginPage>(find.byType(LoginPage)).pilot,
          same(f.dependencies),
        );
      } else {
        expect(
          tester.widget<WorkspaceGate>(find.byType(WorkspaceGate)).pilot,
          same(f.dependencies),
        );
      }
      f.expectReadOnly();
      await tester.pumpWidget(const SizedBox());
    });
  }
  pilotTest(
    'default Login constructed imperatively still borrows scoped auth',
    (tester) async {
      f.db.cacheAuthority = true;
      f.auth.user = null;
      await tester.pumpWidget(
        AndroidPilotAuthScope(
          dependencies: f.dependencies,
          child: const MaterialApp(home: LoginPage()),
        ),
      );
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'synthetic@example.test');
      await tester.enterText(fields.at(1), 'synthetic-password');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await frames(tester);
      expect(f.auth.signIns, 1);
      expect(find.byType(WorkspaceSessionBoundary), findsOneWidget);
      expect(
        tester
            .widget<WorkspaceSessionBoundary>(
              find.byType(WorkspaceSessionBoundary),
            )
            .pilot,
        same(f.dependencies),
      );
      // Do not render real Home inventory dependencies in this test: the actual
      // boundary remains waiting for controlled canonical authority if needed.
      f.expectReadOnly();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
