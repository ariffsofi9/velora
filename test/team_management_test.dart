// Firebase interfaces are replaced with offline doubles in these UI tests.
// ignore_for_file: subtype_of_sealed_class

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/team/team_management_page.dart';
import 'package:velora/services/workspace_resolver.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'owner-a';
  @override
  String? get displayName => 'Sarah Parker';
  @override
  String? get email => 'sarah@example.test';
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _User();
}

class _Resolver extends WorkspaceResolver {
  final CafeWorkspace? workspace;
  final WorkspaceFailure? failure;

  _Resolver.success(this.workspace) : failure = null;
  _Resolver.failure(this.failure) : workspace = null;

  @override
  Future<CafeWorkspace> resolve() async {
    if (failure != null) throw WorkspaceResolutionException(failure!);
    return workspace!;
  }
}

void main() {
  const ownerWorkspace = CafeWorkspace(
    cafeId: 'cafe-a',
    uid: 'owner-a',
    ownerUid: 'owner-a',
    role: CafeRole.owner,
  );

  Widget app(Widget child, {double scale = 1}) => MaterialApp(
    theme: AppTheme.light,
    builder: (context, screen) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: screen!,
    ),
    home: child,
  );

  testWidgets('Verified membership shows only the authenticated member', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: _Auth(),
          resolver: _Resolver.success(ownerWorkspace),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sarah Parker'), findsOneWidget);
    expect(find.text('sarah@example.test'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Staff'), findsNothing);

    final invite = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Invite Staff'),
    );
    final manage = tester.widget<IconButton>(
      find.byKey(const ValueKey('member-management-button')),
    );
    expect(invite.onPressed, isNull);
    expect(manage.onPressed, isNull);
  });

  testWidgets('Missing trusted membership shows an honest empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: _Auth(),
          resolver: _Resolver.failure(WorkspaceFailure.missingMembership),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No trusted team workspace'), findsOneWidget);
    expect(find.text('Sarah Parker'), findsNothing);
    final invite = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Invite Staff'),
    );
    expect(invite.onPressed, isNull);
  });

  for (final width in [320.0, 393.0, 768.0]) {
    testWidgets('Team Management fits $width at 2x text', (tester) async {
      tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        app(
          TeamManagementPage(
            auth: _Auth(),
            resolver: _Resolver.success(ownerWorkspace),
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
