import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
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
  const configuration = FirebaseStartupConfig.current;
  late final FirebaseOptions startupOptions;
  try {
    await initializeVeloraFirebase(
      policy: policy,
      configuration: configuration,
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
      androidFlavor: appFlavor,
      initialize: (options) async {
        if (kIsWeb &&
            options.projectId == AndroidPilotPolicy.approvedProject &&
            configuration.cloudProject == null &&
            !_isLocalWebDebugOrigin(Uri.base)) {
          throw FirebaseConfigurationException(
            'Launch REAL Firebase with '
            '--dart-define=VELORA_FIREBASE_PROJECT=velora-73222.',
          );
        }
        final app = await Firebase.initializeApp(options: options);
        if (kIsWeb) {
          FirebaseStartupProfile.validateActiveApp(options, app.options);
        }
        startupOptions = options;
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
    FirebaseStartupProfile(
      options: startupOptions,
      child: VeloraApp(
        pilot: policy.isRestricted
            ? AndroidPilotAuthDependencies(policy: policy)
            : null,
      ),
    ),
  );
}

bool _isLocalWebDebugOrigin(Uri uri) =>
    kDebugMode &&
    uri.scheme == 'http' &&
    uri.userInfo.isEmpty &&
    const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);

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
    if (pilot != null) {
      return AndroidPilotAuthScope(dependencies: pilot!, child: app);
    }
    if (kIsWeb &&
        Firebase.apps.isNotEmpty &&
        Firebase.app().options.projectId ==
            AndroidPilotPolicy.approvedProject) {
      return _RealWebAuthListener(child: app);
    }
    return app;
  }
}

class _RealWebAuthListener extends StatefulWidget {
  final Widget child;
  const _RealWebAuthListener({required this.child});

  @override
  State<_RealWebAuthListener> createState() => _RealWebAuthListenerState();
}

class _RealWebAuthListenerState extends State<_RealWebAuthListener> {
  late final StreamSubscription<User?> _subscription;

  @override
  void initState() {
    super.initState();
    // Keep FlutterFire's shared Web listener connected across route changes.
    // Reconnecting it can replay the initial user after a route's own snapshot.
    _subscription = FirebaseAuth.instance.authStateChanges().listen(
      (_) {},
      onError: (Object _) {
        // The route's own verification listener handles Auth failures.
      },
    );
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
