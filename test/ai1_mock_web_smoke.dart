// Test-only entry point. Never imported by the application.
// Browser-only harness using the SDK's existing HTML API; no new dependency.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/recipe_suggestions_content.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/ai1_mock_recipe_content.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_session.dart';

void require(bool condition) {
  if (!condition) throw StateError('Smoke assertion failed');
}

T? findWidget<T extends Widget>(bool Function(T) matches) {
  T? found;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is T && matches(widget)) found = widget;
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

Future<T> waitWidget<T extends Widget>(bool Function(T) matches) async {
  for (var attempt = 0; attempt < 700; attempt++) {
    final widget = findWidget<T>(matches);
    if (widget != null) return widget;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('UI smoke timed out');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  final passed = <String>[];
  var ok = false;
  try {
    require(html.window.location.hostname == '127.0.0.1');
    require(
      FirebaseEmulatorConfig.ai1Mock &&
          FirebaseEmulatorConfig.enabled &&
          !FirebaseEmulatorConfig.staffDemo &&
          FirebaseEmulatorConfig.host == '127.0.0.1',
    );
    const placeholder = FirebaseOptions(
      apiKey: 'placeholder',
      appId: 'placeholder',
      messagingSenderId: 'placeholder',
      projectId: 'placeholder',
    );
    await Firebase.initializeApp(
      options: FirebaseEmulatorConfig.optionsFor(placeholder),
    );
    await FirebaseEmulatorConfig.connectIfEnabled();
    for (final role in ['owner', 'staff']) {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: 'ai1-mock-$role@example.test',
        password: 'disposable-test-password',
      );
      final workspace = await WorkspaceResolver().resolve();
      final session = WorkspaceSession.fromVerified(workspace);
      require(
        session.uid == 'ai1-mock-$role' &&
            session.cafeId.isNotEmpty &&
            session.ownerUid == 'ai1-mock-owner' &&
            session.role.name == role,
      );
      runApp(
        MaterialApp(
          key: ValueKey(role),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Ai1MockRecipeContent(workspaceSession: session),
            ),
          ),
        ),
      );
      final button = await waitWidget<FilledButton>(
        (button) => button.onPressed != null,
      );
      button.onPressed!();
      final card = await waitWidget<ListTile>(
        (tile) =>
            tile.title is Text &&
            (tile.title! as Text).data == 'Mock Banana Milk Smoothie',
      );
      card.onTap!();
      final details = await waitWidget<RecipePresentationDetails>((_) => true);
      require(
        jsonEncode(
                  details.recipe.ingredients
                      .map((ingredient) => ingredient.name)
                      .toList(),
                ) ==
                '["Ingredient ID: banana","Ingredient ID: milk"]' &&
            details.recipe.ingredients.every(
              (ingredient) =>
                  ingredient.quantity.isNotEmpty && ingredient.unit.isNotEmpty,
            ) &&
            details.recipe.instructions.isNotEmpty &&
            !details.isDemo,
      );
      passed.add(role);
      runApp(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await FirebaseAuth.instance.signOut();
    }
    ok = true;
  } catch (_) {
    // Never send SDK errors, tokens or credentials to the runner.
  } finally {
    if (Firebase.apps.isNotEmpty) await FirebaseAuth.instance.signOut();
  }
  final result = jsonEncode({'ok': ok, 'roles': passed});
  html.document.body?.append(html.PreElement()..text = result);
  await html.HttpRequest.request(
    '/smoke-result',
    method: 'POST',
    sendData: result,
  );
}
