import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
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
