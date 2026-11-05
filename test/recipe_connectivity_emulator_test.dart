import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:velora/services/fake_recipe_client.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_session.dart';

void main() {
  const run = bool.fromEnvironment('RUN_RECIPE_EMULATOR_TEST');
  testWidgets(
    'real Flutter SDK: shared demo Auth, membership and fake recipe callable',
    (tester) async {
      await tester.runAsync(() async {
        expect(FirebaseEmulatorConfig.recipeConnectivity, true);
        const normal = FirebaseOptions(
          apiKey: 'placeholder',
          appId: 'placeholder',
          messagingSenderId: 'placeholder',
          projectId: 'placeholder',
        );
        await Firebase.initializeApp(
          options: FirebaseEmulatorConfig.optionsFor(normal),
        );
        await FirebaseEmulatorConfig.connectIfEnabled();
        try {
          for (final role in ['owner', 'staff']) {
            await FirebaseAuth.instance.signInWithEmailAndPassword(
              email: 'connectivity-$role@example.test',
              password: 'disposable-test-password',
            );
            final workspace = await WorkspaceResolver().resolve();
            final result = await FakeRecipeClient(
              session: WorkspaceSession.fromVerified(workspace),
            ).generate(requestId: 'flutter-$role-connectivity-0001');
            expect(result.status, 'ok');
            expect(result.recipes.single.ingredientItemIds, ['banana', 'milk']);
            expect(result.recipes.single.steps, isNotEmpty);
            await FirebaseAuth.instance.signOut();
          }
        } finally {
          await FirebaseAuth.instance.signOut();
        }
      });
    },
    skip: !run,
  );
}
