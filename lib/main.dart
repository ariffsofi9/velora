import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:flutter/foundation.dart';
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

  FirebaseOptions options;
  try {
    options = FirebaseStartupConfig.current.resolve(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
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
  await Firebase.initializeApp(options: options);
  await FirebaseEmulatorConfig.connectIfEnabled();

  await LocalNotificationService.init();

  runApp(const VeloraApp());
}

class VeloraApp extends StatelessWidget {
  const VeloraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Velora',
      theme: AppTheme.light,
      home: const SplashPage(),
      routes: {
        '/login': (context) => const LoginPage(),
        '/home': (context) => const WorkspaceGate(),
        '/add-item': (context) => const AddItemPage(),
        '/suggestions': (context) => const SuggestionsPage(),
        '/alerts': (context) => const AlertsPage(),
        '/business-setup': (context) => const BusinessSetupPage(),
      },
    );
  }
}
