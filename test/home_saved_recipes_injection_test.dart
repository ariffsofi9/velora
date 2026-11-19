import 'package:velora/services/android_pilot_policy.dart';
// Test-only plugin delegates keep Home's existing inventory construction offline.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'package:velora/services/workspace_inventory_create_service.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';
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

InventoryHttpsSession _inventorySession(
  WorkspaceSession workspace, {
  String projectId = OfflineInventoryRest.projectId,
  bool verified = true,
}) => InventoryHttpsSession(
  workspace: workspace,
  uid: workspace.uid,
  projectId: projectId,
  emailVerified: verified,
  revision: 1,
);

WorkspaceInventoryCreateRequest _createRequest() =>
    WorkspaceInventoryCreateRequest(
      idempotencyKey: 'synthetic-request-0001',
      name: 'Synthetic item',
      category: 'Meat',
      quantity: 1,
      unit: 'kg',
      expiryDate: DateTime.utc(2027),
      imageUrl: '',
    );

http.Response _createResponse(String cafeId) => http.Response(
  jsonEncode({
    'cafeId': cafeId,
    'itemId': 'item_${List.filled(64, 'a').join()}',
    'created': true,
  }),
  200,
  headers: {'content-type': 'application/json'},
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

  testWidgets('Home requires a matching verified offline inventory transport', (
    tester,
  ) async {
    final workspace = e8Session();
    var dispatches = 0;
    for (final session in [
      null,
      _inventorySession(e8Session()),
      _inventorySession(workspace, projectId: 'velora-73222'),
      _inventorySession(workspace, verified: false),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            workspaceSession: workspace,
            offlineInventoryRest: session == null
                ? null
                : OfflineInventoryRest(
                    session: session,
                    respond: (_) async {
                      dispatches++;
                      return _createResponse(workspace.cafeId);
                    },
                  ),
          ),
        ),
      );
      final bottomBar = tester.widget<VeloraBottomBar>(
        find.byType(VeloraBottomBar),
      );
      bottomBar.onTap(1);
      await tester.pump();
      final inventory = tester.widget<InventoryPage>(
        find.byType(InventoryPage),
      );
      expect(inventory.inventoryCreator, isNull);
      expect(inventory.inventoryUpdater, isNull);
      expect(inventory.stockAdjuster, isNull);
      expect(inventory.lifecycleManager, isNull);
      bottomBar.onTap(2);
      await tester.pump();
      expect(find.byType(AddItemPage), findsNothing);
    }
    expect(dispatches, 0);
  });

  testWidgets('Home forwards one synthetic REST adapter to the inventory UI', (
    tester,
  ) async {
    final workspace = e8Session(role: CafeRole.staff);
    final requests = <http.Request>[];
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          workspaceSession: workspace,
          offlineInventoryRest: OfflineInventoryRest(
            session: _inventorySession(workspace),
            respond: (request) async {
              requests.add(request);
              return _createResponse(workspace.cafeId);
            },
          ),
        ),
      ),
    );
    final bottomBar = tester.widget<VeloraBottomBar>(
      find.byType(VeloraBottomBar),
    );
    bottomBar.onTap(1);
    await tester.pump();
    final inventory = tester.widget<InventoryPage>(find.byType(InventoryPage));
    final creator = inventory.inventoryCreator!;
    expect(creator, isA<HttpsWorkspaceInventory>());
    expect(inventory.inventoryUpdater, same(creator));
    expect(inventory.stockAdjuster, same(creator));
    expect(inventory.lifecycleManager, same(creator));
    bottomBar.onTap(2);
    await tester.pumpAndSettle();
    final add = tester.widget<AddItemPage>(find.byType(AddItemPage));
    expect(add.workspaceSession, same(workspace));
    expect(add.creator, same(creator));
    final request = _createRequest();
    await tester.runAsync(() async {
      final result = await add.creator!.createItem(request);
      expect(result.created, isTrue);
    });
    final sent = requests.single;
    expect(
      sent.url.toString(),
      'https://inventory.offline.invalid/inventory/create',
    );
    expect(sent.headers['authorization'], 'Bearer synthetic-inventory-token');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['expectedCafeId'], workspace.cafeId);
    expect(
      body['expectedMembershipGeneration'],
      workspace.membershipGeneration,
    );
    expect(body['idempotencyKey'], request.idempotencyKey);
  });

  testWidgets('Home replacement fences a pending synthetic acknowledgement', (
    tester,
  ) async {
    final original = e8Session();
    var workspace = original;
    late StateSetter replace;
    var dispatches = 0;
    late Completer<void> started;
    late Completer<http.Response> reply;
    final offline = OfflineInventoryRest(
      session: _inventorySession(original),
      respond: (_) {
        dispatches++;
        if (!started.isCompleted) started.complete();
        return reply.future;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            replace = setState;
            return HomePage(
              workspaceSession: workspace,
              offlineInventoryRest: offline,
            );
          },
        ),
      ),
    );
    tester.widget<VeloraBottomBar>(find.byType(VeloraBottomBar)).onTap(1);
    await tester.pump();
    final oldCreator = tester
        .widget<InventoryPage>(find.byType(InventoryPage))
        .inventoryCreator!;
    late Future<void> pending;
    await tester.runAsync(() async {
      started = Completer<void>();
      reply = Completer<http.Response>();
      pending = expectLater(
        oldCreator.createItem(_createRequest()),
        throwsA(
          isA<InventoryHttpsCreateException>()
              .having((e) => e.transport.code, 'code', 'session-changed')
              .having(
                (e) => e.transport.outcomeUnknown,
                'outcome unknown',
                true,
              ),
        ),
      );
      await started.future.timeout(const Duration(seconds: 5));
    });
    expect(dispatches, 1);
    replace(() => workspace = e8Session());
    await tester.pump();
    expect(original.isActive, isTrue);
    expect(
      tester.widget<InventoryPage>(find.byType(InventoryPage)).inventoryCreator,
      isNull,
    );
    await tester.runAsync(() async {
      reply.complete(_createResponse(original.cafeId));
      await pending;
      await expectLater(
        oldCreator.createItem(_createRequest()),
        throwsA(isA<InventoryHttpsCreateException>()),
      );
    });
    expect(dispatches, 1);
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
