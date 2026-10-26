import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/auth/forgot_password_page.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/services/auth_service.dart';

class _Auth extends Fake implements FirebaseAuth {
  final addresses = <String>[];
  Future<void> Function()? request;
  int signIns = 0;
  int signOuts = 0;
  @override
  User? get currentUser => null;
  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    ActionCodeSettings? actionCodeSettings,
  }) async {
    expect(
      actionCodeSettings,
      isNull,
    ); // Preserve the Firebase-hosted reset flow.
    addresses.add(email);
    await request?.call();
  }

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    signIns++;
    throw StateError('Password reset must not authenticate');
  }

  @override
  Future<void> signOut() async {
    signOuts++;
  }
}

void main() {
  late _Auth auth;
  late AuthService service;
  setUp(() {
    auth = _Auth();
    service = AuthService(auth: auth);
  });

  Future<void> open(
    WidgetTester tester, {
    String email = 'owner@example.test',
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ForgotPasswordPage(initialEmail: email, authService: service),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
  }

  for (final invalid in [
    '',
    'not-an-email',
    'user@domain',
    'a@@example.test',
    'a b@example.test',
  ]) {
    test(
      'Invalid email is rejected before calling Firebase: ${invalid.length} characters',
      () async {
        await expectLater(
          service.sendPasswordResetEmail(email: invalid),
          throwsA(
            isA<FirebaseAuthException>().having(
              (e) => e.code,
              'code',
              'invalid-email',
            ),
          ),
        );
        expect(auth.addresses, isEmpty);
      },
    );
  }

  test(
    'Valid email is trimmed and only the Firebase reset method is called',
    () async {
      await service.sendPasswordResetEmail(email: '  owner@example.test  ');
      expect(auth.addresses, ['owner@example.test']);
      expect(auth.signIns, 0);
      expect(auth.signOuts, 0);
      expect(auth.currentUser, isNull);
    },
  );

  for (final code in ['user-not-found', 'user-disabled']) {
    test('Account-specific $code is neutralized', () async {
      auth.request = () async => throw FirebaseAuthException(code: code);
      await service.sendPasswordResetEmail(email: 'owner@example.test');
      expect(auth.signIns, 0);
    });
  }

  testWidgets(
    'Blank/invalid input displays validation without a reset request',
    (tester) async {
      await open(tester, email: '');
      await send(tester);
      expect(find.text('Please enter a valid email address.'), findsOneWidget);
      expect(auth.addresses, isEmpty);
      await tester.enterText(find.byType(TextFormField), 'bad-address');
      await send(tester);
      expect(auth.addresses, isEmpty);
    },
  );

  testWidgets(
    'Success gives neutral confirmation, tip and a 60-second cooldown',
    (tester) async {
      await open(tester, email: '  owner@example.test  ');
      await send(tester);
      expect(auth.addresses, ['owner@example.test']);
      expect(find.text(ForgotPasswordPage.confirmationMessage), findsOneWidget);
      expect(find.text('Check your inbox and spam folder.'), findsOneWidget);
      expect(find.text('Send again in 60s'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 59));
      expect(find.text('Send again in 1s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Send Reset Link'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(auth.signIns, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final code in ['user-not-found', 'user-disabled']) {
    testWidgets(
      '$code displays the same confirmation and cooldown as success',
      (tester) async {
        auth.request = () async => throw FirebaseAuthException(code: code);
        await open(tester);
        await send(tester);
        expect(
          find.text(ForgotPasswordPage.confirmationMessage),
          findsOneWidget,
        );
        expect(find.text('Send again in 60s'), findsOneWidget);
        expect(find.textContaining(code), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Loading disables input and prevents duplicate keyboard submissions',
    (tester) async {
      final pending = Completer<void>();
      auth.request = () => pending.future;
      await open(tester);
      await send(tester);
      expect(find.text('Sending Reset Link'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        isFalse,
      );
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TextFormField),
          matching: find.byType(TextField),
        ),
      );
      field.onSubmitted?.call('owner@example.test');
      await tester.pump();
      expect(auth.addresses, hasLength(1));
      pending.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final code in [
    'network-request-failed',
    'too-many-requests',
    'internal-error',
  ]) {
    testWidgets('$code gives safe feedback and re-enables retry', (
      tester,
    ) async {
      auth.request = () async => throw FirebaseAuthException(
        code: code,
        message: 'private upstream details',
      );
      await open(tester);
      await send(tester);
      expect(
        find.textContaining(
          code == 'network-request-failed'
              ? 'internet connection'
              : code == 'too-many-requests'
              ? 'Too many requests'
              : 'Unable to request',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private upstream details'), findsNothing);
      expect(find.text(ForgotPasswordPage.confirmationMessage), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });
  }

  testWidgets(
    'Login prefills reset email and Back to Login returns to the existing form',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: LoginPage(authService: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        '  owner@example.test  ',
      );
      await tester.ensureVisible(find.text('Forgot Password?'));
      await tester.tap(find.text('Forgot Password?'));
      await tester.pumpAndSettle();
      expect(find.byType(ForgotPasswordPage), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller
            ?.text,
        'owner@example.test',
      );
      await tester.ensureVisible(find.text('Back to Login'));
      await tester.tap(find.text('Back to Login'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(ForgotPasswordPage), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        '  owner@example.test  ',
      );
      expect(auth.signIns, 0);
    },
  );

  testWidgets('Direct reset-page entry can return to Login', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('Back to Login'));
    await tester.tap(find.text('Back to Login'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets(
    'Request completion after disposal does not update a dead screen',
    (tester) async {
      final pending = Completer<void>();
      auth.request = () => pending.future;
      await open(tester);
      await send(tester);
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(393, 852),
    const Size(768, 1024),
    const Size(1280, 800),
  ]) {
    testWidgets('Reset layout is scroll-safe at $size with enlarged text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, scale: 2);
      await tester.ensureVisible(find.text('Back to Login'));
      expect(tester.takeException(), isNull);
    });
  }
}
