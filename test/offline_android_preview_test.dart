import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/core/theme/app_tokens.dart';
import 'package:velora/offline_preview/main.dart' as preview;
import 'package:velora/screens/home/widgets_home/bottom_bar.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_card.dart';
import 'package:velora/widgets/dashboard/inventory_overview.dart';

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _text(WidgetTester tester, String label) =>
    _tap(tester, find.text(label));

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pumpAndSettle();
}

Future<void> _start(WidgetTester tester) async {
  await tester.pumpWidget(
    preview.OfflinePreviewApp(
      fixtures: preview.OfflinePreviewFixtures(DateTime(2026, 11, 20)),
    ),
  );
  await tester.pumpAndSettle();
  await _text(tester, 'Start walkthrough');
}

Future<void> _sample(WidgetTester tester, [String role = 'Owner']) async {
  await _start(tester);
  await _text(tester, 'View as sample $role');
}

void _disabled(WidgetTester tester, String label) {
  expect(
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, label))
        .onPressed,
    isNull,
  );
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  testWidgets(
    'actual entry point shows the approved wordmark and opens Welcome locally',
    (tester) async {
      preview.main();
      await tester.pumpAndSettle();
      expect(find.text('OFFLINE PREVIEW'), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as AssetImage).assetName,
        'assets/images/velora_reference_wordmark.png',
      );
      expect(tester.takeException(), isNull);
      await _text(tester, 'Start walkthrough');
      expect(find.text('Welcome to Velora'), findsOneWidget);
    },
  );

  testWidgets(
    'Login, Register and all setup steps are reachable without authentication or provisioning',
    (tester) async {
      await _start(tester);
      await _text(tester, 'Login');
      expect(find.text('Welcome Back'), findsOneWidget);
      _disabled(tester, 'Log In');
      await _text(tester, 'View as sample Staff');
      expect(find.byType(InventoryOverview), findsOneWidget);
      await _back(tester);
      expect(find.text('Welcome Back'), findsOneWidget);
      await _back(tester);

      await _text(tester, 'Register');
      expect(find.text('Create an Account'), findsOneWidget);
      _disabled(tester, 'Create Account');
      await _text(tester, 'Preview business setup');
      expect(find.text('Business Setup · Step 1 of 3'), findsOneWidget);
      await _text(tester, 'Bakery');
      await _text(tester, 'Next');
      expect(find.text('Business Setup · Step 2 of 3'), findsOneWidget);
      await _text(tester, 'g');
      await _text(tester, 'Next');
      expect(find.text('Business Setup · Step 3 of 3'), findsOneWidget);
      expect(find.text('Business Setup Summary'), findsOneWidget);
      expect(find.text('Bakery'), findsOneWidget);
      expect(find.text('g'), findsOneWidget);
      _disabled(tester, 'Create Workspace');
      await _back(tester);
      expect(find.text('Business Setup · Step 2 of 3'), findsOneWidget);
      await _text(tester, 'Next');
      await _text(tester, 'View as sample Owner');
      expect(find.text('Aisyah Rahman'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dashboard, Inventory, Add Item, Details and both stock forms are read-only',
    (tester) async {
      _setSize(tester, const Size(800, 1200));
      await _sample(tester);
      expect(find.text('Inventory Overview'), findsOneWidget);
      expect(find.text('Low Stock'), findsOneWidget);
      expect(find.text('Near Expiry'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);
      await _tap(tester, find.byTooltip('Add Item'));
      expect(find.text('Add Item'), findsOneWidget);
      _disabled(tester, 'Save Item');
      await _back(tester);
      await _text(tester, 'Inventory');
      await _text(tester, 'Arabica beans');
      expect(find.text('Item Details'), findsOneWidget);
      expect(find.text('8 kg'), findsOneWidget);
      await _text(tester, 'Stock In');
      _disabled(tester, 'Confirm Stock In');
      await _back(tester);
      await _text(tester, 'Stock Out');
      _disabled(tester, 'Confirm Stock Out');
      await _back(tester);
      await _text(tester, 'Stock History');
      expect(find.text('Initial stock'), findsOneWidget);
      expect(find.textContaining('-2 kg · 8 remaining'), findsOneWidget);
      await _back(tester);
      expect(find.text('8 kg'), findsOneWidget);
      await _back(tester);
      expect(find.byType(InventoryCard), findsNWidgets(3));
    },
  );

  testWidgets(
    'Alerts, Activity, recipe pages, Profile and Appearance are linked locally',
    (tester) async {
      _setSize(tester, const Size(800, 1200));
      await _sample(tester);
      await _tap(tester, find.byTooltip('Open Alerts'));
      expect(find.text('Alerts'), findsOneWidget);
      expect(find.text('Oat milk'), findsOneWidget);
      await _back(tester);
      await _text(tester, 'See all activity');
      expect(find.text('Activity'), findsOneWidget);
      await _back(tester);
      await _text(tester, 'AI Tips');
      expect(find.text('AI Recipe Suggestions'), findsOneWidget);
      _disabled(tester, 'Generate Suggestions');
      await _text(tester, 'Tomato Pasta');
      expect(find.text('Recipe Details'), findsOneWidget);
      _disabled(tester, 'Save Recipe');
      _disabled(tester, 'Cook This Recipe');
      await _back(tester);
      await _text(tester, 'Saved Recipes');
      expect(find.text('Sample shared library'), findsOneWidget);
      await _back(tester);
      await _text(tester, 'Profile');
      expect(find.text('Sample Owner'), findsOneWidget);
      await _text(tester, 'Settings');
      await _text(tester, 'Appearance');
      expect(find.text('Primary Color'), findsOneWidget);
      await _back(tester);
      await _back(tester);
      expect(find.text('Sample Owner'), findsOneWidget);
    },
  );

  for (final role in ['Owner', 'Staff']) {
    testWidgets('sample $role has the expected controls on Team Management', (
      tester,
    ) async {
      await _sample(tester, role);
      await _text(tester, 'Profile');
      expect(find.text('Sample $role'), findsOneWidget);
      await _text(tester, 'Team Management');
      expect(find.text('Aisyah Rahman'), findsOneWidget);
      if (role == 'Owner') {
        _disabled(tester, 'Add Staff');
        expect(
          find.text('Invitations are unavailable in the offline preview.'),
          findsOneWidget,
        );
      } else {
        expect(find.text('Add Staff'), findsNothing);
      }
    });
  }

  for (final size in [
    const Size(390, 844),
    const Size(800, 1200),
    const Size(960, 600),
  ]) {
    testWidgets(
      'Android navigation stays selected on rotation from $size',
      (tester) async {
        _setSize(tester, size);
        await _sample(tester);
        VeloraBottomBar nav() => tester.widget(find.byType(VeloraBottomBar));
        expect(nav().side, size.width > size.height);
        await _text(tester, 'Inventory');
        expect(nav().currentIndex, 1);
        tester.view.physicalSize = Size(size.height, size.width);
        await tester.pumpAndSettle();
        expect(nav().side, size.height >= 720 && size.height > size.width);
        expect(nav().currentIndex, 1);
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(nav().currentIndex, 1);
        expect(find.text('Sample inventory'), findsOneWidget);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets(
    'inventory samples and loading, empty and error states are local',
    (tester) async {
      _setSize(tester, const Size(800, 1200));
      await _sample(tester);
      await _text(tester, 'Inventory');
      for (final (option, result) in [
        ('Bakery samples', 'Bread flour'),
        ('Restaurant samples', 'Chicken breast'),
        (
          'Loading inventory',
          'Choose a sample business to return to the list.',
        ),
        ('Empty inventory', 'No inventory items'),
        ('Inventory error', 'Inventory unavailable'),
        ('Café samples', 'Oat milk'),
      ]) {
        await _tap(
          tester,
          find.byType(DropdownButton<preview.PreviewScenario>),
        );
        await _tap(tester, find.text(option).last);
        expect(find.text(result), findsOneWidget);
      }
    },
  );

  testWidgets(
    'inventory search and category and status filtering combine and survive tab changes',
    (tester) async {
      _setSize(tester, const Size(800, 1200));
      await _sample(tester);
      await _text(tester, 'Inventory');
      final search = find.byType(TextField);
      await tester.enterText(search, '  OAT ');
      await tester.pumpAndSettle();
      expect(find.byType(InventoryCard), findsOneWidget);
      await _text(tester, 'Dairy alternatives');
      await _tap(tester, find.widgetWithText(ChoiceChip, 'Near Expiry'));
      expect(find.text('Oat milk'), findsOneWidget);
      await _text(tester, 'Home');
      await _text(tester, 'Inventory');
      expect(find.text('Oat milk'), findsOneWidget);
      expect(find.text('Arabica beans'), findsNothing);
      await _text(tester, 'Coffee');
      expect(find.text('No matching items'), findsOneWidget);
    },
  );

  testWidgets(
    'large system text fits a phone and keeps all destinations usable',
    (tester) async {
      _setSize(tester, const Size(360, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _sample(tester);
      await _text(tester, 'Inventory');
      expect(find.text('Sample inventory'), findsOneWidget);
      await _text(tester, 'AI Tips');
      expect(find.text('AI Recipe Suggestions'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Saved Recipes'), 100);
      expect(find.text('Saved Recipes'), findsOneWidget);
      await _text(tester, 'Profile');
      expect(find.text('Sample Owner'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('approved theme and semantic text colors preserve contrast', () {
    double contrast(Color foreground, Color background) {
      final a = foreground.computeLuminance();
      final b = background.computeLuminance();
      return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
    }

    final scheme = AppTheme.light.colorScheme;
    expect(scheme.primary, const Color(0xFF866F47));
    expect(scheme.secondary, const Color(0xFFEADFCC));
    expect(AppTheme.light.scaffoldBackgroundColor, Colors.white);
    for (final (foreground, background) in [
      (scheme.onPrimary, scheme.primary),
      (scheme.onSecondary, scheme.secondary),
      (AppColors.success, AppColors.successSurface),
      (AppColors.warning, AppColors.warningSurface),
      (AppColors.danger, AppColors.dangerSurface),
    ]) {
      expect(contrast(foreground, background), greaterThanOrEqualTo(4.5));
    }
  });

  test(
    'preview entry and fixture sources never import service clients or remote images',
    () {
      for (final path in [
        'main.dart',
        'fixtures.dart',
        'walkthrough_pages.dart',
      ]) {
        final source = File('lib/offline_preview/$path').readAsStringSync();
        expect(
          source,
          isNot(
            matches(
              RegExp(
                r'''firebase_|cloud_firestore|package:http|\.network\(|NetworkImage|/services/|/repositories/''',
              ),
            ),
          ),
        );
      }
    },
  );

  test('standalone build pins the entry point and excludes native services', () {
    const folder = 'android/offline_preview';
    final settings = File('$folder/settings.gradle.kts').readAsStringSync();
    final build = File('$folder/build.gradle.kts').readAsStringSync();
    final manifest = File(
      '$folder/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = File(
      '$folder/src/main/java/com/example/velora/offlinepreview/OfflinePreviewActivity.java',
    ).readAsStringSync();

    expect(
      build,
      contains('applicationId = "com.example.velora.offlinepreview"'),
    );
    expect(build, contains('target = "lib/offline_preview/main.dart"'));
    expect(build, contains('gradle.startParameter.isOffline'));
    expect(
      build,
      contains('!hasProperty("target") && !hasProperty("dart-defines")'),
    );
    expect(settings, isNot(contains('dev.flutter.flutter-plugin-loader')));
    expect(
      '$settings$build',
      isNot(contains('com.google.gms.google-services')),
    );
    expect(
      manifest,
      contains(
        'android:name="android.permission.INTERNET" tools:node="remove"',
      ),
    );
    expect(
      manifest,
      matches(RegExp(r'FirebaseInitProvider[^>]+tools:node="remove"')),
    );
    expect(
      manifest,
      matches(
        RegExp(r'automatically-register-plugins"\s+android:value="false"'),
      ),
    );
    expect(activity, isNot(contains('registerWith')));
    expect(activity, isNot(contains('super.configureFlutterEngine')));
  });
}
