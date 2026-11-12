import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/menu/menu_page.dart';
import 'package:velora/screens/team/team_management_page.dart';
import 'package:velora/screens/settings/widgets_settings/edit_profile_dialog.dart';
import 'package:velora/screens/settings/settings_page.dart';
import 'package:velora/screens/settings/widgets_settings/profile_header_card.dart';
import 'package:velora/screens/settings/widgets_settings/notification_settings_card.dart';
import 'package:velora/services/user_profile_service.dart';
import 'package:velora/services/workspace_session.dart';

class _User extends Fake implements User {
  @override
  final String uid;
  @override
  final bool emailVerified;
  _User(this.uid, {this.emailVerified = true});
  // A display name claiming ownership must never influence role presentation.
  @override
  String get displayName => 'Owner display metadata';
  @override
  String get email => '$uid@example.test';
  @override
  String? get photoURL => null;
  @override
  Future<void> reload() async {}
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('actor');
  final changes = StreamController<User?>.broadcast();
  int signOuts = 0;
  Completer<void>? signOutGate;
  bool failSignOut = false;
  @override
  User? get currentUser => user;
  @override
  Stream<User?> idTokenChanges() => changes.stream;
  @override
  Future<void> signOut() async {
    signOuts++;
    await signOutGate?.future;
    if (failSignOut) throw StateError('PRIVATE FAILURE');
    user = null;
    changes.add(null);
  }
}

class _Profiles extends UserProfileService {
  int calls = 0;
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<void> createUserProfileIfNeeded(
    User user, {
    String? initialUsername,
  }) async {
    calls++;
    await gate?.future;
    if (fail) throw StateError('PRIVATE FAILURE');
  }
}

class _RejectedPreferences extends Fake implements SharedPreferences {
  @override
  bool? getBool(String key) => null;
  @override
  Future<bool> setBool(String key, bool value) async => false;
}

class _Routes extends NavigatorObserver {
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      latest = route;
}

WorkspaceSession _session({
  CafeRole role = CafeRole.owner,
  int generation = 7,
}) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: 'cafe',
    uid: 'actor',
    ownerUid: role == CafeRole.owner ? 'actor' : 'owner',
    role: role,
    membershipGeneration: generation,
  ),
);

Widget _app(
  _Auth auth,
  _Profiles profiles,
  WorkspaceSession? session, {
  Future<SharedPreferences> Function()? preferences,
}) => MaterialApp(
  theme: AppTheme.light,
  home: SettingsPage(
    workspaceSession: session,
    auth: auth,
    profileService: profiles,
    preferences: preferences,
  ),
);

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(find.text(text), 180);
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final role in CafeRole.values) {
    testWidgets(
      'verified ${role.name} uses session authority and authenticated profile',
      (tester) async {
        final auth = _Auth(),
            profiles = _Profiles(),
            session = _session(role: role);
        await tester.pumpWidget(_app(auth, profiles, session));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Account Role'), 100);
        expect(
          find.text(
            'Verified workspace role: ${role == CafeRole.owner ? 'Owner' : 'Staff'}',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('by default'), findsNothing);
        expect(profiles.calls, 1);
        expect(session.membershipGeneration, 7);
        expect(
          tester
              .widget<ListTile>(
                find.widgetWithText(ListTile, 'Team Management'),
              )
              .onTap,
          isNotNull,
        );
        expect(
          tester
              .widget<ListTile>(
                find.widgetWithText(ListTile, 'Menu Management'),
              )
              .onTap,
          isNotNull,
        );
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
      },
    );
  }

  for (final kind in ['missing', 'invalidated', 'wrong-user', 'unverified']) {
    testWidgets('$kind authority has no Owner fallback or workspace actions', (
      tester,
    ) async {
      final auth = _Auth(), profiles = _Profiles();
      final session = kind == 'missing' ? null : _session();
      if (kind == 'invalidated') session!.invalidate();
      if (kind == 'wrong-user') auth.user = _User('other');
      if (kind == 'unverified') {
        auth.user = _User('actor', emailVerified: false);
      }
      await tester.pumpWidget(_app(auth, profiles, session));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ProfileHeaderCard>(find.byType(ProfileHeaderCard)).onEdit,
        isNull,
      );
      await tester.scrollUntilVisible(find.text('Account Role'), 100);
      expect(find.text('Workspace access not verified'), findsOneWidget);
      expect(find.textContaining('Verified workspace role:'), findsNothing);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Team Management'))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Menu Management'))
            .onTap,
        isNull,
      );
      expect(profiles.calls, 0);
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    });
  }

  testWidgets('notification preferences persist locally with honest copy', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'nearExpiryAlerts': false});
    final auth = _Auth(), profiles = _Profiles();
    await tester.pumpWidget(_app(auth, profiles, _session()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(NotificationSettingsCard), 180);
    expect(
      find.textContaining('Scheduling and delivery are not enabled'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<NotificationSettingsCard>(
            find.byType(NotificationSettingsCard),
          )
          .nearExpiryAlerts,
      false,
    );
    await _tap(tester, 'Near Expiry Alerts');
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getBool('nearExpiryAlerts'),
      true,
    );
    expect(profiles.calls, 1);
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });

  testWidgets('preference load failure is safe and retry can recover', (
    tester,
  ) async {
    final auth = _Auth(), profiles = _Profiles();
    var fail = true;
    await tester.pumpWidget(
      _app(
        auth,
        profiles,
        _session(),
        preferences: () async {
          if (fail) throw StateError('PRIVATE FAILURE');
          return SharedPreferences.getInstance();
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Retry preferences'), 150);
    expect(find.text('Local preferences could not be loaded.'), findsOneWidget);
    fail = false;
    await _tap(tester, 'Retry preferences');
    await tester.pumpAndSettle();
    expect(find.text('Local preferences could not be loaded.'), findsNothing);
    expect(find.textContaining('PRIVATE'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });

  testWidgets(
    'preference save failure restores displayed choice and reports failure',
    (tester) async {
      final auth = _Auth(), profiles = _Profiles();
      var calls = 0;
      await tester.pumpWidget(
        _app(
          auth,
          profiles,
          _session(),
          preferences: () async {
            if (++calls > 1) throw StateError('PRIVATE FAILURE');
            return SharedPreferences.getInstance();
          },
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'Near Expiry Alerts');
      await tester.pumpAndSettle();
      expect(
        find.text('Preference could not be saved. Please retry.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<NotificationSettingsCard>(
              find.byType(NotificationSettingsCard),
            )
            .nearExpiryAlerts,
        true,
      );
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets(
    'appearance remains a locally saved preview and profile edit remains reachable',
    (tester) async {
      final auth = _Auth(), profiles = _Profiles();
      await tester.pumpWidget(_app(auth, profiles, _session()));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ProfileHeaderCard>(find.byType(ProfileHeaderCard)).onEdit,
        isNotNull,
      );
      await _tap(tester, 'App Appearance');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('appearance-dark')));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool('darkModePrep'),
        true,
      );
      expect(
        find.textContaining('Velora remains in Light mode'),
        findsOneWidget,
      );
      expect(
        Theme.of(tester.element(find.text('Appearance'))).brightness,
        Brightness.light,
      );
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets(
    'logout ignores pending preference/profile completions and clears routes',
    (tester) async {
      final auth = _Auth(), profiles = _Profiles()..gate = Completer<void>();
      final session = _session(), pending = Completer<SharedPreferences>();
      var calls = 0;
      auth.signOutGate = Completer<void>();
      await tester.pumpWidget(
        _app(
          auth,
          profiles,
          session,
          preferences: () {
            return ++calls == 1
                ? SharedPreferences.getInstance()
                : pending.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'Near Expiry Alerts');
      await tester.pump();
      await _tap(tester, 'Sign Out');
      await tester.pump();
      expect(session.isActive, false);
      expect(auth.signOuts, 1);
      await tester.tap(find.text('Sign Out'));
      await tester.pump();
      expect(auth.signOuts, 1);
      auth.signOutGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(SettingsPage), findsNothing);
      pending.complete(await SharedPreferences.getInstance());
      profiles.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool('nearExpiryAlerts'),
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets(
    'failed logout reports failure without restoring Owner authority',
    (tester) async {
      final auth = _Auth()..failSignOut = true,
          profiles = _Profiles(),
          session = _session();
      await tester.pumpWidget(_app(auth, profiles, session));
      await tester.pumpAndSettle();
      await _tap(tester, 'Sign Out');
      await tester.pumpAndSettle();
      expect(find.text('Sign out failed. Please retry.'), findsOneWidget);
      expect(session.isActive, false);
      await tester.scrollUntilVisible(find.text('Account Role'), -180);
      await tester.pumpAndSettle();
      expect(find.text('Workspace access not verified'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets(
    'account replacement invalidates session while preferences are pending',
    (tester) async {
      final auth = _Auth(), profiles = _Profiles(), session = _session();
      final pending = Completer<SharedPreferences>();
      await tester.pumpWidget(
        _app(auth, profiles, session, preferences: () => pending.future),
      );
      await tester.pump();
      auth.user = _User('other');
      auth.changes.add(auth.user);
      await tester.pump();
      pending.complete(await SharedPreferences.getInstance());
      await tester.pumpAndSettle();
      expect(session.isActive, false);
      await tester.scrollUntilVisible(find.text('Account Role'), 100);
      expect(find.text('Workspace access not verified'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets('profile failure is sanitized rather than unhandled', (
    tester,
  ) async {
    final auth = _Auth(), profiles = _Profiles()..fail = true;
    await tester.pumpWidget(_app(auth, profiles, _session()));
    await tester.pumpAndSettle();
    expect(
      find.text('Profile could not be loaded. Please retry later.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });

  testWidgets(
    'a rejected storage acknowledgement is reported as an unsuccessful save',
    (tester) async {
      final auth = _Auth(), profiles = _Profiles();
      await tester.pumpWidget(
        _app(
          auth,
          profiles,
          _session(),
          preferences: () async => _RejectedPreferences(),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'Near Expiry Alerts');
      await tester.pumpAndSettle();
      expect(
        find.text('Preference could not be saved. Please retry.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<NotificationSettingsCard>(
              find.byType(NotificationSettingsCard),
            )
            .nearExpiryAlerts,
        true,
      );
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  for (final destination in ['Team Management', 'Menu Management']) {
    testWidgets(
      '$destination retains its existing independently verified destination',
      (tester) async {
        final auth = _Auth(), profiles = _Profiles(), observer = _Routes();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            navigatorObservers: [observer],
            home: SettingsPage(
              workspaceSession: _session(),
              auth: auth,
              profileService: profiles,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tap(tester, destination);
        // Inspect navigation without starting the destination's Firebase defaults.
        final route = observer.latest! as MaterialPageRoute<dynamic>;
        final page = route.builder(tester.element(find.byType(SettingsPage)));
        expect(
          page.runtimeType,
          destination == 'Team Management' ? TeamManagementPage : MenuPage,
        );
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
      },
    );
  }

  testWidgets('authenticated profile card still opens the existing editor', (
    tester,
  ) async {
    final auth = _Auth(), profiles = _Profiles();
    await tester.pumpWidget(_app(auth, profiles, _session()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ProfileHeaderCard));
    await tester.pumpAndSettle();
    expect(find.byType(EditProfileDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });
}
