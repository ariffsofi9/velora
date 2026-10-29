import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/core/theme/app_tokens.dart';
import 'package:velora/screens/notifications/notification_alert_item.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_alert_card.dart';
import 'package:velora/screens/notifications/widgets_notification/notification_header_card.dart';
import 'package:velora/screens/settings/widgets_settings/profile_header_card.dart';
import 'package:velora/screens/settings/widgets_settings/logout_card.dart';
import 'package:velora/screens/settings/widgets_settings/preferences_settings_card.dart';

void main() {
  test(
    'Shared typography stays readable on light surfaces and primary buttons',
    () {
      final theme = AppTheme.light;
      expect(theme.colorScheme.primary, const Color(0xFF886F47));
      expect(theme.scaffoldBackgroundColor, Colors.white);
      expect(AppColors.nude, const Color(0xFFEADFCC));
      expect(theme.textTheme.headlineSmall?.color, AppColors.textPrimary);
      expect(theme.textTheme.titleLarge?.color, AppColors.textPrimary);
      expect(theme.textTheme.bodyMedium?.color, AppColors.textPrimary);
      expect(
        theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
        Colors.white,
      );
      final light = Colors.white.computeLuminance();
      final dark = AppColors.primary.computeLuminance();
      expect((light + .05) / (dark + .05), greaterThanOrEqualTo(4.5));
    },
  );
  for (final width in [320.0, 393.0, 768.0, 1280.0]) {
    testWidgets(
      'Notifications/Profile fit $width at doubled text and retain actions',
      (tester) async {
        tester.view.physicalSize = Size(width, 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var read = 0;
        var readAll = 0;
        var logout = 0;
        final alert = NotificationAlertItem(
          id: 'test-alert',
          title: 'Low Stock',
          message: 'Milk is running low. Only 2 left.',
          type: AlertType.stock,
          priority: AlertPriority.high,
          isRead: false,
          isDismissed: false,
          createdAt: DateTime.now(),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    NotificationHeaderCard(
                      total: 1,
                      unread: 1,
                      onReadAll: () => readAll++,
                    ),
                    NotificationAlertCard(
                      alert: alert,
                      isRead: false,
                      onToggleRead: () => read++,
                      onDismiss: () {},
                    ),
                    ProfileHeaderCard(user: null, onEdit: () {}),
                    PreferencesSettingsCard(
                      darkModePrep: false,
                      onOpenAppearance: () {},
                    ),
                    LogoutCard(onLogout: () => logout++),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final text in ['Read all', 'Mark read', 'Sign Out']) {
          await tester.ensureVisible(find.text(text));
          await tester.tap(find.text(text));
        }
        expect([readAll, read, logout], [1, 1, 1]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
