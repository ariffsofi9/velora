import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/signup_page.dart';
import 'package:velora/screens/auth/splash_page.dart';
import 'package:velora/services/auth_service.dart';
import 'package:velora/services/user_profile_service.dart';

class _User extends Fake implements User {
  final List<String> events;
  String? name;
  _User(this.events);
  @override
  String get uid => 'registered-user';
  @override
  String get email => 'owner@example.test';
  @override
  String? get displayName => name;
  @override
  bool get emailVerified => false;
  @override
  Future<void> updateDisplayName(String? value) async {
    name = value;
    events.add('name');
  }

  @override
  Future<void> sendEmailVerification([ActionCodeSettings? settings]) async =>
      fail('Registration must not send a verification email');
}

class _Credential extends Fake implements UserCredential {
  final User? value;
  _Credential(this.value);
  @override
  User? get user => value;
}

class _Auth extends Fake implements FirebaseAuth {
  final List<String> events;
  User? user;
  bool failCreate = false;
  bool nullCredential = false;
  bool failSignOut = false;
  int creates = 0;
  Future<void> Function()? onSignOut;
  _Auth(this.events);
  @override
  User? get currentUser => user;
  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    creates++;
    events.add('create');
    if (failCreate) throw FirebaseAuthException(code: 'email-already-in-use');
    if (nullCredential) return _Credential(null);
    user = _User(events);
    return _Credential(user);
  }

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    events.add('login');
    user = _User(events);
    return _Credential(user);
  }

  @override
  Future<void> signOut() async {
    events.add('signOut');
    await onSignOut?.call();
    if (failSignOut) {
      throw FirebaseAuthException(code: 'network-request-failed');
    }
    user = null;
  }
}

class _Profiles extends Fake implements UserProfileService {
  final List<String> events;
  Future<void> Function()? save;
  _Profiles(this.events);
  @override
  Future<void> createUserProfileIfNeeded(User user) async {
    events.add('profile');
    await save?.call();
    events.add('profileSaved');
  }
}

void main() {
  late List<String> events;
  late _Auth auth;
  late _Profiles profiles;
  late AuthService service;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    events = [];
    auth = _Auth(events);
    profiles = _Profiles(events);
    service = AuthService(auth: auth, profiles: profiles);
  });
  Future<void> register() => service.register(
    name: 'Cafe Owner',
    email: 'owner@example.test',
    password: 'test-password',
  );

  test('Registration waits for profile creation before signing out', () async {
    final save = Completer<void>();
    profiles.save = () => save.future;
    final registration = register();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['create', 'name', 'profile']);
    expect(auth.currentUser?.displayName, 'Cafe Owner');
    save.complete();
    await registration;
    expect(events, ['create', 'name', 'profile', 'profileSaved', 'signOut']);
    expect(auth.currentUser, isNull);
    expect(await service.canRestoreSession(), isFalse);
  });

  test(
    'Unverified manual login clears registration guard and restores persistence',
    () async {
      await register();
      await service.signIn(
        email: 'owner@example.test',
        password: 'test-password',
      );
      expect(auth.currentUser?.emailVerified, isFalse);
      expect(await service.canRestoreSession(), isTrue);
      expect(events.where((e) => e == 'login'), hasLength(1));
    },
  );

  test(
    'Profile failure signs out and reports incomplete setup, not success',
    () async {
      profiles.save = () async => throw StateError('simulated storage failure');
      await expectLater(
        register(),
        throwsA(
          isA<AuthFlowException>().having(
            (e) => e.message,
            'message',
            contains('profile setup did not finish'),
          ),
        ),
      );
      expect(auth.currentUser, isNull);
      expect(auth.creates, 1);
      expect(await service.canRestoreSession(), isFalse);
      profiles.save = null;
      await service.signIn(
        email: 'owner@example.test',
        password: 'test-password',
      );
      expect(await service.canRestoreSession(), isTrue);
    },
  );

  test('Failed sign-out cannot auto-restore the newly created session', () async {
    auth.failSignOut = true;
    await expectLater(
      register(),
      throwsA(
        isA<AuthFlowException>().having(
          (e) => e.message,
          'message',
          contains('sign-out could not be completed'),
        ),
      ),
    );
    expect(auth.currentUser, isNotNull);
    // A fresh service instance sees the persistent guard even after app restart.
    final restarted = AuthService(auth: auth, profiles: profiles);
    expect(await restarted.canRestoreSession(), isFalse);
    auth.failSignOut = false;
    await restarted.signIn(
      email: 'owner@example.test',
      password: 'test-password',
    );
    expect(await restarted.canRestoreSession(), isTrue);
  });

  test(
    'Account creation errors preserve Firebase error codes and never save a profile',
    () async {
      auth.failCreate = true;
      await expectLater(
        register(),
        throwsA(
          isA<FirebaseAuthException>().having(
            (e) => e.code,
            'code',
            'email-already-in-use',
          ),
        ),
      );
      expect(events, isNot(contains('profile')));
      expect(await service.canRestoreSession(), isFalse);
    },
  );

  test(
    'Interrupted registration profile recovery must succeed before login returns',
    () async {
      await register();
      profiles.save = () async => throw StateError('simulated storage failure');
      await expectLater(
        service.signIn(email: 'owner@example.test', password: 'test-password'),
        throwsA(isA<AuthFlowException>()),
      );
      expect(auth.currentUser, isNull);
      expect(await service.canRestoreSession(), isFalse);
    },
  );

  test('Null account response never claims successful registration', () async {
    auth.nullCredential = true;
    await expectLater(
      register(),
      throwsA(
        isA<AuthFlowException>().having(
          (e) => e.message,
          'message',
          contains('could not be confirmed'),
        ),
      ),
    );
    expect(events, isNot(contains('profile')));
    expect(await service.canRestoreSession(), isFalse);
  });

  test(
    'Existing persisted sessions do not require email verification',
    () async {
      auth.user = _User(events);
      expect(await service.canRestoreSession(), isTrue);
      expect(events, isEmpty);
    },
  );

  Future<void> openSignup(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: SignUpPage(authService: service),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Cafe Owner');
    await tester.enterText(fields.at(1), 'owner@example.test');
    await tester.enterText(fields.at(2), 'test-password');
    await tester.enterText(fields.at(3), 'test-password');
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
  }

  testWidgets(
    'Registration navigates to Login only after profile and sign-out, clears stack and shows success',
    (tester) async {
      final save = Completer<void>();
      final signOut = Completer<void>();
      profiles.save = () => save.future;
      auth.onSignOut = () => signOut.future;
      await openSignup(tester);
      expect(find.byType(LoginPage), findsNothing);
      expect(events, isNot(contains('signOut')));
      save.complete();
      await tester.pump();
      expect(events, contains('signOut'));
      expect(find.byType(LoginPage), findsNothing);
      signOut.complete();
      await tester.pumpAndSettle();
      expect(auth.currentUser, isNull);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(SignUpPage), findsNothing);
      expect(
        find.text('Account created successfully! Please log in.'),
        findsOneWidget,
      );
      expect(
        Navigator.of(tester.element(find.byType(LoginPage))).canPop(),
        isFalse,
      );
    },
  );

  testWidgets(
    'Profile error stays on registration without success navigation',
    (tester) async {
      profiles.save = () async => throw StateError('simulated failure');
      await openSignup(tester);
      await tester.pumpAndSettle();
      expect(find.byType(SignUpPage), findsOneWidget);
      expect(find.byType(LoginPage), findsNothing);
      expect(
        find.textContaining('profile setup did not finish'),
        findsOneWidget,
      );
      expect(
        find.text('Account created successfully! Please log in.'),
        findsNothing,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'Splash never restores an unfinished registration, even if sign-out fails',
    (tester) async {
      auth.failSignOut = true;
      await expectLater(register(), throwsA(isA<AuthFlowException>()));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: SplashPage(authService: service),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(SplashPage), findsNothing);
    },
  );
}
