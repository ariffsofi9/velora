import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/screens/auth/welcome_page.dart';
import 'package:velora/screens/auth/splash_page.dart';
import 'package:velora/services/auth_service.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/signup_page.dart';
import 'package:velora/screens/auth/forgot_password_page.dart';
import 'package:velora/screens/dashboard/dashboard_page.dart';
import 'package:velora/screens/home/widgets_home/bottom_bar.dart';
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/item_details_page.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_card.dart';
import 'package:velora/screens/inventory/widgets_inventory/inventory_search_bar.dart';
import 'package:velora/screens/settings/widgets_settings/profile_header_card.dart';
import 'package:velora/screens/settings/widgets_settings/preferences_settings_card.dart';
import 'package:velora/screens/settings/widgets_settings/logout_card.dart';
import 'dashboard_test_fakes.dart';

class _PreviewSession extends Fake implements AuthService {
  @override
  Future<bool> canRestoreSession() async => false;
}

// Opt-in offline previews. Fixtures here are never production data.
void main() {
  testWidgets(
    'Capture white/brown reference previews at 393px',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final fonts = '${Platform.environment['WINDIR']}/Fonts';
        const sdk = String.fromEnvironment('FLUTTER_SDK');
        for (final entry in {
          'Roboto': '$fonts/segoeui.ttf',
          'Georgia': '$fonts/georgia.ttf',
          'MaterialIcons':
              '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(entry.key)
            ..addFont(
              File(
                entry.value,
              ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
          await loader.load();
        }
      });
      final item = InventoryItem(
        id: 'fixture-milk',
        name: 'Milk',
        category: 'Dairy',
        quantity: 2,
        expiryDate: DateTime.now().add(const Duration(days: 2)),
        imageUrl: '',
        createdAt: DateTime.now(),
      );
      final search = TextEditingController();
      addTearDown(search.dispose);
      final screens = <String, Widget Function()>{
        'splash': () => TickerMode(
          enabled: false,
          child: SplashPage(authService: _PreviewSession()),
        ),
        'welcome': () => const WelcomePage(),
        'login': () => const LoginPage(),
        'register': () => const SignUpPage(),
        'forgot': () => const ForgotPasswordPage(),
        'dashboard': () => Scaffold(
          body: DashboardPage(
            firestore: dashboardFirestore(),
            onCheckNotifications: () {},
          ),
          bottomNavigationBar: VeloraBottomBar(currentIndex: 0, onTap: (_) {}),
        ),
        'inventory': () => Scaffold(
          appBar: AppBar(title: const Text('Inventory')),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                InventorySearchBar(controller: search, onChanged: (_) {}),
                const SizedBox(height: 16),
                InventoryCard(item: item, onTap: () {}),
              ],
            ),
          ),
          bottomNavigationBar: VeloraBottomBar(currentIndex: 1, onTap: (_) {}),
        ),
        'add': () => const AddItemPage(),
        'details': () => ItemDetailsPage(item: item),
        'profile': () => Scaffold(
          appBar: AppBar(title: const Text('Profile')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                ProfileHeaderCard(user: null, onEdit: () {}),
                const SizedBox(height: 16),
                PreferencesSettingsCard(
                  darkModePrep: false,
                  onOpenAppearance: () {},
                ),
                const SizedBox(height: 16),
                LogoutCard(onLogout: () {}),
              ],
            ),
          ),
          bottomNavigationBar: VeloraBottomBar(currentIndex: 4, onTap: (_) {}),
        ),
      };
      for (final entry in screens.entries) {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light.copyWith(
                textTheme: AppTheme.light.textTheme.apply(fontFamily: 'Roboto'),
                primaryTextTheme: AppTheme.light.primaryTextTheme.apply(
                  fontFamily: 'Roboto',
                ),
              ),
              home: entry.value(),
            ),
          ),
        );
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/images/auth/logo_mark.png'),
            tester.element(find.byType(Scaffold).first),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: entry.key);
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Directory.systemTemp.path}/velora-reference-${entry.key}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
    skip: !const bool.fromEnvironment('REDESIGN_SCREENSHOT'),
  );
}
