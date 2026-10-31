import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'package:velora/services/auth_service.dart';
import 'package:velora/services/workspace_resolver.dart';

class _Resolver extends WorkspaceResolver {
  Future<CafeWorkspace> Function() result;
  int calls = 0;

  _Resolver(this.result);

  @override
  Future<CafeWorkspace> resolve() {
    calls++;
    return result();
  }
}

class _Auth extends Fake implements AuthService {
  int calls = 0;

  @override
  Future<void> signIn({required String email, required String password}) async {
    calls++;
  }
}

const owner = CafeWorkspace(
  cafeId: 'cafe-a',
  uid: 'owner-a',
  ownerUid: 'owner-a',
  role: CafeRole.owner,
);

const staff = CafeWorkspace(
  cafeId: 'cafe-a',
  uid: 'staff-a',
  ownerUid: 'owner-a',
  role: CafeRole.staff,
);

Widget _app(_Resolver resolver) => MaterialApp(
  theme: AppTheme.light,
  home: WorkspaceGate(
    resolver: resolver,
    homeBuilder: (_) => const Scaffold(body: Text('Verified Home')),
    setupBuilder: (_) => const Scaffold(body: Text('Setup Preview')),
  ),
);

void main() {
  testWidgets('successful Login enters the shared gate, not Home directly', (
    tester,
  ) async {
    final pending = Completer<CafeWorkspace>();
    final resolver = _Resolver(() => pending.future);
    final auth = _Auth();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: LoginPage(authService: auth, workspaceResolver: resolver),
      ),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'owner@example.test');
    await tester.enterText(fields.at(1), 'password');
    await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(auth.calls, 1);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(WorkspaceGate), findsOneWidget);
    expect(find.text('Verifying your workspace…'), findsOneWidget);
    expect(resolver.calls, 1);
  });

  for (final workspace in [owner, staff]) {
    testWidgets('verified ${workspace.role.name} reaches Home', (tester) async {
      final resolver = _Resolver(() async => workspace);
      await tester.pumpWidget(_app(resolver));
      await tester.pumpAndSettle();

      expect(find.text('Verified Home'), findsOneWidget);
      expect(find.text('Setup Preview'), findsNothing);
      expect(resolver.calls, 1);
    });
  }

  testWidgets('only missing membership reaches Business Setup preview', (
    tester,
  ) async {
    final resolver = _Resolver(
      () async => throw const WorkspaceResolutionException(
        WorkspaceFailure.missingMembership,
      ),
    );
    await tester.pumpWidget(_app(resolver));
    await tester.pumpAndSettle();

    expect(find.text('Setup Preview'), findsOneWidget);
    expect(find.text('Verified Home'), findsNothing);
  });

  testWidgets('inconsistent membership fails closed', (tester) async {
    final resolver = _Resolver(
      () async => throw const WorkspaceResolutionException(
        WorkspaceFailure.inconsistentMembership,
      ),
    );
    await tester.pumpWidget(_app(resolver));
    await tester.pumpAndSettle();

    expect(find.text('Workspace access not verified'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-retry')), findsOneWidget);
    expect(find.text('Verified Home'), findsNothing);
    expect(find.text('Setup Preview'), findsNothing);
  });

  for (final failure in [
    WorkspaceFailure.unavailable,
    WorkspaceFailure.sessionChanged,
    WorkspaceFailure.unauthenticated,
  ]) {
    testWidgets('${failure.name} fails closed instead of showing Setup', (
      tester,
    ) async {
      final resolver = _Resolver(
        () async => throw WorkspaceResolutionException(failure),
      );
      await tester.pumpWidget(_app(resolver));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('workspace-retry')), findsOneWidget);
      expect(find.text('Verified Home'), findsNothing);
      expect(find.text('Setup Preview'), findsNothing);
    });
  }

  testWidgets('unknown resolver errors fail closed and retry can recover', (
    tester,
  ) async {
    final first = Completer<CafeWorkspace>();
    final resolver = _Resolver(() => first.future);
    await tester.pumpWidget(_app(resolver));
    expect(find.text('Verifying your workspace…'), findsOneWidget);

    first.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Workspace unavailable'), findsOneWidget);

    resolver.result = () async => owner;
    await tester.tap(find.byKey(const ValueKey('workspace-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Verified Home'), findsOneWidget);
    expect(resolver.calls, 2);
  });
}
