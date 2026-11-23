import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
// Firebase interfaces are replaced with offline doubles in these UI tests.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/team/staff_invitation_page.dart';
import 'package:velora/screens/team/team_management_page.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/team_members_service.dart';
import 'package:velora/services/workspace_session.dart';
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
  int reads = 0;
  User? user = _User();
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  FirebaseApp get app => _RosterApp('velora-spark-test');

  @override
  User? get currentUser {
    reads++;
    return user;
  }

  @override
  Stream<User?> authStateChanges() => changes.stream;
}

class _RosterApp extends Fake implements FirebaseApp {
  final String project;
  _RosterApp(this.project);

  @override
  FirebaseOptions get options => FirebaseOptions(
    projectId: project,
    apiKey: 'offline',
    appId: 'offline',
    messagingSenderId: 'offline',
  );
}

class _RosterAuth extends _Auth {
  final FirebaseApp _app;

  @override
  FirebaseApp get app => _app;
  _RosterAuth(_RosterUser account, {String project = 'velora-73222'})
    : _app = _RosterApp(project) {
    user = account;
  }
}

class _RosterUser extends _User {
  final Map<String, Object> claimOverrides;
  final refreshes = <bool>[];
  late String token;
  _RosterUser(super.id, {this.claimOverrides = const {}});

  @override
  bool get emailVerified => true;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    refreshes.add(forceRefresh);
    String segment(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final header = segment({'alg': 'RS256', 'kid': 'offline'});
    final claims = segment({
      'aud': 'velora-73222',
      'iss': 'https://securetoken.google.com/velora-73222',
      'sub': uid,
      'email': email,
      'email_verified': true,
      'auth_time': now - 10,
      'iat': now - 5,
      'exp': now + 300,
      ...claimOverrides,
    });
    return token = '$header.$claims.offline';
  }
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
  int calls = 0;
  final CafeWorkspace? workspace;
  final WorkspaceFailure? failure;

  _Resolver.success(this.workspace) : failure = null;
  _Resolver.failure(this.failure) : workspace = null;

  @override
  Future<CafeWorkspace> resolve() async {
    calls++;
    if (failure != null) throw WorkspaceResolutionException(failure!);
    return workspace!;
  }
}

class _PagedMembers extends _Members implements PagedTeamMembers {
  final requested = <String>[];
  Completer<TeamRoster>? pendingPage;

  @override
  Future<TeamRoster> load(CafeWorkspace workspace) async =>
      TeamRoster(workspace, const [], nextCursor: 'page_two');

  @override
  Future<TeamRoster> loadPage(CafeWorkspace workspace, String cursor) async {
    requested.add(cursor);
    if (pendingPage case final page?) return page.future;
    return TeamRoster(workspace, const [
      TeamMember(
        'staff-b',
        'Second Page',
        'staff-b@example.test',
        CafeRole.staff,
      ),
    ]);
  }
}

AndroidPilotPolicy _pilotPolicy(bool invalid) => AndroidPilotPolicy.parse(
  invalid
      ? {'VELORA_ANDROID_READ_ONLY_PILOT': 'false'}
      : {
          'VELORA_ANDROID_READ_ONLY_PILOT': 'true',
          'VELORA_FIREBASE_PROJECT': AndroidPilotPolicy.approvedProject,
          'VELORA_ANDROID_PILOT_BINDINGS':
              '[["synthetic-owner","synthetic-cafe"]]',
        },
  isWeb: false,
  platform: TargetPlatform.android,
);
final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

void main() {
  for (final invalid in [false, true]) {
    test(
      'Team service invalid=$invalid rejects before Auth and callable lookup',
      () async {
        final policy = _pilotPolicy(invalid), auth = _Auth();
        final resolver = _Resolver.failure(WorkspaceFailure.unavailable);
        final service = FirebaseTeamMembers(
          pilotPolicy: policy,
          auth: auth,
          resolver: resolver,
        );
        expect(service.pilotPolicy, same(policy));
        await expectLater(
          service.load(
            const CafeWorkspace(
              cafeId: 'cafe-a',
              uid: 'owner-a',
              ownerUid: 'owner-a',
              role: CafeRole.owner,
            ),
          ),
          throwsA(isA<TeamPilotPolicyException>()),
        );
        expect(auth.reads, 0);
        expect(resolver.calls, 0);
        await auth.changes.close();
      },
    );
    testWidgets(
      'direct Team invalid=$invalid does not invoke injected dependencies',
      (tester) async {
        final auth = _Auth(),
            members = _Members(),
            resolver = _Resolver.failure(WorkspaceFailure.unavailable);
        await tester.pumpWidget(
          AndroidPilotAuthScope(
            dependencies: AndroidPilotAuthDependencies(
              policy: _pilotPolicy(invalid),
            ),
            child: MaterialApp(
              home: TeamManagementPage(
                auth: auth,
                members: members,
                resolver: resolver,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
        expect(auth.reads, 0);
        expect(members.calls, 0);
        expect(resolver.calls, 0);
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
      },
    );
  }
  testWidgets('captured Team retry cannot bypass replaced policy', (
    tester,
  ) async {
    var policy = _normalPolicy;
    late StateSetter update;
    final auth = _Auth(), members = _Members();
    final resolver = _Resolver.success(
      const CafeWorkspace(
        cafeId: 'cafe-a',
        uid: 'owner-a',
        ownerUid: 'owner-a',
        role: CafeRole.owner,
      ),
    );
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return AndroidPilotAuthScope(
            dependencies: AndroidPilotAuthDependencies(policy: policy),
            child: MaterialApp(
              home: TeamManagementPage(
                auth: auth,
                members: members,
                resolver: resolver,
              ),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    final retry = tester
        .widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Refresh members'),
        )
        .onPressed!;
    final before = members.calls;
    update(() => policy = _pilotPolicy(false));
    await tester.pump();
    retry();
    await tester.pump();
    expect(members.calls, before);
    expect(find.text('Sarah Parker'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });
  testWidgets('pending Team result is hidden after policy invalidation', (
    tester,
  ) async {
    var policy = _normalPolicy;
    late StateSetter update;
    final auth = _Auth(),
        members = _Members()..pending = Completer<TeamRoster>();
    const workspace = CafeWorkspace(
      cafeId: 'cafe-a',
      uid: 'owner-a',
      ownerUid: 'owner-a',
      role: CafeRole.owner,
    );
    final resolver = _Resolver.success(workspace);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return AndroidPilotAuthScope(
            dependencies: AndroidPilotAuthDependencies(policy: policy),
            child: MaterialApp(
              home: TeamManagementPage(
                auth: auth,
                members: members,
                resolver: resolver,
              ),
            ),
          );
        },
      ),
    );
    await tester.pump();
    expect(members.calls, 1);
    update(() => policy = _pilotPolicy(true));
    await tester.pump();
    members.pending!.complete(TeamRoster(workspace, const []));
    await tester.pump();
    expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
    expect(find.textContaining('Verified Members'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });

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

  const rosterOrigin = 'https://rest-api.velora-smart-inventory.workers.dev';
  Future<void> settleRoster(WidgetTester tester) async {
    await tester.pump();
    // Stream cleanup can complete on the real event loop before fake time moves.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Map<String, Object> row(String uid, String name, CafeRole role) => {
    'uid': uid,
    'name': name,
    'email': '$uid@example.test',
    'role': role.name,
  };
  http.Response rosterResponse(
    CafeWorkspace workspace,
    List<Map<String, Object>> members, {
    String? cursor,
  }) => http.Response(
    jsonEncode({
      'cafeId': workspace.cafeId,
      'viewerRole': workspace.role.name,
      'members': members,
      'nextCursor': ?cursor,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  testWidgets(
    'REAL directory uses verified bearer and workspace on every owner page',
    (tester) async {
      final user = _RosterUser(ownerWorkspace.uid),
          requests = <Map<String, dynamic>>[];
      final workspace = CafeWorkspace(
        cafeId: ownerWorkspace.cafeId,
        uid: ownerWorkspace.uid,
        ownerUid: ownerWorkspace.ownerUid,
        role: CafeRole.owner,
        membershipGeneration: 7,
      );
      final auth = _RosterAuth(user);
      await tester.pumpWidget(
        app(
          TeamManagementPage(
            auth: auth,
            workspaceSession: WorkspaceSession.fromVerified(workspace),
            rosterOrigin: rosterOrigin,
            createRosterClient: () => MockClient((request) async {
              expect(request.url.toString(), '$rosterOrigin/staff/list');
              expect(request.headers['authorization'], 'Bearer ${user.token}');
              expect(request.followRedirects, isFalse);
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              requests.add(body);
              return body['cursor'] == null
                  ? rosterResponse(workspace, [
                      row(workspace.uid, 'REAL Owner', CafeRole.owner),
                    ], cursor: 'page_two')
                  : rosterResponse(workspace, [
                      row('staff-b', 'REAL Staff', CafeRole.staff),
                    ]);
            }),
          ),
        ),
      );
      auth.changes.add(user);
      await settleRoster(tester);
      expect(find.text('REAL Owner'), findsOneWidget);
      expect(find.text('No verified Staff members are listed.'), findsNothing);
      await tester.tap(find.text('Next page'));
      await settleRoster(tester);
      expect(find.text('REAL Staff'), findsOneWidget);
      expect(requests, [
        {'expectedCafeId': workspace.cafeId, 'expectedMembershipGeneration': 7},
        {
          'cursor': 'page_two',
          'expectedCafeId': workspace.cafeId,
          'expectedMembershipGeneration': 7,
        },
      ]);
      expect(user.refreshes, [false, false]);
      auth.changes.add(user);
      await tester.pumpAndSettle();
      expect(find.text('REAL Staff'), findsNothing);
      expect(find.text('Team members unavailable'), findsOneWidget);
      expect(requests, hasLength(2));
    },
  );

  testWidgets('REAL Owner roster clears when workspace authority is revoked', (
    tester,
  ) async {
    final user = _RosterUser(ownerWorkspace.uid);
    final auth = _RosterAuth(user);
    final workspace = WorkspaceSession.fromVerified(ownerWorkspace);
    var requests = 0;
    http.Client createClient() => MockClient((_) async {
      requests++;
      return rosterResponse(ownerWorkspace, [
        row(ownerWorkspace.uid, 'Verified Owner', CafeRole.owner),
      ]);
    });
    Widget page() => app(
      TeamManagementPage(
        auth: auth,
        workspaceSession: workspace,
        createRosterClient: createClient,
      ),
    );
    await tester.pumpWidget(page());
    auth.changes.add(user);
    await settleRoster(tester);
    expect(find.text('Verified Owner'), findsOneWidget);
    final invite = tester
        .widget<FilledButton>(find.byKey(const ValueKey('invite-staff-button')))
        .onPressed!;
    workspace.invalidate();
    await tester.pumpWidget(page());
    invite();
    await tester.pumpAndSettle();
    expect(find.text('Verified Owner'), findsNothing);
    expect(find.byType(StaffInvitationPage), findsNothing);
    expect(find.byKey(const ValueKey('invite-staff-button')), findsNothing);
    expect(requests, 1);
  });

  testWidgets('REAL Staff response cannot include an unrelated Staff user', (
    tester,
  ) async {
    const workspace = CafeWorkspace(
      cafeId: 'cafe-a',
      uid: 'staff-a',
      ownerUid: 'owner-a',
      role: CafeRole.staff,
    );
    final replies = <Map<String, Object>>[
      row(workspace.ownerUid, 'REAL Owner', CafeRole.owner),
      row(workspace.uid, 'REAL Staff', CafeRole.staff),
    ];
    final user = _RosterUser(workspace.uid);
    final auth = _RosterAuth(user);
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: auth,
          workspaceSession: WorkspaceSession.fromVerified(workspace),
          rosterOrigin: rosterOrigin,
          createRosterClient: () =>
              MockClient((_) async => rosterResponse(workspace, replies)),
        ),
      ),
    );
    auth.changes.add(user);
    await settleRoster(tester);
    expect(find.text('REAL Owner'), findsOneWidget);
    expect(find.text('REAL Staff'), findsOneWidget);
    expect(find.text('Next page'), findsNothing);
    replies.add(row('other-staff', 'Other Staff', CafeRole.staff));
    await tester.tap(find.text('Refresh members'));
    await settleRoster(tester);
    expect(find.text('Team members unavailable'), findsOneWidget);
    expect(find.text('Other Staff'), findsNothing);
  });

  for (final failure in [
    'missing origin',
    'wrong project',
    'wrong UID',
    'expired JWT',
    'wrong JWT audience',
    'REST 503',
  ]) {
    testWidgets('REAL directory fails closed on $failure', (tester) async {
      final user = _RosterUser(
        failure == 'wrong UID' ? 'other-user' : ownerWorkspace.uid,
        claimOverrides: {
          if (failure == 'expired JWT') 'exp': 1,
          if (failure == 'wrong JWT audience') 'aud': 'velora-spark-test',
        },
      );
      final auth = _RosterAuth(
        user,
        project: failure == 'wrong project'
            ? 'velora-spark-test'
            : 'velora-73222',
      );
      var calls = 0;
      await tester.pumpWidget(
        app(
          TeamManagementPage(
            auth: auth,
            workspaceSession: WorkspaceSession.fromVerified(ownerWorkspace),
            rosterOrigin: failure == 'missing origin' ? '' : rosterOrigin,
            createRosterClient: () => MockClient((_) async {
              calls++;
              return http.Response(
                '{"error":"unavailable"}',
                503,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        ),
      );
      auth.changes.add(user);
      await settleRoster(tester);
      expect(find.text('Team members unavailable'), findsOneWidget);
      expect(calls, failure == 'REST 503' ? 1 : 0);
    });
  }

  testWidgets(
    'REAL Owner with zero Staff sees the empty state and can invite',
    (tester) async {
      final user = _RosterUser(ownerWorkspace.uid);
      final auth = _RosterAuth(user);
      await tester.pumpWidget(
        app(
          TeamManagementPage(
            auth: auth,
            workspaceSession: WorkspaceSession.fromVerified(ownerWorkspace),
            createRosterClient: () => MockClient((request) async {
              expect(request.method, 'POST');
              expect(request.url.path, '/staff/list');
              return rosterResponse(ownerWorkspace, [
                row(ownerWorkspace.uid, 'REAL Owner', CafeRole.owner),
              ]);
            }),
          ),
        ),
      );
      auth.changes.add(user);
      await settleRoster(tester);
      expect(find.text('REAL Owner'), findsOneWidget);
      expect(
        find.text('No verified Staff members are listed.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('invite-staff-button')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  for (final (status, code, message) in [
    (401, 'unauthenticated', 'Your sign-in could not be verified'),
    (403, 'permission-denied', 'The service denied access'),
    (429, 'resource-exhausted', 'The team service is busy'),
    (503, 'unavailable', 'The team service is temporarily unavailable'),
    (200, 'malformed', 'The team service returned an invalid roster'),
    (0, 'network', 'Velora could not reach the team service'),
  ]) {
    testWidgets('REAL roster classifies $code independently', (tester) async {
      final user = _RosterUser(ownerWorkspace.uid);
      final auth = _RosterAuth(user);
      await tester.pumpWidget(
        app(
          TeamManagementPage(
            auth: auth,
            workspaceSession: WorkspaceSession.fromVerified(ownerWorkspace),
            createRosterClient: () => MockClient((request) async {
              expect(request.url.path, '/staff/list');
              if (status == 0) throw http.ClientException('Offline fixture');
              return http.Response(
                jsonEncode({'error': code}),
                status,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        ),
      );
      auth.changes.add(user);
      await settleRoster(tester);
      expect(find.textContaining(message), findsOneWidget);
      expect(find.textContaining('Verified Members'), findsNothing);
      final invite = find.byKey(const ValueKey('invite-staff-button'));
      if ([429, 503, 0].contains(status)) {
        expect(tester.widget<FilledButton>(invite).onPressed, isNotNull);
        if (status == 429) {
          await tester.tap(invite);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<StaffInvitationPage>(find.byType(StaffInvitationPage))
                .ownerMode,
            isTrue,
          );
        }
      } else {
        expect(invite, findsNothing);
      }
    });
  }

  testWidgets('Owner can advance an empty page and return to the first page', (
    tester,
  ) async {
    final members = _PagedMembers();
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: _Auth(),
          members: members,
          resolver: _Resolver.success(ownerWorkspace),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No verified members are available.'), findsOneWidget);
    await tester.tap(find.text('Next page'));
    await tester.tap(find.text('Next page'));
    await tester.pumpAndSettle();
    expect(members.requested, ['page_two']);
    expect(find.text('Second Page'), findsOneWidget);
    expect(find.text('Next page'), findsNothing);
    await tester.tap(find.text('Previous page'));
    await tester.tap(find.text('Previous page'));
    await tester.pumpAndSettle();
    expect(find.text('Second Page'), findsNothing);
    expect(find.text('Next page'), findsOneWidget);
  });

  testWidgets('Replacing the workspace clears history and drops a late page', (
    tester,
  ) async {
    final pending = Completer<TeamRoster>();
    final members = _PagedMembers()..pendingPage = pending;
    final auth = _Auth();
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: auth,
          members: members,
          resolver: _Resolver.success(ownerWorkspace),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next page'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    const replacementWorkspace = CafeWorkspace(
      cafeId: 'cafe-b',
      uid: 'owner-a',
      ownerUid: 'owner-a',
      role: CafeRole.owner,
      membershipGeneration: 1,
    );
    await tester.pumpWidget(
      app(
        TeamManagementPage(
          auth: auth,
          members: _Members(),
          resolver: _Resolver.success(replacementWorkspace),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Previous page'), findsNothing);
    expect(find.text('Sarah Parker'), findsOneWidget);

    pending.complete(
      const TeamRoster(ownerWorkspace, [
        TeamMember(
          'late-staff',
          'Late Staff',
          'late@example.test',
          CafeRole.staff,
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Late Staff'), findsNothing);
    expect(find.text('Sarah Parker'), findsOneWidget);
  });

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

      expect(find.text('Invite Staff'), findsNothing);
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
    expect(find.text('Invite Staff'), findsNothing);
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
    expect(find.text('Invite Staff'), findsNothing);
    expect(find.text('Remove access'), findsNothing);
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
