import 'package:velora/services/android_pilot_policy.dart';
// Test-only plugin delegates keep Home's existing inventory construction offline.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_saved_recipe_repository.dart'
    as saved;
import 'package:velora/screens/home/home_page.dart';
import 'package:velora/screens/home/widgets_home/bottom_bar.dart';
import 'package:velora/screens/dashboard/dashboard_page.dart';
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'package:velora/services/workspace_session.dart';

WorkspaceSession e8Session({CafeRole role = CafeRole.owner}) =>
    WorkspaceSession.fromVerified(
      CafeWorkspace(
        cafeId: 'dashboard-cafe',
        uid: role == CafeRole.owner ? 'owner-a' : 'staff-a',
        ownerUid: 'owner-a',
        role: role,
      ),
    );

class E8SavedFixture
    implements saved.SavedRecipeReadPort, saved.SavedRecipeObservationPort {
  final WorkspaceSession workspace;
  final changes = StreamController<saved.SavedRecipeSession?>.broadcast(
    sync: true,
  );
  late final saved.SavedRecipeSession session;
  late final saved.WorkspaceSavedRecipeRepository repository;
  final operations = <String>[];
  bool populated = false;
  int reconciles = 0;
  E8SavedFixture(this.workspace) {
    session = saved.SavedRecipeSession(
      projectId: 'velora-spark-test',
      uid: workspace.uid,
      revision: 1,
      emailVerified: true,
      workspace: workspace,
    );
    repository = saved.WorkspaceSavedRecipeRepository(
      pilotPolicy: _normalPolicy,
      readPort: this,
      observationPort: this,
      currentSession: () => session,
      sessionChanges: changes.stream,
    );
  }
  @override
  Future<Object?> read(
    saved.SavedRecipeSession session,
    String operation,
    Map<String, Object?> request,
  ) async {
    operations.add(operation);
    final id = 'recipe_${'a' * 64}';
    final common = <String, Object?>{
      'recipeId': id,
      'source': 'workspace-submitted',
      'provenanceEvidence': 'unverified-attribution',
      'submittedAttribution': {
        'kind': 'sample',
        'provider': null,
        'ticketId': null,
      },
      'version': 1,
      'isArchived': false,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
    };
    if (operation == 'get') {
      return {
        'schemaVersion': 1,
        'cafeId': workspace.cafeId,
        'item': {
          ...common,
          'schemaVersion': 1,
          'projectId': 'velora-spark-test',
          'cafeId': workspace.cafeId,
          'contentDigest': 'b' * 64,
          'createdBy': workspace.uid,
          'updatedBy': workspace.uid,
          'archivedBy': null,
          'archivedAt': null,
          'recipe': {
            'title': 'Offline latte',
            'ingredients': [
              {'itemId': 'milk', 'quantity': 1, 'unit': 'L'},
            ],
            'steps': ['Serve.'],
            'whyRecommended': 'Offline sample.',
          },
        },
      };
    }
    expect(operation, 'list');
    return {
      'schemaVersion': 1,
      'cafeId': workspace.cafeId,
      'items': populated
          ? [
              {...common, 'title': 'Offline latte'},
            ]
          : [],
      'nextCursor': null,
    };
  }

  @override
  Future<Object?> reconcile(
    saved.SavedRecipeSession session,
    Map<String, Object?> request,
  ) async {
    reconciles++;
    throw StateError('Unexpected reconciliation');
  }

  Future<void> close() async {
    await repository.dispose();
    await changes.close();
  }
}

class _Core extends FirebasePlatform {
  final offline = FirebaseAppPlatform(
    '[DEFAULT]',
    const FirebaseOptions(
      apiKey: 'offline',
      appId: 'offline',
      messagingSenderId: 'offline',
      projectId: 'offline',
    ),
  );
  @override
  FirebaseAppPlatform app([String name = '[DEFAULT]']) => offline;
}

class _Firestore extends FirebaseFirestorePlatform {
  @override
  FirebaseFirestorePlatform delegateFor({
    required FirebaseApp app,
    required String databaseId,
  }) => this;
  @override
  CollectionReferencePlatform collection(String collectionPath) =>
      _Collection(this, collectionPath);
}

class _Collection extends CollectionReferencePlatform {
  _Collection(super.firestore, super.path);
  @override
  Stream<QuerySnapshotPlatform> snapshots({
    bool includeMetadataChanges = false,
    ListenSource listenSource = ListenSource.defaultSource,
  }) => Stream.error(StateError('Offline inventory fixture'));
}

final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FirebasePlatform oldCore;
  late FirebaseFirestorePlatform oldFirestore;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    oldCore = FirebasePlatform.instance;
    FirebasePlatform.instance = _Core();
    oldFirestore = FirebaseFirestorePlatform.instance;
    FirebaseFirestorePlatform.instance = _Firestore();
  });
  tearDown(() {
    FirebaseFirestorePlatform.instance = oldFirestore;
    FirebasePlatform.instance = oldCore;
  });

  for (final role in [CafeRole.owner, CafeRole.staff]) {
    testWidgets('Home forwards the same borrowed repository for ${role.name}', (
      tester,
    ) async {
      final session = e8Session(role: role);
      final first = E8SavedFixture(session);
      final next = E8SavedFixture(session);
      var current = first.repository;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return HomePage(
                workspaceSession: session,
                savedRecipesRepository: current,
              );
            },
          ),
        ),
      );
      final dashboard = tester.widget<DashboardPage>(
        find.byType(DashboardPage),
      );
      expect(dashboard.savedRecipesRepository, same(first.repository));
      final inventory = dashboard.inventoryRepository;
      final activity = dashboard.activityRepository;
      update(() => current = next.repository);
      await tester.pump();
      final replaced = tester.widget<DashboardPage>(find.byType(DashboardPage));
      expect(replaced.savedRecipesRepository, same(next.repository));
      expect(replaced.inventoryRepository, same(inventory));
      expect(replaced.activityRepository, same(activity));
      tester.widget<VeloraBottomBar>(find.byType(VeloraBottomBar)).onTap(3);
      // Finish Discover's asynchronous initialization before opening a route.
      // This offline inventory source completes with an error, not a spinner.
      await tester.pumpAndSettle();
      final discover = tester.widget<SuggestionsPage>(
        find.byType(SuggestionsPage),
      );
      expect(discover.savedRecipesRepository, same(next.repository));
      expect(discover.workspaceSession, same(session));
      await tester.tap(find.byKey(const ValueKey('discover-saved-recipes')));
      await tester.pumpAndSettle();
      expect(find.text('No active saved recipes.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester.widget<SuggestionsPage>(find.byType(SuggestionsPage)),
        same(discover),
      );
      next.populated = true;
      final entry = find.byKey(const ValueKey('discover-saved-recipes'));
      expect(tester.widget<TextButton>(entry).onPressed, isNotNull);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(next.operations, ['list', 'list']);
      expect(find.text('Cafe-shared library'), findsOneWidget);
      expect(find.text('Offline latte'), findsOneWidget);
      await tester.tap(find.text('View recipe: Offline latte'));
      await tester.pumpAndSettle();
      expect(find.text('Offline sample.'), findsOneWidget);
      expect(next.operations, ['list', 'list', 'get']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      // Both dependencies remain usable after borrowers have unmounted.
      await first.repository.list(mode: 'active', limit: 20);
      await next.repository.list(mode: 'active', limit: 20);
      expect(first.reconciles + next.reconciles, 0);
      await first.close();
      await next.close();
    });
  }

  testWidgets('Home defaults to unavailable Saved Recipes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(workspaceSession: e8Session())),
    );
    expect(
      tester
          .widget<DashboardPage>(find.byType(DashboardPage))
          .savedRecipesRepository,
      isNull,
    );
    tester.widget<VeloraBottomBar>(find.byType(VeloraBottomBar)).onTap(3);
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('discover-saved-recipes')),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Home rejects mismatched workspace and invalidates open library',
    (tester) async {
      final session = e8Session();
      final wrong = E8SavedFixture(e8Session());
      final matching = E8SavedFixture(session);
      var current = wrong.repository;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return HomePage(
                workspaceSession: session,
                savedRecipesRepository: current,
              );
            },
          ),
        ),
      );
      tester.widget<VeloraBottomBar>(find.byType(VeloraBottomBar)).onTap(3);
      await tester.pump();
      final entry = find.byKey(const ValueKey('discover-saved-recipes'));
      expect(tester.widget<TextButton>(entry).onPressed, isNull);
      expect(wrong.operations, isEmpty);
      update(() => current = matching.repository);
      await tester.pump();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('Cafe-shared library'), findsOneWidget);
      session.invalidate();
      matching.changes.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Cafe-shared library'), findsNothing);
      expect(tester.widget<TextButton>(entry).onPressed, isNull);
      await tester.pumpWidget(const MaterialApp(home: Text('Signed out')));
      await tester.pump();
      expect(find.byType(SuggestionsPage), findsNothing);
      expect(matching.reconciles, 0);
      await wrong.close();
      await matching.close();
    },
  );
}
