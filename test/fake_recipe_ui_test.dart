// Offline Firebase interface doubles; no network or emulator access.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/fake_recipe_client.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/recipe_suggestions_content.dart';

class _User extends Fake implements User {
  @override
  final String uid;
  _User(this.uid);
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('actor');
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void change(String? uid) {
    user = uid == null ? null : _User(uid);
    changes.add(user);
  }
}

class _Resolver extends WorkspaceResolver {
  CafeWorkspace workspace;
  bool revoked = false;
  _Resolver(CafeRole role)
    : workspace = CafeWorkspace(
        cafeId: 'cafe',
        uid: 'actor',
        ownerUid: role == CafeRole.owner ? 'actor' : 'owner',
        role: role,
      );
  @override
  Future<CafeWorkspace> resolve() async {
    if (revoked) {
      throw const WorkspaceResolutionException(
        WorkspaceFailure.inconsistentMembership,
      );
    }
    return workspace;
  }
}

class _Callable implements FakeRecipeCallable {
  @override
  String projectId = FirebaseEmulatorConfig.recipeProject;
  final ids = <String>[];
  Completer<void>? pending;
  bool fail = false, empty = false;
  @override
  Future<Map<String, dynamic>> invoke(Map<String, Object> data) async {
    ids.add(data['requestId']! as String);
    await pending?.future;
    if (fail) throw StateError('PRIVATE raw provider error');
    return {
      'schemaVersion': 1,
      'provider': 'fake',
      'requestId': data['requestId'],
      'status': empty ? 'no_suggestions' : 'ok',
      'recipes': [
        if (!empty)
          {
            'title': 'Fixture recipe',
            'ingredientItemIds': ['banana', 'milk'],
            'steps': ['Supplied fixture instruction.'],
            'whyRecommended': 'Fake fixture.',
          },
      ],
    };
  }
}

void main() {
  late _Auth auth;
  late _Resolver resolver;
  late _Callable callable;
  late FakeRecipeClient client;
  late WorkspaceSession session;
  void setup([CafeRole role = CafeRole.staff]) {
    auth = _Auth();
    resolver = _Resolver(role);
    callable = _Callable();
    session = WorkspaceSession.fromVerified(resolver.workspace);
    client = FakeRecipeClient(
      session: session,
      auth: auth,
      resolver: resolver,
      callable: callable,
    );
  }

  Future<void> show(
    WidgetTester tester, {
    WorkspaceSession? context,
    bool missing = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecipeSuggestionsContent(
              workspaceSession: missing ? null : context ?? session,
              client: client,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> generate(WidgetTester tester) async {
    await tester.tap(find.text('Generate Recipes'));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    // Stream subscription cancellation can complete in the controller's setup
    // zone. Let those real microtasks finish before advancing the fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  setUp(setup);
  tearDown(() async {
    await auth.changes.close();
  });

  testWidgets('non-recipe profiles cannot dispatch even with injected client', (
    tester,
  ) async {
    if (FakeRecipeClient.profileEnabled) return;
    await show(tester);
    await generate(tester);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(callable.ids, isEmpty);
  });
  testWidgets('missing verified session is disabled', (tester) async {
    await show(tester, missing: true);
    await generate(tester);
    expect(callable.ids, isEmpty);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
  group('explicit isolated recipe profile UI', () {
    for (final role in CafeRole.values) {
      testWidgets(
        '$role generates and opens honest read-only details at 320px / 2x text',
        (tester) async {
          await auth.changes.close();
          setup(role);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 852);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await show(tester, scale: 2);
          // Exercise the existing responsive details renderer with enlarged text.
          await generate(tester);
          await settle(tester);
          expect(
            find.text('Fixture recipe'),
            findsOneWidget,
            reason: tester
                .widgetList<Text>(find.byType(Text))
                .map((text) => text.data)
                .join('|'),
          );
          expect(callable.ids, hasLength(1));
          await tester.ensureVisible(find.text('Fixture recipe'));
          await tester.tap(find.text('Fixture recipe'));
          await settle(tester);
          await tester.scrollUntilVisible(
            find.textContaining('Quantities and units are not supplied.'),
            200,
            scrollable: find.byType(Scrollable).last,
          );
          expect(
            find.textContaining('Quantities and units are not supplied.'),
            findsOneWidget,
          );
          await tester.scrollUntilVisible(
            find.text('Ingredient ID: banana'),
            200,
            scrollable: find.byType(Scrollable).last,
          );
          expect(find.text('Ingredient ID: banana'), findsOneWidget);
          expect(find.text('Ingredient ID: milk'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Supplied fixture instruction.'),
            200,
            scrollable: find.byType(Scrollable).last,
          );
          expect(find.text('Supplied fixture instruction.'), findsOneWidget);
          expect(find.text('Cook Now'), findsNothing);
          expect(find.text('Save Recipe'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets('loading prevents duplicate submits; empty stays empty', (
      tester,
    ) async {
      callable.pending = Completer<void>();
      callable.empty = true;
      await show(tester);
      await generate(tester);
      expect(find.text('Loading fake recipes…'), findsOneWidget);
      await generate(tester);
      expect(callable.ids, hasLength(1));
      callable.pending!.complete();
      await settle(tester);
      expect(
        find.text('No fake recipes match the eligible inventory.'),
        findsOneWidget,
      );
      expect(find.text('Fixture recipe'), findsNothing);
    });
    testWidgets('safe error and explicit retry use a fresh request ID', (
      tester,
    ) async {
      callable.fail = true;
      await show(tester);
      await generate(tester);
      await settle(tester);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(callable.ids, hasLength(1));
      callable.fail = false;
      await tester.ensureVisible(find.text('Retry recipes'));
      await tester.tap(find.text('Retry recipes'));
      await settle(tester);
      expect(find.text('Fixture recipe'), findsOneWidget);
      expect(callable.ids.toSet(), hasLength(2));
    });
    for (final denied in ['wrong-project', 'signed-out', 'revoked']) {
      testWidgets('authorization denied: $denied', (tester) async {
        if (denied == 'wrong-project') callable.projectId = 'production';
        if (denied == 'signed-out') auth.change(null);
        if (denied == 'revoked') resolver.revoked = true;
        await show(tester);
        await generate(tester);
        await settle(tester);
        expect(callable.ids, isEmpty);
        expect(find.text('Fixture recipe'), findsNothing);
      });
    }
    for (final change in [
      'signout',
      'identity',
      'away-back',
      'membership',
      'cafe',
      'widget-session',
    ]) {
      testWidgets('pending UI result rejected: $change', (tester) async {
        callable.pending = Completer<void>();
        await show(tester);
        await generate(tester);
        if (change == 'membership') {
          resolver.revoked = true;
        } else if (change == 'cafe' || change == 'widget-session') {
          resolver.workspace = const CafeWorkspace(
            cafeId: 'other',
            uid: 'actor',
            ownerUid: 'other-owner',
            role: CafeRole.staff,
          );
          if (change == 'widget-session') {
            await show(
              tester,
              context: WorkspaceSession.fromVerified(resolver.workspace),
            );
          }
        } else {
          auth.change(change == 'identity' ? 'other' : null);
          if (change == 'away-back') auth.change('actor');
        }
        callable.pending!.complete();
        await settle(tester);
        expect(find.text('Fixture recipe'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('disposed widget ignores pending result', (tester) async {
      callable.pending = Completer<void>();
      await show(tester);
      await generate(tester);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      callable.pending!.complete();
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  }, skip: !FakeRecipeClient.profileEnabled);
}
