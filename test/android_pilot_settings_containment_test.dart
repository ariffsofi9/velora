// Synthetic SDK boundaries only; never initialize Firebase or use a network.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'package:velora/screens/auth/workspace_session_boundary.dart';
import 'package:velora/screens/business_setup/business_setup_page.dart';
import 'package:velora/screens/menu/menu_page.dart';
import 'package:velora/screens/team/team_management_page.dart';
import 'package:velora/screens/team/staff_invitation_page.dart';
import 'package:velora/screens/settings/settings_page.dart';
import 'package:velora/screens/settings/appearance_page.dart';
import 'package:velora/screens/settings/widgets_settings/edit_profile_dialog.dart';
import 'package:velora/screens/settings/widgets_settings/profile_header_card.dart';
import 'package:velora/screens/settings/widgets_settings/notification_settings_card.dart';
import 'package:velora/screens/settings/widgets_settings/preferences_settings_card.dart';
import 'package:velora/screens/settings/widgets_settings/logout_card.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/services/owner_email_verification.dart';
import 'package:velora/services/staff_invitation_service.dart';
import 'package:velora/services/user_profile_service.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'package:velora/services/workspace_session.dart';
import 'helpers/workspace_bootstrap_fake.dart';
import 'helpers/owner_verification_fake.dart';

AndroidPilotPolicy policy(AndroidPilotState state) => AndroidPilotPolicy.parse(
  state == AndroidPilotState.normal
      ? {}
      : {
          AndroidPilotPolicy.modeKey: state == AndroidPilotState.invalid
              ? 'false'
              : 'true',
          AndroidPilotPolicy.projectKey: AndroidPilotPolicy.approvedProject,
          AndroidPilotPolicy.bindingsKey: jsonEncode([
            ['synthetic-owner', 'synthetic-cafe'],
            ['synthetic-staff', 'synthetic-cafe'],
          ]),
        },
  isWeb: false,
  platform: TargetPlatform.android,
);

class _Token extends Fake implements IdTokenResult {
  @override
  Map<String, dynamic> get claims => {'email_verified': true};
}

class _User extends Fake implements User {
  @override
  final String uid;
  @override
  bool emailVerified = true;
  @override
  String? displayName = 'Cached Auth name';
  @override
  String get email => 'synthetic@example.test';
  @override
  String? photoURL;
  int names = 0, photos = 0, emails = 0, reloads = 0, tokens = 0;
  Completer<void>? pendingReload;
  _User({this.uid = 'synthetic-owner'});
  @override
  Future<void> updateDisplayName(String? value) async {
    names++;
    displayName = value;
  }

  @override
  Future<void> updatePhotoURL(String? value) async {
    photos++;
    photoURL = value;
  }

  @override
  Future<void> sendEmailVerification([ActionCodeSettings? settings]) async {
    emails++;
  }

  @override
  Future<void> reload() async {
    reloads++;
    await pendingReload?.future;
  }

  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async {
    tokens++;
    return _Token();
  }
}

class _Auth extends Fake implements FirebaseAuth {
  User? user;
  int signOuts = 0, listeners = 0;
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
    );
    controller.onCancel = () {
      listeners--;
      unawaited(sub.cancel());
    };
    controller.addSync(user);
  });
  @override
  Stream<User?> idTokenChanges() => authStateChanges();
  @override
  Future<void> signOut() async {
    signOuts++;
    replace(null);
  }
}

class _Metadata extends Fake implements SnapshotMetadata {
  @override
  bool get isFromCache => false;
  @override
  bool get hasPendingWrites => false;
}

class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  @override
  final String id;
  final Map<String, dynamic>? value;
  _Snapshot(this.id, this.value);
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
  @override
  SnapshotMetadata get metadata => _Metadata();
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _Database db;
  final String uid;
  _Document(this.db, this.uid);
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    db.sources.add(options?.source);
    db.uids.add(uid);
    if (db.pendingRead == db.sources.length) await db.pending?.future;
    if (db.error != null) throw db.error!;
    return _Snapshot(uid, db.value);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    db.writes++;
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    db.writes++;
  }
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _Database db;
  _Collection(this.db);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _Document(db, path!);
}

class _Database extends Fake implements FirebaseFirestore {
  Map<String, dynamic>? value = {
    'username': 'Server confirmed name',
    'email': 'synthetic@example.test',
    'photoUrl': '',
    'role': 'owner',
    'createdAt': Timestamp.fromMillisecondsSinceEpoch(1000),
    'updatedAt': Timestamp.fromMillisecondsSinceEpoch(1000),
  };
  Object? error;
  Completer<void>? pending;
  int pendingRead = -1, writes = 0;
  final sources = <Source?>[];
  final uids = <String>[];
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path != 'users') throw StateError('Unexpected synthetic collection');
    return _Collection(this);
  }
}

class _Profiles extends UserProfileService {
  int creates = 0;
  @override
  Future<void> createUserProfileIfNeeded(
    User user, {
    String? initialUsername,
  }) async {
    creates++;
  }
}

class _Preferences extends Fake implements SharedPreferences {
  int writes = 0;
  @override
  bool? getBool(String key) => false;
  @override
  Future<bool> setBool(String key, bool value) async {
    writes++;
    return true;
  }
}

class _Invitations extends Fake implements StaffInvitations {
  int creates = 0, revokes = 0, redeems = 0;
  @override
  Future<StaffInvitation> create(
    String email, {
    required CafeWorkspace workspace,
  }) async {
    creates++;
    throw StateError('Synthetic invocation');
  }

  @override
  Future<void> revoke(String id, {required CafeWorkspace workspace}) async {
    revokes++;
  }

  @override
  Future<void> redeem(String code) async {
    redeems++;
  }
}

class _Provisioner extends Fake implements WorkspaceProvisioner {
  int calls = 0;
  @override
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  ) async {
    calls++;
    return const WorkspaceCreationResult(created: true);
  }
}

class _Fixture {
  final user = _User();
  final auth = _Auth();
  final db = _Database();
  final profiles = _Profiles();
  final preferences = _Preferences();
  final invitations = _Invitations();
  final provisioner = _Provisioner();
  final verification = VerifiedOwnerFake();
  final session = WorkspaceSession.fromVerified(
    const CafeWorkspace(
      uid: 'synthetic-owner',
      cafeId: 'synthetic-cafe',
      ownerUid: 'synthetic-owner',
      role: CafeRole.owner,
      membershipGeneration: 7,
    ),
  );
  int preferenceLookups = 0;
  _Fixture() {
    auth.user = user;
  }
  AndroidPilotAuthDependencies dependencies(AndroidPilotState state) =>
      AndroidPilotAuthDependencies(
        policy: policy(state),
        firebaseAuth: auth,
        firestore: db,
      );
  SettingsPage settings({WorkspaceSession? workspace}) => SettingsPage(
    workspaceSession: workspace ?? session,
    auth: auth,
    profileService: profiles,
    preferences: () async {
      preferenceLookups++;
      return preferences;
    },
  );
  void expectNoWrites() {
    expect(db.writes, 0);
    expect(user.names, 0);
    expect(user.photos, 0);
    expect(user.emails, 0);
    expect(preferences.writes, 0);
    expect(provisioner.calls, 0);
    expect(invitations.creates + invitations.revokes + invitations.redeems, 0);
  }

  Future<void> close() async {
    await auth.changes.close();
  }
}

void pilotTest(String name, WidgetTesterCallback body) =>
    testWidgets(name, body, timeout: const Timeout(Duration(seconds: 40)));
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget scoped(AndroidPilotAuthDependencies dependencies, Widget child) =>
    AndroidPilotAuthScope(
      dependencies: dependencies,
      child: MaterialApp(home: child),
    );

const request = WorkspaceCreationRequest(
  businessName: 'Synthetic Cafe',
  businessType: 'Bakery',
  address: '',
  inventoryUnit: 'kg',
  lowStockAlerts: true,
  expiryReminders: true,
  reminderDays: 3,
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

  pilotTest(
    'restricted Settings displays a server profile without repair or preferences access',
    (tester) async {
      final dependencies = f.dependencies(AndroidPilotState.restricted);
      await tester.pumpWidget(scoped(dependencies, f.settings()));
      await frames(tester);
      expect(find.text('Server confirmed name'), findsOneWidget);
      expect(find.text('Cached Auth name'), findsNothing);
      expect(f.db.sources, [Source.server, Source.server]);
      expect(f.db.uids, everyElement(f.user.uid));
      expect(f.profiles.creates, 0);
      expect(f.preferenceLookups, 0);
      expect(f.session.isActive, isTrue);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final failure in [
    'missing',
    'unavailable',
    'invalid',
    'unverified',
    'wrong-uid',
    'wrong-workspace',
  ]) {
    pilotTest('Settings rejects $failure without repair', (tester) async {
      var workspace = f.session;
      switch (failure) {
        case 'missing':
          f.db.value = null;
        case 'unavailable':
          f.db.error = StateError('synthetic-private-error');
        case 'invalid':
          f.db.value!.remove('username');
        case 'unverified':
          f.user.emailVerified = false;
        case 'wrong-uid':
          f.auth.user = _User(uid: 'synthetic-other');
        case 'wrong-workspace':
          workspace = WorkspaceSession.fromVerified(
            const CafeWorkspace(
              uid: 'synthetic-owner',
              cafeId: 'synthetic-other-cafe',
              ownerUid: 'synthetic-owner',
              role: CafeRole.owner,
              membershipGeneration: 7,
            ),
          );
      }
      await tester.pumpWidget(
        scoped(
          f.dependencies(AndroidPilotState.restricted),
          f.settings(workspace: workspace),
        ),
      );
      await frames(tester);
      expect(find.text('Server confirmed name'), findsNothing);
      expect(
        find.textContaining('Profile could not be verified'),
        findsWidgets,
      );
      expect(find.textContaining('synthetic-private-error'), findsNothing);
      expect(f.profiles.creates, 0);
      expect(f.preferenceLookups, 0);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    });
  }
  pilotTest('invalid Settings policy performs zero protected reads or writes', (
    tester,
  ) async {
    await tester.pumpWidget(
      scoped(f.dependencies(AndroidPilotState.invalid), f.settings()),
    );
    await frames(tester);
    expect(f.db.sources, isEmpty);
    expect(f.profiles.creates, 0);
    expect(f.preferenceLookups, 0);
    f.expectNoWrites();
    await tester.pumpWidget(const SizedBox());
  });

  pilotTest(
    'Settings handlers block profile, Menu, Team and preference dispatch',
    (tester) async {
      await tester.pumpWidget(
        scoped(f.dependencies(AndroidPilotState.restricted), f.settings()),
      );
      await frames(tester);
      // Call callbacks directly, including those under IgnorePointer.
      await tester.scrollUntilVisible(
        find.byType(NotificationSettingsCard),
        150,
      );
      final notifications = tester.widget<NotificationSettingsCard>(
        find.byType(NotificationSettingsCard),
      );
      notifications.onNearExpiryChanged(false);
      notifications.onLowStockChanged(false);
      notifications.onActivityChanged(true);
      await tester.scrollUntilVisible(
        find.byType(PreferencesSettingsCard),
        150,
      );
      tester
          .widget<PreferencesSettingsCard>(find.byType(PreferencesSettingsCard))
          .onOpenAppearance();
      for (final name in ['Team Management', 'Menu Management']) {
        await tester.scrollUntilVisible(find.text(name), -120);
        expect(
          tester.widget<ListTile>(find.widgetWithText(ListTile, name)).onTap,
          isNull,
        );
      }
      await frames(tester);
      expect(find.byType(MenuPage), findsNothing);
      expect(find.byType(TeamManagementPage), findsNothing);
      expect(find.byType(EditProfileDialog), findsNothing);
      expect(find.byType(AppearancePage), findsNothing);
      expect(f.preferenceLookups, 0);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    },
  );
  pilotTest(
    'callbacks captured in normal Settings cannot bypass a later restricted scope',
    (tester) async {
      var dependencies = f.dependencies(AndroidPilotState.normal);
      late StateSetter update;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return scoped(dependencies, f.settings());
          },
        ),
      );
      await frames(tester);
      final edit = tester
          .widget<ProfileHeaderCard>(find.byType(ProfileHeaderCard))
          .onEdit!;
      final callbacks = <VoidCallback>[];
      for (final name in ['Team Management', 'Menu Management']) {
        await tester.scrollUntilVisible(find.text(name), 100);
        callbacks.add(
          tester.widget<ListTile>(find.widgetWithText(ListTile, name)).onTap!,
        );
      }
      await tester.scrollUntilVisible(
        find.byType(NotificationSettingsCard),
        150,
      );
      final notifications = tester.widget<NotificationSettingsCard>(
        find.byType(NotificationSettingsCard),
      );
      await tester.scrollUntilVisible(
        find.byType(PreferencesSettingsCard),
        150,
      );
      final appearance = tester
          .widget<PreferencesSettingsCard>(find.byType(PreferencesSettingsCard))
          .onOpenAppearance;
      final previousLookups = f.preferenceLookups;
      update(() => dependencies = f.dependencies(AndroidPilotState.restricted));
      await tester.pump();
      edit();
      appearance();
      for (final callback in callbacks) {
        callback();
      }
      notifications.onNearExpiryChanged(false);
      await frames(tester);
      expect(find.byType(MenuPage), findsNothing);
      expect(find.byType(TeamManagementPage), findsNothing);
      expect(find.byType(EditProfileDialog), findsNothing);
      expect(find.byType(AppearancePage), findsNothing);
      expect(f.preferenceLookups, previousLookups);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final state in [
    AndroidPilotState.restricted,
    AndroidPilotState.invalid,
  ]) {
    pilotTest('$state Settings logout keeps policy and clears navigation', (
      tester,
    ) async {
      final dependencies = f.dependencies(state);
      await tester.pumpWidget(scoped(dependencies, f.settings()));
      await frames(tester);
      await tester.scrollUntilVisible(find.byType(LogoutCard), 180);
      tester.widget<LogoutCard>(find.byType(LogoutCard)).onLogout();
      await frames(tester);
      expect(f.auth.user, isNull);
      expect(f.auth.signOuts, 1);
      final login = tester.widget<LoginPage>(find.byType(LoginPage));
      expect(login.pilot, same(dependencies));
      expect(
        Navigator.of(tester.element(find.byType(LoginPage))).canPop(),
        isFalse,
      );
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    });
    pilotTest('$state direct Edit Profile has no update action', (
      tester,
    ) async {
      await tester.pumpWidget(
        scoped(f.dependencies(state), EditProfileDialog(user: f.user)),
      );
      expect(find.text('Profile editing unavailable'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Save'), findsNothing);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    });
    pilotTest(
      '$state Business Setup rejects injected unguarded services before dispatch',
      (tester) async {
        await tester.pumpWidget(
          scoped(
            f.dependencies(state),
            BusinessSetupPage(
              provisioner: f.provisioner,
              verification: f.verification,
            ),
          ),
        );
        expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
        expect(find.byKey(const ValueKey('setup-dashboard')), findsNothing);
        expect(f.verification.refreshes, 0);
        f.expectNoWrites();
        await tester.pumpWidget(const SizedBox());
      },
    );
    for (final ownerMode in [false, true]) {
      pilotTest(
        '$state Staff Invitation owner=$ownerMode has no callable or email dispatch',
        (tester) async {
          await tester.pumpWidget(
            scoped(
              f.dependencies(state),
              StaffInvitationPage(
                ownerMode: ownerMode,
                auth: f.auth,
                invitations: f.invitations,
              ),
            ),
          );
          expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
          expect(
            f.auth.listeners,
            0,
          ); // No service/session binding was dispatched.
          f.expectNoWrites();
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    test(
      '$state provisioner rejects before profile/config/transaction access',
      () async {
        final store = BootstrapFake();
        var configurationReads = 0;
        final service = FirebaseWorkspaceProvisioner(
          pilotPolicy: policy(state),
          store: store,
          verification: f.verification,
          resolveProfile: () {
            configurationReads++;
            throw StateError('Not allowed');
          },
        );
        await expectLater(
          service.createWorkspace(request),
          throwsA(
            isA<WorkspaceProvisioningException>().having(
              (e) => e.outcomeUncertain,
              'no dispatch',
              isFalse,
            ),
          ),
        );
        expect(store.calls, 0);
        expect(store.ids, 0);
        expect(store.commits, 0);
        expect(store.docs, isEmpty);
        expect(configurationReads, 0);
        expect(f.verification.refreshes, 0);
        // No Firebase singleton access even without injected SDK dependencies.
        await expectLater(
          FirebaseWorkspaceProvisioner(
            pilotPolicy: policy(state),
          ).createWorkspace(request),
          throwsA(isA<WorkspaceProvisioningException>()),
        );
      },
    );
    test(
      '$state verification email rejects before Auth lookup or cooldown changes',
      () async {
        final service = FirebaseOwnerEmailVerification(
          auth: f.auth,
          pilotPolicy: policy(state),
        );
        await expectLater(
          service.sendVerification(),
          throwsA(isA<OwnerVerificationException>()),
        );
        expect(service.resendRemaining, Duration.zero);
        await expectLater(
          FirebaseOwnerEmailVerification(
            pilotPolicy: policy(state),
          ).sendVerification(),
          throwsA(isA<OwnerVerificationException>()),
        );
        f.expectNoWrites();
      },
    );
  }
  pilotTest(
    'a captured Edit Profile Save callback cannot dispatch under restricted policy',
    (tester) async {
      var dependencies = f.dependencies(AndroidPilotState.normal);
      late StateSetter update;
      final dialog = EditProfileDialog(user: f.user);
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return scoped(dependencies, dialog);
          },
        ),
      );
      final save = tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Save'))
          .onPressed!;
      update(() => dependencies = f.dependencies(AndroidPilotState.restricted));
      await tester.pump();
      save();
      await frames(tester);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    },
  );
  pilotTest(
    'captured Staff invitation actions and direct email callback cannot bypass policy',
    (tester) async {
      var dependencies = f.dependencies(AndroidPilotState.normal);
      late StateSetter update;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return scoped(
              dependencies,
              StaffInvitationPage(auth: f.auth, invitations: f.invitations),
            );
          },
        ),
      );
      await frames(tester);
      final redeem = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Redeem invitation'),
          )
          .onPressed!;
      final send = tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Send verification email'),
          )
          .onPressed!;
      update(() => dependencies = f.dependencies(AndroidPilotState.restricted));
      await tester.pump();
      redeem();
      send();
      await frames(tester);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    },
  );
  pilotTest(
    'captured Business Create callback stops before refresh and provisioning',
    (tester) async {
      var dependencies = f.dependencies(AndroidPilotState.normal);
      late StateSetter update;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return scoped(
              dependencies,
              BusinessSetupPage(
                provisioner: f.provisioner,
                verification: f.verification,
              ),
            );
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('business-name')),
        'Synthetic Cafe',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('type-Bakery')));
      await tester.tap(find.byKey(const ValueKey('type-Bakery')));
      for (var i = 0; i < 2; i++) {
        await tester.ensureVisible(find.byKey(const ValueKey('setup-next')));
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await frames(tester);
      }
      final create = tester
          .widget<FilledButton>(find.byKey(const ValueKey('setup-dashboard')))
          .onPressed!;
      update(() => dependencies = f.dependencies(AndroidPilotState.restricted));
      await tester.pump();
      create();
      await frames(tester);
      expect(f.verification.refreshes, 0);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final replacement in ['same-uid', 'other-uid', 'logout', 'unmount']) {
    pilotTest(
      '$replacement during profile view read cannot publish stale data',
      (tester) async {
        f.db.pendingRead = 2;
        f.db.pending = Completer<void>();
        await tester.pumpWidget(
          scoped(f.dependencies(AndroidPilotState.restricted), f.settings()),
        );
        await frames(tester);
        expect(f.db.sources, hasLength(2));
        if (replacement == 'unmount') {
          await tester.pumpWidget(
            const MaterialApp(home: Text('Replacement root')),
          );
        } else {
          f.auth.replace(
            replacement == 'logout'
                ? null
                : _User(
                    uid: replacement == 'same-uid'
                        ? f.user.uid
                        : 'synthetic-other',
                  ),
          );
        }
        f.db.pending!.complete();
        await frames(tester);
        expect(find.text('Server confirmed name'), findsNothing);
        if (replacement != 'unmount') expect(f.session.isActive, isFalse);
        f.expectNoWrites();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test(
    'restricted verification refresh remains read-only for an approved account',
    () async {
      final service = FirebaseOwnerEmailVerification(
        auth: f.auth,
        pilotPolicy: policy(AndroidPilotState.restricted),
      );
      expect(await service.refreshVerified(), isTrue);
      expect(f.user.reloads, 1);
      expect(f.user.tokens, 1);
      f.expectNoWrites();
    },
  );
  test('invalid verification refresh does not dispatch Auth reads', () async {
    await expectLater(
      FirebaseOwnerEmailVerification(
        auth: f.auth,
        pilotPolicy: policy(AndroidPilotState.invalid),
      ).refreshVerified(),
      throwsA(isA<OwnerVerificationException>()),
    );
    expect(f.user.reloads, 0);
    expect(f.user.tokens, 0);
  });
  for (final sameUid in [true, false]) {
    test(
      'replacement during verification reload stops before token refresh (same UID=$sameUid)',
      () async {
        f.user.pendingReload = Completer<void>();
        final service = FirebaseOwnerEmailVerification(
          auth: f.auth,
          pilotPolicy: policy(AndroidPilotState.restricted),
        );
        final rejected = expectLater(
          service.refreshVerified(),
          throwsA(isA<OwnerVerificationException>()),
        );
        // A bounded event turn starts the controlled reload; no wall-clock sleep.
        await Future<void>.delayed(Duration.zero);
        expect(f.user.reloads, 1);
        f.auth.replace(_User(uid: sameUid ? f.user.uid : 'synthetic-other'));
        f.user.pendingReload!.complete();
        await rejected;
        expect(f.user.tokens, 0);
        f.expectNoWrites();
      },
    );
  }
  pilotTest(
    'normal Settings retains profile setup and local preference persistence',
    (tester) async {
      await tester.pumpWidget(
        scoped(f.dependencies(AndroidPilotState.normal), f.settings()),
      );
      await frames(tester);
      expect(f.profiles.creates, 1);
      expect(f.preferenceLookups, 1);
      expect(find.byType(ProfileHeaderCard), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(NotificationSettingsCard),
        150,
      );
      tester
          .widget<NotificationSettingsCard>(
            find.byType(NotificationSettingsCard),
          )
          .onNearExpiryChanged(true);
      await frames(tester);
      expect(f.preferences.writes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('normal verification retains email sending', () async {
    f.user.emailVerified = false;
    await FirebaseOwnerEmailVerification(
      auth: f.auth,
      pilotPolicy: policy(AndroidPilotState.normal),
    ).sendVerification();
    expect(f.user.emails, 1);
  });
  test(
    'restricted verification refresh may report an approved account still unverified',
    () async {
      f.user.emailVerified = false;
      final service = FirebaseOwnerEmailVerification(
        auth: f.auth,
        pilotPolicy: policy(AndroidPilotState.restricted),
      );
      expect(await service.refreshVerified(), isFalse);
      expect(f.user.reloads, 1);
      expect(f.user.tokens, 0);
      f.expectNoWrites();
    },
  );
  pilotTest(
    'a missing second server read never falls back to cached profile data',
    (tester) async {
      f.db.pendingRead = 2;
      f.db.pending = Completer<void>();
      await tester.pumpWidget(
        scoped(f.dependencies(AndroidPilotState.restricted), f.settings()),
      );
      await frames(tester);
      expect(f.db.sources, hasLength(2));
      f.db.value = null;
      f.db.pending!.complete();
      await frames(tester);
      expect(find.text('Server confirmed name'), findsNothing);
      expect(
        find.textContaining('Profile could not be verified'),
        findsWidgets,
      );
      expect(f.profiles.creates, 0);
      f.expectNoWrites();
      await tester.pumpWidget(const SizedBox());
    },
  );
  pilotTest('normal profile editing still updates Auth metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      scoped(
        f.dependencies(AndroidPilotState.normal),
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EditProfileDialog(user: f.user),
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await frames(tester);
    await tester.enterText(
      find.byType(TextField).at(0),
      'Synthetic changed name',
    );
    await tester.enterText(find.byType(TextField).at(1), 'synthetic-photo');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await frames(tester);
    expect(f.user.names, 1);
    expect(f.user.photos, 1);
    expect(f.user.reloads, 1);
    expect(f.user.displayName, 'Synthetic changed name');
    expect(f.user.photoURL, 'synthetic-photo');
    await tester.pumpWidget(const SizedBox());
  });
  for (final action in ['logout', 'membership revocation']) {
    pilotTest(
      'Settings within the actual boundary retains policy after $action',
      (tester) async {
        final dependencies = f.dependencies(AndroidPilotState.restricted);
        final authority = StreamController<bool>.broadcast(sync: true);
        await tester.pumpWidget(
          scoped(
            dependencies,
            WorkspaceSessionBoundary(
              session: f.session,
              pilot: dependencies,
              authority: authority.stream,
              resolve: () async => const CafeWorkspace(
                uid: 'synthetic-owner',
                cafeId: 'synthetic-cafe',
                ownerUid: 'synthetic-owner',
                role: CafeRole.owner,
                membershipGeneration: 7,
              ),
              child: f.settings(),
            ),
          ),
        );
        authority.add(true);
        await frames(tester);
        expect(find.text('Server confirmed name'), findsOneWidget);
        if (action == 'logout') {
          await tester.scrollUntilVisible(find.byType(LogoutCard), 180);
          tester.widget<LogoutCard>(find.byType(LogoutCard)).onLogout();
        } else {
          authority.add(false);
        }
        await frames(tester);
        expect(f.session.isActive, isFalse);
        expect(find.byType(SettingsPage), findsNothing);
        expect(find.text('Server confirmed name'), findsNothing);
        if (action == 'logout') {
          expect(
            tester.widget<LoginPage>(find.byType(LoginPage)).pilot,
            same(dependencies),
          );
        } else {
          expect(
            tester.widget<WorkspaceGate>(find.byType(WorkspaceGate)).pilot,
            same(dependencies),
          );
        }
        f.expectNoWrites();
        await tester.pumpWidget(const SizedBox());
        await authority.close();
      },
    );
  }
}
