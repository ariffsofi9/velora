import 'package:velora/services/android_pilot_policy.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/types.dart'
    show GetAllParameters;
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/repositories/workspace_saved_recipe_repository.dart'
    as saved;
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/recipe_suggestions_content.dart';

class _InventorySource implements WorkspaceInventoryDataSource {
  final Stream<List<WorkspaceInventoryDocument>> stream;
  String? watchedPath;
  int watches = 0;

  _InventorySource(this.stream);

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw UnimplementedError();

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watches++;
    watchedPath = path;
    return stream;
  }
}

final _session = WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'ai-cafe',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

WorkspaceInventoryDocument _item() => WorkspaceInventoryDocument(
  id: 'milk-a',
  data: {
    'name': 'Fresh Milk',
    'category': 'Dairy',
    'quantity': 1,
    'unit': 'L',
    'expiryDate': DateTime.now().add(const Duration(days: 1)),
    'imageUrl': '',
    'createdAt': DateTime.now(),
  },
);

Widget _app(_InventorySource source) => MaterialApp(
  theme: AppTheme.light,
  home: SuggestionsPage(
    workspaceSession: _session,
    repository: WorkspaceInventoryRepository(
      session: _session,
      dataSource: source,
    ),
  ),
);

final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reads only the verified cafe and renders scoped insights', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_item()]));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(source.watchedPath, 'cafes/ai-cafe/inventory');
    expect(find.text('Fresh Milk'), findsWidgets);
    expect(find.text('Smart Restock Suggestions'), findsOneWidget);
  });

  testWidgets('empty cafe shows normal inventory guidance', (tester) async {
    final source = _InventorySource(Stream.value(const []));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(
      find.text('Add inventory items first to get AI insights.'),
      findsOneWidget,
    );
    expect(find.textContaining('Inventory is unavailable'), findsNothing);
  });

  testWidgets('loading and repository errors remain distinguishable', (
    tester,
  ) async {
    final controller = StreamController<List<WorkspaceInventoryDocument>>();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(_InventorySource(controller.stream)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.addError(StateError('permission denied'));
    await tester.pump();
    expect(
      find.text(
        'Inventory is unavailable. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('unsafe AI actions are visibly disabled and do not run', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_item()]));

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Generate Recipes'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Restock Advice'),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.textContaining('Recipe generation is not available yet'),
      findsOneWidget,
    );
  });

  testWidgets('missing verified context fails closed without inventory access', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const SuggestionsPage()),
    );

    expect(
      find.text(
        'AI Insights is unavailable because workspace access was not verified.',
      ),
      findsOneWidget,
    );
  });
  for (final role in CafeRole.values) {
    testWidgets('${role.name} verified context is accepted', (tester) async {
      final session = _context(role: role);
      final source = _InventorySource(Stream.value([_item()]));
      final repo = WorkspaceInventoryRepository(
        session: session,
        dataSource: source,
      );
      await tester.pumpWidget(_page(session, repo));
      await tester.pumpAndSettle();
      expect(source.watchedPath, 'cafes/ai-cafe/inventory');
      expect(find.text('Fresh Milk'), findsWidgets);
    });
  }

  testWidgets('mismatched and missing page sessions never subscribe', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_item()]));
    final repo = WorkspaceInventoryRepository(
      session: _context(),
      dataSource: source,
    );
    for (final session in [_context(), null]) {
      await tester.pumpWidget(_page(session, repo));
      await tester.pumpAndSettle();
      expect(source.watches, 0);
      expect(find.text('Fresh Milk'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    }
  });

  for (final change in ['identity', 'account', 'cafe', 'generation']) {
    for (final populated in [false, true]) {
      testWidgets(
        '$change replacement clears ${populated ? 'published' : 'pending'} inventory and child state',
        (tester) async {
          final oldEvents =
              StreamController<List<WorkspaceInventoryDocument>>();
          final newEvents =
              StreamController<List<WorkspaceInventoryDocument>>();
          final oldSession = _context();
          final nextSession = _context(
            uid: change == 'account' ? 'other-user' : 'staff-a',
            cafe: change == 'cafe' ? 'other-cafe' : 'ai-cafe',
            generation: change == 'generation' ? 2 : 1,
          );
          final oldRepo = WorkspaceInventoryRepository(
            session: oldSession,
            dataSource: _InventorySource(oldEvents.stream),
          );
          final nextSource = _InventorySource(newEvents.stream);
          final nextRepo = WorkspaceInventoryRepository(
            session: nextSession,
            dataSource: nextSource,
          );
          await tester.pumpWidget(_page(oldSession, oldRepo));
          if (populated) {
            oldEvents.add([_item()]);
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('preview-sample-recipes')),
            );
            await tester.pumpAndSettle();
            expect(find.byType(RecipeDemoResult), findsOneWidget);
          }
          await tester.pumpWidget(_page(nextSession, nextRepo));
          expect(find.text('Fresh Milk'), findsNothing);
          expect(find.byType(RecipeDemoResult), findsNothing);
          oldEvents.add([_item()]);
          await tester.pump();
          expect(find.text('Fresh Milk'), findsNothing);
          newEvents.add(const []);
          await tester.pumpAndSettle();
          expect(
            find.text('Add inventory items first to get AI insights.'),
            findsOneWidget,
          );
          expect(find.byType(RecipeDemoResult), findsNothing);
          expect(nextSource.watches, 1);
          expect(
            nextSource.watchedPath,
            'cafes/${nextSession.cafeId}/inventory',
          );
          await tester.pumpWidget(const SizedBox());
          unawaited(oldEvents.close());
          unawaited(newEvents.close());
        },
      );
    }
  }

  testWidgets('replacement with old repository fails closed', (tester) async {
    final session = _context();
    final source = _InventorySource(Stream.value([_item()]));
    final repo = WorkspaceInventoryRepository(
      session: session,
      dataSource: source,
    );
    await tester.pumpWidget(_page(session, repo));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_page(_context(), repo));
    await tester.pumpAndSettle();
    expect(find.text('Fresh Milk'), findsNothing);
    expect(source.watches, 1);
  });

  for (final populated in [false, true]) {
    testWidgets(
      'invalidated context hides ${populated ? 'published' : 'pending'} insights and cannot retry',
      (tester) async {
        final events = StreamController<List<WorkspaceInventoryDocument>>();
        final session = _context();
        final source = _InventorySource(events.stream);
        final repo = WorkspaceInventoryRepository(
          session: session,
          dataSource: source,
        );
        await tester.pumpWidget(_page(session, repo));
        if (populated) {
          events.add([_item()]);
          await tester.pumpAndSettle();
        }
        session.invalidate();
        events.add([_item()]);
        await tester.pumpWidget(_page(session, repo));
        await tester.pumpAndSettle();
        expect(find.text('Fresh Milk'), findsNothing);
        expect(find.text('Retry'), findsNothing);
        expect(source.watches, 1);
        await tester.pumpWidget(const SizedBox());
        unawaited(events.close());
      },
    );
  }

  testWidgets(
    'retry uses replacement context and never accumulates listeners',
    (tester) async {
      final first = _context();
      final next = _context(cafe: 'other-cafe');
      final oldSource = _RetrySource();
      final newSource = _RetrySource();
      final oldRepo = WorkspaceInventoryRepository(
        session: first,
        dataSource: oldSource,
      );
      final newRepo = WorkspaceInventoryRepository(
        session: next,
        dataSource: newSource,
      );
      await tester.pumpWidget(_page(first, oldRepo));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.pumpWidget(_page(next, newRepo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Fresh Milk'), findsWidgets);
      expect(oldSource.paths, ['cafes/ai-cafe/inventory']);
      expect(newSource.paths, [
        'cafes/other-cafe/inventory',
        'cafes/other-cafe/inventory',
      ]);
      expect(oldSource.active, 0);
      expect(newSource.active, 1);
      expect(newSource.maximum, 1);
      await tester.pumpWidget(_page(next, newRepo));
      await tester.pumpAndSettle();
      expect(newSource.paths.length, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(newSource.active, 0);
    },
  );

  testWidgets('captured Retry refuses invalidated sessions', (tester) async {
    final session = _context();
    final source = _RetrySource();
    final repo = WorkspaceInventoryRepository(
      session: session,
      dataSource: source,
    );
    await tester.pumpWidget(_page(session, repo));
    await tester.pumpAndSettle();
    final retry = tester
        .widget<OutlinedButton>(
          find.byKey(const ValueKey('discover-inventory-retry')),
        )
        .onPressed!;
    session.invalidate();
    retry();
    await tester.pump();
    expect(source.paths.length, 1);
    expect(find.text('Fresh Milk'), findsNothing);
  });

  testWidgets('logout removes pending workspace content', (tester) async {
    final events = StreamController<List<WorkspaceInventoryDocument>>();
    final session = _context();
    await tester.pumpWidget(
      _page(
        session,
        WorkspaceInventoryRepository(
          session: session,
          dataSource: _InventorySource(events.stream),
        ),
      ),
    );
    session.invalidate();
    await tester.pumpWidget(const MaterialApp(home: Text('Signed out')));
    events.add([_item()]);
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('Fresh Milk'), findsNothing);
    expect(tester.takeException(), isNull);
    unawaited(events.close());
  });

  testWidgets('Saved Recipes is unavailable without an injected repository', (
    tester,
  ) async {
    final source = _InventorySource(Stream.value([_item()]));
    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    final entry = tester.widget<TextButton>(
      find.byKey(const ValueKey('discover-saved-recipes')),
    );
    expect(entry.onPressed, isNull);
    expect(find.text('Fresh Milk'), findsWidgets);
  });

  for (final role in [CafeRole.owner, CafeRole.staff]) {
    testWidgets('Saved Recipes opens read-only library for ${role.name}', (
      tester,
    ) async {
      final session = _context(role: role);
      final fixture = _SavedRecipeFixture(session);
      final source = _InventorySource(Stream.value([_item()]));
      await tester.pumpWidget(_savedPage(session, source, fixture.repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('discover-saved-recipes')));
      await tester.pumpAndSettle();
      expect(find.text('Cafe-shared library'), findsOneWidget);
      expect(fixture.reads, 1);
      expect(fixture.reconciles, 0);
      expect(find.text('Save'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Fresh Milk'), findsWidgets);
      expect(source.watches, 1);
      await _unmountAndDispose(tester, [fixture]);
    });
  }

  testWidgets('mismatched workspace repository fails closed', (tester) async {
    final session = _context();
    final fixture = _SavedRecipeFixture(_context());
    await tester.pumpWidget(
      _savedPage(
        session,
        _InventorySource(Stream.value([_item()])),
        fixture.repository,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('discover-saved-recipes')),
          )
          .onPressed,
      isNull,
    );
    expect(fixture.reads, 0);
    await _unmountAndDispose(tester, [fixture]);
  });

  testWidgets('early Saved Recipes navigation reopens after initialization', (
    tester,
  ) async {
    final originalStore = SharedPreferencesStorePlatform.instance;
    final preferences = _PendingPreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    addTearDown(() {
      if (!preferences.pending.isCompleted) preferences.pending.complete({});
      SharedPreferencesStorePlatform.instance = originalStore;
    });
    final session = _context();
    final fixture = _SavedRecipeFixture(session);
    final source = _InventorySource(Stream.value([_item()]));
    await tester.pumpWidget(_savedPage(session, source, fixture.repository));
    expect(preferences.started, isTrue);
    expect(preferences.pending.isCompleted, isFalse);
    final discoverState = tester.state(find.byType(SuggestionsPage));
    final entry = find.byKey(const ValueKey('discover-saved-recipes'));
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(fixture.reads, 1);
    expect(find.text('Cafe-shared library'), findsOneWidget);

    // Complete initialization while the navigation busy flag is still true.
    preferences.pending.complete({});
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(
              const ValueKey('discover-saved-recipes'),
              skipOffstage: false,
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(SuggestionsPage)), same(discoverState));
    expect(tester.widget<TextButton>(entry).onPressed, isNotNull);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('Cafe-shared library'), findsOneWidget);
    expect(fixture.reads, 2);
    expect(fixture.reconciles, 0);
    expect(source.watches, 1);
    fixture.invalidate();
    await tester.pumpAndSettle();
    expect(find.text('Cafe-shared library'), findsNothing);
    expect(tester.widget<TextButton>(entry).onPressed, isNull);
    await _unmountAndDispose(tester, [fixture]);
  });

  testWidgets('destination loading, empty, and read failure remain read-only', (
    tester,
  ) async {
    final session = _context();
    final loading = Completer<Object?>();
    final fixture = _SavedRecipeFixture(
      session,
      response: () => loading.future,
    );
    await tester.pumpWidget(
      _savedPage(
        session,
        _InventorySource(Stream.value([_item()])),
        fixture.repository,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('discover-saved-recipes')));
    // The pending read keeps the progress indicator animating. Settle only the
    // route transition so pumpAndSettle cannot advance to the read timeout.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(loading.isCompleted, isFalse);
    expect(fixture.reads, 1);
    expect(find.textContaining('Loading saved recipes'), findsOneWidget);
    loading.complete(_savedList(const []));
    await tester.pumpAndSettle();
    expect(find.text('No active saved recipes.'), findsOneWidget);
    expect(fixture.reconciles, 0);

    final failing = _SavedRecipeFixture(
      session,
      response: () => throw StateError('offline'),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _savedPage(
        session,
        _InventorySource(Stream.value([_item()])),
        failing.repository,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('discover-saved-recipes')));
    await tester.pumpAndSettle();
    expect(
      find.text('Saved recipes could not be loaded. Please try again.'),
      findsOneWidget,
    );
    expect(failing.reconciles, 0);
    await _unmountAndDispose(tester, [fixture, failing]);
  });

  testWidgets('session, parent, and repository replacement close open routes', (
    tester,
  ) async {
    final session = _context();
    final fixture = _SavedRecipeFixture(session);
    final source = _InventorySource(Stream.value([_item()]));
    final inventory = WorkspaceInventoryRepository(
      session: session,
      dataSource: source,
    );
    var activeSession = session;
    var activeInventory = inventory;
    var activeSavedRecipes = fixture.repository;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return SuggestionsPage(
              workspaceSession: activeSession,
              repository: activeInventory,
              savedRecipesRepository: activeSavedRecipes,
            );
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('discover-saved-recipes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View recipe: Iced Latte'));
    await tester.pumpAndSettle();
    expect(find.text('Iced Latte'), findsWidgets);

    fixture.invalidate();
    await tester.pumpAndSettle();
    expect(find.text('Cafe-shared library'), findsNothing);
    expect(find.text('Fresh Milk'), findsWidgets);

    final replacement = _SavedRecipeFixture(session);
    update(() => activeSavedRecipes = replacement.repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('discover-saved-recipes')));
    await tester.pumpAndSettle();
    final swapped = _SavedRecipeFixture(session);
    update(() => activeSavedRecipes = swapped.repository);
    await tester.pumpAndSettle();
    expect(find.text('Cafe-shared library'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('discover-saved-recipes')));
    await tester.pumpAndSettle();
    final otherSession = _context(cafe: 'other-cafe');
    final otherInventory = WorkspaceInventoryRepository(
      session: otherSession,
      dataSource: _InventorySource(Stream.value([_item()])),
    );
    update(() {
      activeSession = otherSession;
      activeInventory = otherInventory;
    });
    await tester.pumpAndSettle();
    expect(find.text('Cafe-shared library'), findsNothing);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('discover-saved-recipes')),
          )
          .onPressed,
      isNull,
    );
    await _unmountAndDispose(tester, [fixture, replacement, swapped]);
  });

  testWidgets('rapid Saved Recipes taps produce one read-only route', (
    tester,
  ) async {
    final session = _context();
    final fixture = _SavedRecipeFixture(session);
    await tester.pumpWidget(
      _savedPage(
        session,
        _InventorySource(Stream.value([_item()])),
        fixture.repository,
      ),
    );
    final entry = find.byKey(const ValueKey('discover-saved-recipes'));
    final open = tester.widget<TextButton>(entry).onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    expect(find.text('Cafe-shared library'), findsOneWidget);
    expect(fixture.reads, 1);
    expect(fixture.reconciles, 0);
    await _unmountAndDispose(tester, [fixture]);
  });
}

WorkspaceSession _context({
  String cafe = 'ai-cafe',
  String uid = 'staff-a',
  int generation = 1,
  CafeRole role = CafeRole.staff,
}) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafe,
    uid: role == CafeRole.owner ? 'owner-a' : uid,
    ownerUid: 'owner-a',
    role: role,
    membershipGeneration: generation,
  ),
);

Widget _page(WorkspaceSession? session, WorkspaceInventoryRepository repo) =>
    MaterialApp(
      theme: AppTheme.light,
      home: SuggestionsPage(workspaceSession: session, repository: repo),
    );

class _RetrySource implements WorkspaceInventoryDataSource {
  final paths = <String>[];
  int active = 0, maximum = 0;
  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw StateError('Unexpected read');
  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    paths.add(path);
    final fail = paths.length == 1;
    late StreamController<List<WorkspaceInventoryDocument>> controller;
    controller = StreamController(
      onListen: () {
        active++;
        if (active > maximum) maximum = active;
        if (fail) {
          controller.addError(StateError('private backend detail'));
        } else {
          controller.add([_item()]);
        }
      },
      onCancel: () {
        active--;
      },
    );
    return controller.stream;
  }
}

Widget _savedPage(
  WorkspaceSession session,
  _InventorySource source,
  saved.WorkspaceSavedRecipeRepository repository,
) => MaterialApp(
  theme: AppTheme.light,
  home: SuggestionsPage(
    workspaceSession: session,
    repository: WorkspaceInventoryRepository(
      session: session,
      dataSource: source,
    ),
    savedRecipesRepository: repository,
  ),
);

class _SavedRecipeFixture
    implements saved.SavedRecipeReadPort, saved.SavedRecipeObservationPort {
  final WorkspaceSession workspace;
  final StreamController<saved.SavedRecipeSession?> _changes =
      StreamController<saved.SavedRecipeSession?>.broadcast(sync: true);
  final Future<Object?> Function()? response;
  late final saved.SavedRecipeSession session;
  late final saved.WorkspaceSavedRecipeRepository repository;
  int reads = 0, reconciles = 0;

  _SavedRecipeFixture(this.workspace, {this.response}) {
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
      sessionChanges: _changes.stream,
    );
  }

  @override
  Future<Object?> read(
    saved.SavedRecipeSession requestSession,
    String operation,
    Map<String, Object?> request,
  ) async {
    reads++;
    if (response != null) return response!();
    if (operation == 'list') return _savedList([_savedSummary()]);
    return _savedGet();
  }

  @override
  Future<Object?> reconcile(
    saved.SavedRecipeSession requestSession,
    Map<String, Object?> request,
  ) async {
    reconciles++;
    throw StateError('Reconciliation must not be dispatched by this bridge.');
  }

  void invalidate() => _changes.add(null);
  Future<void> dispose() =>
      _changes.isClosed ? Future.value() : _changes.close();
}

class _PendingPreferences extends InMemorySharedPreferencesStore {
  _PendingPreferences() : super.empty();
  final pending = Completer<Map<String, Object>>();
  bool started = false;
  @override
  Future<Map<String, Object>> getAll() {
    started = true;
    return pending.future;
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => getAll();
}

Future<void> _unmountAndDispose(
  WidgetTester tester,
  Iterable<_SavedRecipeFixture> fixtures,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  for (final fixture in fixtures) {
    await fixture.dispose();
  }
}

Map<String, Object?> _savedList(List<Object?> items) => {
  'schemaVersion': 1,
  'cafeId': 'ai-cafe',
  'items': items,
  'nextCursor': null,
};

Map<String, Object?> _savedSummary() => {
  'recipeId': 'recipe_${'a' * 64}',
  'title': 'Iced Latte',
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

Map<String, Object?> _savedRecipe() => {
  'schemaVersion': 1,
  'projectId': 'velora-spark-test',
  'cafeId': 'ai-cafe',
  'recipeId': 'recipe_${'a' * 64}',
  'contentDigest': 'b' * 64,
  'recipe': {
    'title': 'Iced Latte',
    'ingredients': [
      {'itemId': 'milk-a', 'quantity': 1, 'unit': 'L'},
    ],
    'steps': ['Mix and serve.'],
    'whyRecommended': 'Uses the current cafe inventory.',
  },
  'source': 'workspace-submitted',
  'provenanceEvidence': 'unverified-attribution',
  'submittedAttribution': {
    'kind': 'sample',
    'provider': null,
    'ticketId': null,
  },
  'createdBy': 'staff-a',
  'updatedBy': 'staff-a',
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': '2026-01-01T00:00:00.000Z',
  'version': 1,
  'isArchived': false,
  'archivedBy': null,
  'archivedAt': null,
};

Map<String, Object?> _savedGet() => {
  'schemaVersion': 1,
  'cafeId': 'ai-cafe',
  'item': _savedRecipe(),
};
