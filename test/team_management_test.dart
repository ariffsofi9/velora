// Firebase interfaces are replaced with offline doubles in these UI tests.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/team/team_management_page.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/team_members_service.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'helpers/invitation_firebase.dart';

class _User extends Fake implements User {
  final String id;
  _User([this.id = 'owner-a']);
  @override
  String get uid => id;
  @override
  String? get displayName => 'Sarah Parker';
  @override
  String? get email => 'sarah@example.test';
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User();
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => changes.stream;
}

class _Members implements TeamMembers {
  int calls = 0;
  bool fail = false;
  bool empty = false;
  Completer<TeamRoster>? pending;
  @override
  Future<TeamRoster> load(CafeWorkspace workspace) async {
    calls++;
    if (fail) throw StateError('Unavailable');
    if (pending != null) return pending!.future;
    if (empty) return TeamRoster(workspace, const []);
    return TeamRoster(workspace, const [
      TeamMember(
        'owner-a',
        'Sarah Parker',
        'sarah@example.test',
        CafeRole.owner,
      ),
      TeamMember(
        'staff-a',
        'Staff Member',
        'staff@example.test',
        CafeRole.staff,
      ),
    ]);
  }
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
  setUp(installInvitationFirebase);
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

  testWidgets(
    'Owner sees verified owner and staff without unsupported management menu',
    (tester) async {
      await tester.pumpWidget(
        app(
          TeamManagementPage(
            auth: _Auth(),
            members: _Members(),
            resolver: _Resolver.success(ownerWorkspace),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sarah Parker'), findsOneWidget);
      expect(find.text('sarah@example.test'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Staff'), findsOneWidget);
      expect(find.text('staff@example.test'), findsOneWidget);
      expect(find.text('Verified Members (2)'), findsOneWidget);

      final invite = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Invite Staff'),
      );
      expect(
        invite.onPressed,
        FirebaseEmulatorConfig.invitationsAvailable ? isNotNull : isNull,
      );
      expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    },
  );

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

    expect(find.text('Team members unavailable'), findsOneWidget);
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
            members: _Members(),
            resolver: _Resolver.success(ownerWorkspace),
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Staff sees permitted team and cannot invite or manage', (
    tester,
  ) async {
    final auth = _Auth()..user = _User('staff-a');
    const workspace = CafeWorkspace(
      cafeId: 'cafe-a',
      uid: 'staff-a',
      ownerUid: 'owner-a',
      role: CafeRole.staff,
    );
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: auth,
          resolver: _Resolver.success(workspace),
          members: _Members(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('staff@example.test'), findsOneWidget);
    expect(find.text('sarah@example.test'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Invite Staff'),
          )
          .onPressed,
      isNull,
    );
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
  });

  testWidgets(
    'List failure has retry and never falls back to self; refresh reloads',
    (tester) async {
      final members = _Members()..fail = true;
      await tester.pumpWidget(
        app(
          TeamManagementPage(
            auth: _Auth(),
            resolver: _Resolver.success(ownerWorkspace),
            members: members,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Team members unavailable'), findsOneWidget);
      expect(find.text('sarah@example.test'), findsNothing);
      members.fail = false;
      await tester.tap(find.text('Check Again'));
      await tester.pumpAndSettle();
      expect(find.text('Verified Members (2)'), findsOneWidget);
      final calls = members.calls;
      await tester.ensureVisible(find.text('Refresh members'));
      await tester.tap(find.text('Refresh members'));
      await tester.pumpAndSettle();
      expect(members.calls, calls + 1);
    },
  );

  testWidgets('Pending list is hidden after sign-out', (tester) async {
    final auth = _Auth();
    final members = _Members()..pending = Completer<TeamRoster>();
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: auth,
          resolver: _Resolver.success(ownerWorkspace),
          members: members,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    auth.user = null;
    auth.changes.add(null);
    await tester.pumpAndSettle();
    members.pending!.complete(
      const TeamRoster(ownerWorkspace, [
        TeamMember(
          'owner-a',
          'Stale Owner',
          'stale@example.test',
          CafeRole.owner,
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('stale@example.test'), findsNothing);
    expect(find.text('Team members unavailable'), findsOneWidget);
  });

  testWidgets('Empty verified list is explicit and never fabricates self', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: _Auth(),
          resolver: _Resolver.success(ownerWorkspace),
          members: _Members()..empty = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Verified Members (0)'), findsOneWidget);
    expect(find.text('No verified members are available.'), findsOneWidget);
    expect(find.text('sarah@example.test'), findsNothing);
  });
}
