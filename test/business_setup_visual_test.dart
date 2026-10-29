import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/business_setup/business_setup_page.dart';

// Local UI fixture only; does not initialize Firebase or create business records.
void main() {
  testWidgets(
    'Capture Business Setup preview steps at 393px',
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
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light.copyWith(
              textTheme: AppTheme.light.textTheme.apply(fontFamily: 'Roboto'),
              primaryTextTheme: AppTheme.light.primaryTextTheme.apply(
                fontFamily: 'Roboto',
              ),
            ),
            home: const BusinessSetupPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(int step) async {
        expect(tester.takeException(), isNull);
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Directory.systemTemp.path}/velora-business-setup-$step.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture(1);
      await tester.enterText(
        find.byKey(const ValueKey('business-name')),
        'Tasty Bites',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('type-Restaurant')));
      await tester.tap(find.byKey(const ValueKey('type-Restaurant')));
      await tester.ensureVisible(find.byKey(const ValueKey('setup-next')));
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      await capture(2);
      await tester.ensureVisible(find.byKey(const ValueKey('setup-next')));
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      await capture(3);
      await tester.ensureVisible(find.text('AI Recipe Suggestions'));
      await tester.pumpAndSettle();
      await capture(4);
    },
    skip: !const bool.fromEnvironment('SETUP_SCREENSHOT'),
  );
}
