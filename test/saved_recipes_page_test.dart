import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_saved_recipe_repository.dart'
    hide SavedRecipesPage;
import 'package:velora/screens/suggestions/saved_recipes_page.dart';
import 'package:velora/services/workspace_session.dart';

String id(int i) => 'recipe_${i.toRadixString(16).padLeft(64, '0')}';
const instant = '2026-11-12T00:00:00.000Z';
Map<String, Object?> attribution(String kind) => {
  'kind': kind,
  'provider': kind == 'claimed-ai' ? 'groq' : null,
  'ticketId': null,
};
Map<String, Object?> summary(
  int i, {
  bool archived = false,
  String kind = 'claimed-ai',
}) => {
  'recipeId': id(i),
  'title': 'Recipe $i',
  'source': 'workspace-submitted',
  'provenanceEvidence': 'unverified-attribution',
  'submittedAttribution': attribution(kind),
  'version': archived ? 2 : 1,
  'isArchived': archived,
  'createdAt': instant,
  'updatedAt': instant,
};
Map<String, Object?> record(
  int i, {
  bool archived = false,
  String kind = 'claimed-ai',
  String cafe = 'cafe',
}) => {
  'schemaVersion': 1,
  'projectId': 'velora-spark-test',
  'cafeId': cafe,
  'recipeId': id(i),
  'contentDigest': 'a' * 64,
  'recipe': {
    'title': 'Full recipe $i',
    'ingredients': [
      {'itemId': 'ingredient-id', 'quantity': 0.125, 'unit': 'L'},
    ],
    'steps': ['First canonical step.', 'Second canonical step.'],
    'whyRecommended': 'Canonical recommendation.',
  },
  'source': 'workspace-submitted',
  'provenanceEvidence': 'unverified-attribution',
  'submittedAttribution': attribution(kind),
  'createdBy': 'owner',
  'updatedBy': 'owner',
  'createdAt': instant,
  'updatedAt': instant,
  'version': archived ? 2 : 1,
  'isArchived': archived,
  'archivedBy': archived ? 'owner' : null,
  'archivedAt': archived ? instant : null,
};
SavedRecipeSession session({
  String cafe = 'cafe',
  int generation = 7,
  String uid = 'owner',
  int revision = 0,
}) => SavedRecipeSession(
  projectId: 'velora-spark-test',
  uid: uid,
  revision: revision,
  emailVerified: true,
  workspace: WorkspaceSession.fromVerified(
    CafeWorkspace(
      cafeId: cafe,
      uid: uid,
      ownerUid: 'owner',
      role: uid == 'owner' ? CafeRole.owner : CafeRole.staff,
      membershipGeneration: generation,
    ),
  ),
);

class Ports implements SavedRecipeReadPort, SavedRecipeObservationPort {
  final calls = <Map<String, Object?>>[];
  int observations = 0;
  Future<Object?> Function(String, Map<String, Object?>)? hook;
  @override
  Future<Object?> read(
    SavedRecipeSession session,
    String operation,
    Map<String, Object?> request,
  ) async {
    calls.add({'operation': operation, 'request': request});
    if (hook != null) {
      return await hook!(operation, request);
    }
    if (operation == 'get') {
      return {'schemaVersion': 1, 'cafeId': 'cafe', 'item': record(1)};
    }
    return page([summary(1, archived: request['mode'] == 'archived')]);
  }

  @override
  Future<Object?> reconcile(
    SavedRecipeSession session,
    Map<String, Object?> request,
  ) async {
    observations++;
    throw StateError('UI must not observe receipts');
  }
}

Map<String, Object?> page(
  List<Map<String, Object?>> items, {
  Map<String, Object?>? cursor,
}) => {
  'schemaVersion': 1,
  'cafeId': 'cafe',
  'items': items,
  'nextCursor': cursor,
};
Map<String, Object?> cursor() => {
  'schemaVersion': 1,
  'projectId': 'velora-spark-test',
  'cafeId': 'cafe',
  'uid': 'owner',
  'membershipGeneration': 7,
  'mode': 'active',
  'limit': 20,
  'afterId': id(20),
};

class Fixture {
  final ports = Ports();
  final changes = StreamController<SavedRecipeSession?>.broadcast(sync: true);
  SavedRecipeSession? current = session();
  late final WorkspaceSavedRecipeRepository repository;
  Fixture({String uid = 'owner'}) {
    current = session(uid: uid);
    repository = WorkspaceSavedRecipeRepository(
      readPort: ports,
      observationPort: ports,
      currentSession: () => current,
      sessionChanges: changes.stream,
    );
    addTearDown(() async {
      expect(ports.observations, 0);
      expect(
        ports.calls.every((c) => ['list', 'get'].contains(c['operation'])),
        true,
      );
      await repository.dispose();
      await changes.close();
    });
  }
}

Widget app(Fixture f, {double scale = 1}) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: SavedRecipesPage(repository: f.repository),
);
Future<void> visible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 600, maxScrolls: 100);
  await tester.pump();
}

Future<void> open(WidgetTester tester) async {
  final button = find.text('View recipe: Recipe 1');
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'replacement under an open detail route clears its rendered data',
    (tester) async {
      final a = Fixture(), b = Fixture();
      final selected = ValueNotifier(a.repository);
      addTearDown(selected.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: ValueListenableBuilder<WorkspaceSavedRecipeRepository>(
            valueListenable: selected,
            builder: (_, repository, _) =>
                SavedRecipesPage(repository: repository),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await open(tester);
      expect(find.text('Full recipe 1'), findsOneWidget);
      selected.value = b.repository;
      await tester.pumpAndSettle();
      expect(find.text('Full recipe 1'), findsNothing);
      expect(
        find.text('Workspace access changed. Reopen Saved Recipes.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'closing pending detail suppresses late results and leaves repository usable',
    (tester) async {
      final f = Fixture(), pending = Completer<Object?>();
      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();
      f.ports.hook = (_, _) => pending.future;
      await tester.tap(find.text('View recipe: Recipe 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pageBack();
      await tester.pumpAndSettle();
      pending.complete({
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'item': record(1),
      });
      await tester.pumpAndSettle();
      expect(find.text('Full recipe 1'), findsNothing);
      expect(find.text('Recipe 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      f.ports.hook = null;
      expect((await f.repository.get(id(1))).recipeId, id(1));
    },
  );
  testWidgets('context change without a frame cannot authorize a detail tap', (
    tester,
  ) async {
    final f = Fixture();
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();
    f.current = session();
    await tester.tap(find.text('View recipe: Recipe 1'));
    await tester.pumpAndSettle();
    expect(f.ports.calls.length, 1);
    expect(find.text('Recipe 1'), findsNothing);
    expect(
      find.text('Workspace access changed. Reopen Saved Recipes.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'foreign detail response is rejected without rendering its content',
    (tester) async {
      final f = Fixture();
      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();
      f.ports.hook = (_, _) async => {
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'item': record(1, cafe: 'foreign'),
      };
      await open(tester);
      expect(find.text('Full recipe 1'), findsNothing);
      expect(
        find.text('Recipe details could not be loaded. Please try again.'),
        findsOneWidget,
      );
    },
  );
  testWidgets('initial loading is bounded to one explicit Active list read', (
    tester,
  ) async {
    final f = Fixture(), pending = Completer<Object?>();
    f.ports.hook = (_, _) => pending.future;
    await tester.pumpWidget(app(f));
    await tester.pump();
    expect(find.text('Loading saved recipes…'), findsOneWidget);
    expect(f.ports.calls.length, 1);
    expect(f.ports.calls.single['request'], {
      'expectedCafeId': 'cafe',
      'expectedMembershipGeneration': 7,
      'mode': 'active',
      'limit': 20,
      'cursor': null,
    });
    pending.complete(page([summary(1)]));
    await tester.pumpAndSettle();
    expect(find.text('Recipe 1'), findsOneWidget);
  });
  for (final uid in ['owner', 'staff']) {
    testWidgets(
      '$uid can browse Active, Archived and All with mode-specific empty states',
      (tester) async {
        final f = Fixture(uid: uid);
        f.ports.hook = (_, _) async => page([]);
        await tester.pumpWidget(app(f));
        await tester.pumpAndSettle();
        expect(find.text('No active saved recipes.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('saved-filter-archived')));
        await tester.pumpAndSettle();
        expect(find.text('No archived saved recipes.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('saved-filter-all')));
        await tester.pumpAndSettle();
        expect(find.text('No saved recipes yet.'), findsOneWidget);
        expect(f.ports.calls.map((c) => (c['request'] as Map)['mode']), [
          'active',
          'archived',
          'all',
        ]);
      },
    );
  }
  testWidgets(
    'initial read error is sanitized and retries only on explicit action',
    (tester) async {
      final f = Fixture();
      f.ports.hook = (_, _) async => throw StateError('SECRET_RAW_TOKEN');
      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();
      expect(find.textContaining('SECRET_RAW_TOKEN'), findsNothing);
      expect(f.ports.calls.length, 1);
      f.ports.hook = null;
      await tester.tap(find.byKey(const ValueKey('saved-read-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Recipe 1'), findsOneWidget);
      expect(f.ports.calls.length, 2);
    },
  );
  testWidgets(
    'pagination is explicit; failure preserves rows and retry uses unchanged cursor',
    (tester) async {
      final f = Fixture(), pending = Completer<Object?>();
      f.ports.hook = (_, request) async => request['cursor'] == null
          ? page(List.generate(20, (i) => summary(i + 1)), cursor: cursor())
          : pending.future;
      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();
      expect(f.ports.calls.length, 1);
      await visible(tester, find.byKey(const ValueKey('saved-load-more')));
      await tester.tap(find.byKey(const ValueKey('saved-load-more')));
      await tester.pump();
      expect(f.ports.calls.last['operation'], 'list');
      expect(f.ports.calls.length, 2);
      await visible(tester, find.text('Loading more recipes…'));
      expect(find.text('Loading more recipes…'), findsOneWidget);
      pending.completeError(StateError('private'));
      await tester.pumpAndSettle();
      expect(find.text('Recipe 20'), findsOneWidget);
      final retry = find.byKey(const ValueKey('saved-read-retry'));
      await visible(tester, retry);
      f.ports.hook = (_, _) async => page([summary(21)]);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect((f.ports.calls[1]['request'] as Map)['cursor'], cursor());
      expect(f.ports.calls[2]['request'], f.ports.calls[1]['request']);
      await visible(tester, find.text('Recipe 21'));
      expect(find.text('Recipe 21'), findsOneWidget);
      expect(f.ports.calls.length, 3);
      expect(find.byKey(const ValueKey('saved-load-more')), findsNothing);
    },
  );
  testWidgets(
    'details perform get, show canonical content and omit invented fields',
    (tester) async {
      final f = Fixture();
      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();
      await open(tester);
      expect(f.ports.calls.last['operation'], 'get');
      expect((f.ports.calls.last['request'] as Map)['recipeId'], id(1));
      expect(find.text('Full recipe 1'), findsOneWidget);
      expect(
        find.text('Workspace-submitted recipe; AI origin not verified.'),
        findsOneWidget,
      );
      expect(find.text('Canonical recommendation.'), findsOneWidget);
      await visible(tester, find.textContaining('ingredient-id'));
      expect(find.textContaining('0.125 L'), findsOneWidget);
      await visible(tester, find.text('2. Second canonical step.'));
      expect(find.text('1. First canonical step.'), findsOneWidget);
      await visible(tester, find.text('Version: 1'));
      expect(find.text('Version: 1'), findsOneWidget);
      for (final forbidden in [
        'Cook Now',
        'Save',
        'Restore',
        'Delete',
        'Servings',
        'Cooking time',
        'Validated AI recipe',
      ]) {
        expect(find.text(forbidden), findsNothing);
      }
    },
  );
  for (final kind in ['sample', 'mock']) {
    testWidgets(
      '$kind attribution survives list and detail without AI promotion',
      (tester) async {
        final f = Fixture();
        f.ports.hook = (op, _) async => op == 'list'
            ? page([summary(1, kind: kind)])
            : {
                'schemaVersion': 1,
                'cafeId': 'cafe',
                'item': record(1, kind: kind),
              };
        await tester.pumpWidget(app(f));
        await tester.pumpAndSettle();
        expect(
          find.text(kind == 'sample' ? 'Sample recipe' : 'Mock recipe'),
          findsOneWidget,
        );
        await open(tester);
        expect(find.text('Submitted attribution: $kind'), findsOneWidget);
        expect(find.text('Validated AI recipe'), findsNothing);
      },
    );
  }
  testWidgets('archived detail retains status and archive actor/time', (
    tester,
  ) async {
    final f = Fixture();
    f.ports.hook = (op, _) async => op == 'list'
        ? page([summary(1, archived: true)])
        : {
            'schemaVersion': 1,
            'cafeId': 'cafe',
            'item': record(1, archived: true),
          };
    f.ports.hook = (_, _) async => page([]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();
    f.ports.hook = (op, _) async => op == 'list'
        ? page([summary(1, archived: true)])
        : {
            'schemaVersion': 1,
            'cafeId': 'cafe',
            'item': record(1, archived: true),
          };
    await tester.tap(find.byKey(const ValueKey('saved-filter-archived')));
    await tester.pumpAndSettle();
    await open(tester);
    expect(find.text('Archived'), findsOneWidget);
    await visible(tester, find.text('Archived by: owner'));
    await visible(tester, find.text('Archived (UTC): $instant'));
    expect(find.text('Archived (UTC): $instant'), findsOneWidget);
    expect(find.text('Version: 2'), findsOneWidget);
  });
  testWidgets('detail loading, read error and explicit detail retry', (
    tester,
  ) async {
    final f = Fixture(), pending = Completer<Object?>();
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();
    f.ports.hook = (_, _) => pending.future;
    await tester.tap(find.text('View recipe: Recipe 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Loading recipe details…'), findsOneWidget);
    pending.completeError(
      const SavedRecipeException(SavedRecipeFailure.notFound),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('This saved recipe is no longer available.'),
      findsOneWidget,
    );
    f.ports.hook = null;
    await tester.tap(find.byKey(const ValueKey('saved-detail-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Full recipe 1'), findsOneWidget);
  });
  for (final mode in [
    'replacement',
    'cafe',
    'generation',
    'logout',
    'error',
    'done',
  ]) {
    testWidgets('$mode clears rendered library and blocks later actions', (
      tester,
    ) async {
      final f = Fixture();
      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();
      switch (mode) {
        case 'replacement':
          f.current = session();
          f.changes.add(f.current);
        case 'cafe':
          f.current = session(cafe: 'other');
          f.changes.add(f.current);
        case 'generation':
          f.current = session(generation: 8);
          f.changes.add(f.current);
        case 'logout':
          f.current = null;
          f.changes.add(null);
        case 'error':
          f.changes.addError(StateError('private'));
        case 'done':
          await tester.runAsync(() => f.changes.close());
      }
      await tester.pumpAndSettle();
      expect(find.text('Recipe 1'), findsNothing);
      expect(
        find.text('Workspace access changed. Reopen Saved Recipes.'),
        findsOneWidget,
      );
      expect(f.ports.calls.length, 1);
    });
  }
  for (final pendingDetail in [false, true]) {
    testWidgets(
      'invalidation hides open details pending=$pendingDetail and rejects late completion',
      (tester) async {
        final f = Fixture(), pending = Completer<Object?>();
        await tester.pumpWidget(app(f));
        await tester.pumpAndSettle();
        if (pendingDetail) f.ports.hook = (_, _) => pending.future;
        await tester.tap(find.text('View recipe: Recipe 1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        f.current = session(cafe: 'other');
        f.changes.add(f.current);
        await tester.pumpAndSettle();
        if (pendingDetail) {
          pending.complete({
            'schemaVersion': 1,
            'cafeId': 'cafe',
            'item': record(1),
          });
          await tester.pumpAndSettle();
        }
        expect(find.text('Full recipe 1'), findsNothing);
        expect(find.textContaining('ingredient-id'), findsNothing);
        expect(
          find.text('Workspace access changed. Reopen Saved Recipes.'),
          findsOneWidget,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Recipe 1'), findsNothing);
      },
    );
  }
  testWidgets('late old-filter response cannot replace current mode', (
    tester,
  ) async {
    final f = Fixture(), pending = Completer<Object?>();
    f.ports.hook = (_, request) async => request['mode'] == 'active'
        ? pending.future
        : page([summary(2, archived: true)]);
    await tester.pumpWidget(app(f));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('saved-filter-archived')));
    await tester.pumpAndSettle();
    pending.complete(page([summary(1)]));
    await tester.pumpAndSettle();
    expect(find.text('Recipe 2'), findsOneWidget);
    expect(find.text('Recipe 1'), findsNothing);
    expect((f.ports.calls.last['request'] as Map)['cursor'], null);
  });
  testWidgets(
    'repository replacement rejects old pending result and keeps caller ownership',
    (tester) async {
      final a = Fixture(), b = Fixture(), pending = Completer<Object?>();
      a.ports.hook = (_, _) => pending.future;
      b.ports.hook = (_, _) async => page([summary(2)]);
      await tester.pumpWidget(app(a));
      await tester.pump();
      await tester.pumpWidget(app(b));
      await tester.pumpAndSettle();
      pending.complete(page([summary(1)]));
      await tester.pumpAndSettle();
      expect(find.text('Recipe 2'), findsOneWidget);
      expect(find.text('Recipe 1'), findsNothing);
      a.ports.hook = null;
      expect((await a.repository.get(id(1))).recipeId, id(1));
    },
  );
  testWidgets(
    'disposal during a read ignores completion without disposing caller repository',
    (tester) async {
      final f = Fixture(), pending = Completer<Object?>();
      f.ports.hook = (_, _) => pending.future;
      await tester.pumpWidget(app(f));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete(page([summary(1)]));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      f.ports.hook = null;
      expect((await f.repository.get(id(1))).recipeId, id(1));
    },
  );
  for (final width in [320.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'list and scrollable detail fit ${width}px at ${scale}x text',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final f = Fixture();
          await tester.pumpWidget(app(f, scale: scale));
          await tester.pumpAndSettle();
          await open(tester);
          await visible(tester, find.text('Version: 1'));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
