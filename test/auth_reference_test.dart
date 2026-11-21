import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/signup_page.dart';
import 'package:velora/screens/auth/splash_page.dart';
import 'package:velora/services/auth_service.dart';

class _PreviewSession extends Fake implements AuthService {
  @override
  Future<bool> canRestoreSession() async => false;
}

Widget _app(Widget child, {double scale = 1, double keyboard = 0}) =>
    MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: child,
    );

void main() {
  testWidgets(
    'Auth uses 700 titles, 600 labels/buttons and 400 body/input text',
    (tester) async {
      await tester.pumpWidget(_app(const LoginPage()));
      expect(
        tester.widget<Text>(find.text('Welcome Back')).style?.fontWeight,
        FontWeight.w700,
      );
      expect(
        tester
            .widget<Text>(find.text('Log in to continue to Velora'))
            .style
            ?.fontWeight,
        FontWeight.w400,
      );
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.style?.fontWeight, FontWeight.w400);
      expect(field.decoration?.labelStyle?.fontWeight, FontWeight.w400);
      expect(field.decoration?.floatingLabelStyle?.fontWeight, FontWeight.w600);
      expect(field.decoration?.hintStyle?.fontWeight, FontWeight.w400);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.style?.textStyle?.resolve({})?.fontWeight, FontWeight.w600);
    },
  );
  final forms = <String, Widget Function()>{
    'Login': () => const LoginPage(),
    'Register': () => const SignUpPage(),
  };
  for (final entry in forms.entries) {
    for (final width in [320.0, 393.0, 768.0, 1280.0]) {
      testWidgets('${entry.key} fits $width with doubled text and keyboard', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_app(entry.value(), scale: 2, keyboard: 240));
        await tester.pumpAndSettle();
        final submit = find.byType(FilledButton);
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        expect(tester.getSize(submit).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(submit).width, lessThanOrEqualTo(420));
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [320.0, 393.0]) {
    testWidgets('Splash fits $width with doubled text', (tester) async {
      tester.view.physicalSize = Size(width, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          TickerMode(
            enabled: false,
            child: SplashPage(authService: _PreviewSession()),
          ),
          scale: 2,
        ),
      );
      expect(find.text('VELORA'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('Login retains password visibility and empty-input validation', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const LoginPage()));
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isFalse,
    );
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('Please enter email and password.'), findsOneWidget);
  });

  testWidgets('Account links keep Login/Register navigation functional', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const LoginPage()));
    await tester.ensureVisible(find.text('Sign up'));
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();
    expect(find.byType(SignUpPage), findsOneWidget);
    await tester.ensureVisible(find.text('Log in'));
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('Register retains the Terms validation before account creation', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SignUpPage()));
    final fields = find.byType(TextField);
    for (final (index, text) in [
      'Example User',
      'example@example.test',
      'test-password',
      'test-password',
    ].indexed) {
      await tester.enterText(fields.at(index), text);
    }
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(
      find.text('Please agree to the Terms & Conditions.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Capture production Splash at three viewports and Login/Register at 393px',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
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
      for (final entry in <String, Widget Function()>{
        for (final viewport in ['393x852', '800x1200', '852x393'])
          'splash-$viewport': () => TickerMode(
            enabled: false,
            child: SplashPage(authService: _PreviewSession()),
          ),
        'login': () => const LoginPage(),
        'register': () => const SignUpPage(),
      }.entries) {
        final isSplash = entry.key.startsWith('splash-');
        tester.view.physicalSize = switch (entry.key) {
          'splash-800x1200' => const Size(800, 1200),
          'splash-852x393' => const Size(852, 393),
          _ => const Size(393, 852),
        };
        tester.view.padding = switch (entry.key) {
          'splash-852x393' => const FakeViewPadding(
            left: 24,
            right: 24,
            bottom: 16,
          ),
          _ when isSplash => const FakeViewPadding(top: 24, bottom: 16),
          _ => const FakeViewPadding(),
        };
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
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
        expect(tester.takeException(), isNull);
        if (isSplash) {
          final safeBounds = Rect.fromLTRB(
            tester.view.padding.left,
            tester.view.padding.top,
            tester.view.physicalSize.width - tester.view.padding.right,
            tester.view.physicalSize.height - tester.view.padding.bottom,
          );
          for (final child in [
            find.text('VELORA'),
            find.text('AI SMART INVENTORY\nFOR F&B BUSINESSES'),
            find.byType(LinearProgressIndicator),
          ]) {
            final bounds = tester.getRect(child);
            expect(bounds.left, greaterThanOrEqualTo(safeBounds.left));
            expect(bounds.top, greaterThanOrEqualTo(safeBounds.top));
            expect(bounds.right, lessThanOrEqualTo(safeBounds.right));
            expect(bounds.bottom, lessThanOrEqualTo(safeBounds.bottom));
          }
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable))
                .position
                .maxScrollExtent,
            0,
          );
        }
        final render =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Directory.systemTemp.path}/velora-auth-batch-${entry.key}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
    skip: !const bool.fromEnvironment('AUTH_SCREENSHOT'),
  );
}
