import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/dashboard/dashboard_page.dart';
import 'package:velora/screens/home/widgets_home/bottom_bar.dart';
import 'dashboard_test_fakes.dart';

// Opt-in offline render, never used as production inventory data.
void main() {
  testWidgets(
    'Capture Batch 3 Dashboard at 393px',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final fonts = '${Platform.environment['WINDIR']}/Fonts';
        final sdk = const String.fromEnvironment('FLUTTER_SDK');
        for (final entry in {
          'Roboto': '$fonts/segoeui.ttf',
          'Ahem': '$fonts/segoeui.ttf',
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
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: AppTheme.light.copyWith(
              textTheme: AppTheme.light.textTheme.apply(fontFamily: 'Roboto'),
              primaryTextTheme: AppTheme.light.primaryTextTheme.apply(
                fontFamily: 'Roboto',
              ),
            ),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: DashboardPage(
                firestore: dashboardFirestore(),
                onCheckNotifications: () {},
              ),
              bottomNavigationBar: VeloraBottomBar(
                currentIndex: 0,
                onTap: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        final context = tester.element(find.byType(DashboardPage));
        await precacheImage(
          const AssetImage('assets/images/auth/logo_mark.png'),
          context,
        );
        if (context.mounted) {
          await precacheImage(
            const AssetImage('assets/images/auth/leaf_small_1.png'),
            context,
          );
        }
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${Directory.systemTemp.path}/velora-dashboard-batch3-preview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    },
    skip: !const bool.fromEnvironment('DASHBOARD_SCREENSHOT'),
  );
}
