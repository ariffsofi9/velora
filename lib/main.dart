import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'services/android_pilot_policy.dart';
import 'services/firebase_startup_config.dart';
import 'core/theme/app_theme.dart';

// SERVICES
import 'services/local_notification_service.dart';
import 'services/firebase_emulator_config.dart';

// AUTH
import 'screens/auth/splash_page.dart';
import 'screens/auth/login_page.dart';
import 'screens/auth/workspace_gate.dart';

// INVENTORY
import 'screens/inventory/add_item/add_item_page.dart';

// SUGGESTIONS
import 'screens/suggestions/suggestions_page.dart';

// ALERTS
import 'screens/alerts/alerts_page.dart';
import 'screens/business_setup/business_setup_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final policy = AndroidPilotPolicy.fromBuildConfiguration(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    androidFlavor: appFlavor,
  );
  try {
    await initializeVeloraFirebase(
      policy: policy,
      configuration: FirebaseStartupConfig.current,
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
      androidFlavor: appFlavor,
      initialize: (options) async {
        await Firebase.initializeApp(options: options);
      },
    );
  } on FirebaseConfigurationException catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(error.toString()),
            ),
          ),
        ),
      ),
    );
    return;
  }
  if (!policy.isRestricted) {
    await FirebaseEmulatorConfig.connectIfEnabled();
    await LocalNotificationService.init();
  }
  runApp(
    VeloraApp(
      pilot: policy.isRestricted
          ? AndroidPilotAuthDependencies(policy: policy)
          : null,
    ),
  );
}

/// Startup admission shared with offline tests. Resolves/validates before the
/// initializer can run; tests supply a synthetic callback, never Firebase.
Future<void> initializeVeloraFirebase({
  required AndroidPilotPolicy policy,
  required FirebaseStartupConfig configuration,
  required bool isWeb,
  required TargetPlatform platform,
  String? androidFlavor,
  required Future<void> Function(FirebaseOptions options) initialize,
}) async {
  final options = configuration.resolve(
    pilotPolicy: policy,
    isWeb: isWeb,
    platform: platform,
    androidFlavor: androidFlavor,
  );
  await initialize(options);
}

class VeloraApp extends StatelessWidget {
  final AndroidPilotAuthDependencies? pilot;
  const VeloraApp({super.key, this.pilot});

  @override
  Widget build(BuildContext context) {
    if (pilot?.policy.isValid == false) {
      return const MaterialApp(home: PilotAccessBlockedPage());
    }
    final contained = pilot?.policy.isRestricted == true;
    Widget guarded(WidgetBuilder builder, BuildContext context) =>
        contained ? const PilotAccessBlockedPage() : builder(context);
    final routes = <String, WidgetBuilder>{
      '/login': (context) => LoginPage(pilot: pilot),
      '/home': (context) => WorkspaceGate(pilot: pilot),
      '/add-item': (context) => guarded((_) => const AddItemPage(), context),
      '/suggestions': (context) =>
          guarded((_) => const SuggestionsPage(), context),
      '/alerts': (context) => guarded((_) => const AlertsPage(), context),
      '/business-setup': (context) =>
          guarded((_) => const BusinessSetupPage(), context),
    };
    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Velora',
      theme: AppTheme.light,
      home: contained ? null : SplashPage(pilot: pilot),
      routes: routes,
      onGenerateInitialRoutes: !contained
          ? null
          : (initial) => [
              MaterialPageRoute<void>(
                settings: RouteSettings(name: initial),
                builder: (context) => initial == '/'
                    ? SplashPage(pilot: pilot)
                    : routes[initial]?.call(context) ??
                          const PilotAccessBlockedPage(),
              ),
            ],
      onUnknownRoute: !contained
          ? null
          : (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const PilotAccessBlockedPage(),
            ),
    );
    return pilot == null
        ? app
        : AndroidPilotAuthScope(dependencies: pilot!, child: app);
  }
}
