// Offline Firebase interface doubles only.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/fake_recipe_response.dart';
import 'package:velora/services/fake_recipe_client.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_session.dart';

const requestId = 'fake-request-00000001';
Map<String, dynamic> result() => {
  'schemaVersion': 1,
  'requestId': requestId,
  'provider': 'fake',
  'status': 'ok',
  'recipes': [
    {
      'title': 'Fixture smoothie',
      'ingredientItemIds': ['banana', 'milk'],
      'steps': ['Blend the fixture ingredients.'],
      'whyRecommended': 'Explicit fake test fixture.',
    },
  ],
};

class _User extends Fake implements User {
  @override
  final String uid;
  _User(this.uid);
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('staff-a');
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
  CafeWorkspace workspace = const CafeWorkspace(
    cafeId: 'cafe-a',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  );
  bool revoked = false;
  Completer<CafeWorkspace>? pending;
  @override
  Future<CafeWorkspace> resolve() async {
    if (pending != null) return pending!.future;
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
  final calls = <Map<String, Object>>[];
  Future<Map<String, dynamic>> Function()? handler;
  @override
  Future<Map<String, dynamic>> invoke(Map<String, Object> data) async {
    calls.add(Map.from(data));
    return handler == null ? result() : await handler!();
  }
}

void main() {
  const profile =
      FirebaseEmulatorConfig.recipeConnectivity &&
      FirebaseEmulatorConfig.enabled &&
      !FirebaseEmulatorConfig.staffDemo &&
      !FirebaseEmulatorConfig.ai1Mock &&
      FirebaseEmulatorConfig.host == '127.0.0.1';
  test(
    'profile options preserve normal/staff defaults and reject conflicting opt-ins',
    () {
      const normal = FirebaseOptions(
        apiKey: 'placeholder',
        appId: 'placeholder',
        messagingSenderId: 'placeholder',
        projectId: 'normal',
      );
      if (FirebaseEmulatorConfig.recipeConnectivity) {
        if (!profile) {
          expect(
            () => FirebaseEmulatorConfig.optionsFor(normal),
            throwsStateError,
          );
        } else {
          expect(
            FirebaseEmulatorConfig.optionsFor(normal).projectId,
            FirebaseEmulatorConfig.recipeProject,
          );
        }
      } else if (FirebaseEmulatorConfig.ai1Mock) {
        if (!FirebaseEmulatorConfig.enabled ||
            FirebaseEmulatorConfig.conflictingProfiles ||
            FirebaseEmulatorConfig.host != '127.0.0.1') {
          expect(
            () => FirebaseEmulatorConfig.optionsFor(normal),
            throwsStateError,
          );
        } else {
          expect(
            FirebaseEmulatorConfig.optionsFor(normal).projectId,
            FirebaseEmulatorConfig.ai1Project,
          );
        }
      } else if (!FirebaseEmulatorConfig.staffDemo) {
        if (FirebaseEmulatorConfig.enabled) {
          expect(
            FirebaseEmulatorConfig.optionsFor(normal).projectId,
            'demo-velora-workspaces',
          );
        } else {
          expect(
            () => FirebaseEmulatorConfig.optionsFor(normal),
            throwsStateError,
          );
        }
      }
    },
  );
  test('schema v1 keeps ingredient IDs without invented units/quantities', () {
    final parsed = FakeRecipeResponse.parse(result(), requestId, 1);
    expect(parsed.recipes.single.ingredientItemIds, ['banana', 'milk']);
    expect(parsed.status, 'ok');
    expect(
      () => parsed.recipes.single.steps.add('forged'),
      throwsUnsupportedError,
    );
  });
  test(
    'empty fake results are explicit and never fabricate fallback recipes',
    () {
      final parsed = FakeRecipeResponse.parse(
        {...result(), 'status': 'no_suggestions', 'recipes': []},
        requestId,
        1,
      );
      expect(parsed.recipes, isEmpty);
    },
  );
  test(
    'wrong provider/schema/request and malformed recipe content are rejected',
    () {
      for (final extra in [
        {'schemaVersion': 2},
        {'provider': 'groq'},
        {'requestId': 'other'},
        {'status': 'ok', 'recipes': []},
        {
          'recipes': [
            {'title': 'Incomplete'},
          ],
        },
        {
          'recipes': [
            {
              'title': 'Fixture',
              'ingredients': [],
              'steps': ['x'],
              'whyRecommended': 'x',
            },
          ],
        },
      ]) {
        expect(
          () => FakeRecipeResponse.parse({...result(), ...extra}, requestId, 1),
          throwsFormatException,
        );
      }
    },
  );
  test('disabled build cannot dispatch or fall back to Firebase', () async {
    if (profile) return;
    final resolver = _Resolver();
    final transport = _Callable();
    final client = FakeRecipeClient(
      session: WorkspaceSession.fromVerified(resolver.workspace),
      callable: transport,
    );
    await expectLater(
      client.generate(requestId: requestId),
      throwsA(
        isA<RecipeClientException>().having(
          (e) => e.failure,
          'failure',
          RecipeClientFailure.disabled,
        ),
      ),
    );
    expect(transport.calls, isEmpty);
  });
  group('explicit fake connectivity profile', () {
    late _Auth auth;
    late _Resolver resolver;
    late _Callable transport;
    late FakeRecipeClient client;
    setUp(() {
      auth = _Auth();
      resolver = _Resolver();
      transport = _Callable();
      client = FakeRecipeClient(
        session: WorkspaceSession.fromVerified(resolver.workspace),
        auth: auth,
        resolver: resolver,
        callable: transport,
      );
    });
    tearDown(() async {
      await auth.changes.close();
    });
    test(
      'authenticated request sends only request ID and bounded recipe count',
      () async {
        final response = await client.generate(requestId: requestId);
        expect(response.recipes.length, 1);
        expect(transport.calls.single, {
          'requestId': requestId,
          'maxRecipes': 1,
        });
      },
    );
    test('wrong project is rejected before dispatch', () async {
      transport.projectId = 'velora-73222';
      await expectLater(
        client.generate(requestId: requestId),
        throwsA(isA<RecipeClientException>()),
      );
      expect(transport.calls, isEmpty);
    });
    test(
      'missing auth, revoked membership and invalid inputs are denied',
      () async {
        auth.change(null);
        await expectLater(
          client.generate(requestId: requestId),
          throwsA(isA<RecipeClientException>()),
        );
        auth.change('staff-a');
        resolver.revoked = true;
        await expectLater(
          client.generate(requestId: requestId),
          throwsA(isA<RecipeClientException>()),
        );
        for (final count in [0, 4]) {
          await expectLater(
            client.generate(requestId: requestId, maxRecipes: count),
            throwsA(isA<RecipeClientException>()),
          );
        }
        await expectLater(
          client.generate(requestId: 'short'),
          throwsA(isA<RecipeClientException>()),
        );
        expect(transport.calls, isEmpty);
      },
    );
    for (final transition in [
      'signout',
      'identity',
      'away-back',
      'membership',
      'cafe',
    ]) {
      test('pending result invalidated: $transition', () async {
        final pending = Completer<Map<String, dynamic>>();
        transport.handler = () => pending.future;
        final request = client.generate(requestId: requestId);
        final expected = expectLater(
          request,
          throwsA(isA<RecipeClientException>()),
        );
        await Future<void>.delayed(Duration.zero);
        if (transition == 'membership') {
          resolver.revoked = true;
        } else if (transition == 'cafe') {
          resolver.workspace = const CafeWorkspace(
            cafeId: 'other',
            uid: 'staff-a',
            ownerUid: 'other-owner',
            role: CafeRole.staff,
          );
        } else {
          auth.change(transition == 'identity' ? 'other-user' : null);
          if (transition == 'away-back') auth.change('staff-a');
        }
        pending.complete(result());
        await expected;
      });
    }
    test('session transition during authorization prevents dispatch', () async {
      resolver.pending = Completer<CafeWorkspace>();
      final request = client.generate(requestId: requestId);
      final expected = expectLater(
        request,
        throwsA(isA<RecipeClientException>()),
      );
      await Future<void>.delayed(Duration.zero);
      auth.change(null);
      auth.change('staff-a');
      resolver.pending!.complete(resolver.workspace);
      await expected;
      expect(transport.calls, isEmpty);
    });
    for (final code in [
      'unauthenticated',
      'permission-denied',
      'aborted',
      'already-exists',
      'resource-exhausted',
      'unavailable',
    ]) {
      test('callable $code is safe and never retried automatically', () async {
        transport.handler = () async => throw FirebaseFunctionsException(
          code: code,
          message: 'PRIVATE-TOKEN-AND-RESPONSE',
        );
        await expectLater(
          client.generate(requestId: requestId),
          throwsA(isA<RecipeClientException>()),
        );
        expect(transport.calls.length, 1);
        expect(
          const RecipeClientException(
            RecipeClientFailure.unavailable,
          ).toString(),
          isNot(contains('PRIVATE')),
        );
      });
    }
  }, skip: !profile);
}
