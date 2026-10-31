import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/splash_page.dart';
import 'package:velora/screens/auth/welcome_page.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'package:velora/services/auth_service.dart';

class _Session extends Fake implements AuthService {
  final Future<bool> result;
  _Session(this.result);
  @override
  Future<bool> canRestoreSession() => result;
}

class _Observer extends NavigatorObserver {
  Route<dynamic>? top;
  @override
  void didChangeTop(
    Route<dynamic> topRoute,
    Route<dynamic>? previousTopRoute,
  ) => top = topRoute;
}

Widget _app(Widget child, {NavigatorObserver? observer, double scale = 1}) =>
    MaterialApp(
      theme: AppTheme.light,
      navigatorObservers: [?observer],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(393, 852),
    const Size(768, 1024),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Welcome fits $size at text scale $scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_app(const WelcomePage(), scale: scale));
        await tester.pumpAndSettle();
        expect(find.text('Velora'), findsOneWidget);
        expect(find.text('Your Caf\u00e9 Inventory Partner'), findsOneWidget);
        final button = find.widgetWithText(FilledButton, 'Get Started');
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(button).width, lessThanOrEqualTo(440));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Get Started opens Login and replaces Welcome', (tester) async {
    await tester.pumpWidget(_app(const WelcomePage()));
    await tester.ensureVisible(find.text('Get Started'));
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);
    expect(
      Navigator.of(tester.element(find.byType(LoginPage))).canPop(),
      isFalse,
    );
  });

  testWidgets('Restorable session opens the workspace gate after the delay', (
    tester,
  ) async {
    final session = Completer<bool>();
    final observer = _Observer();
    await tester.pumpWidget(
      _app(
        SplashPage(authService: _Session(session.future)),
        observer: observer,
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(SplashPage), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    session.complete(true);
    // Flush routing without resolving a real Firebase workspace.
    await tester.idle();
    final route = observer.top! as MaterialPageRoute<dynamic>;
    expect(
      route.builder(tester.element(find.byType(SplashPage))),
      isA<WorkspaceGate>(),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Session check failure falls back to Welcome without granting access',
    (tester) async {
      final session = Completer<bool>();
      await tester.pumpWidget(
        _app(SplashPage(authService: _Session(session.future))),
      );
      await tester.pump(const Duration(seconds: 3));
      session.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.byType(WelcomePage), findsOneWidget);
      expect(find.byType(WorkspaceGate), findsNothing);
    },
  );
}
