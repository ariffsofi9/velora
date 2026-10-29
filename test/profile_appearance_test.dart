import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/settings/appearance_page.dart';
import 'package:velora/screens/settings/widgets_settings/profile_header_card.dart';

class _ProfileUser extends Fake implements User {
  @override
  String? get displayName => 'Sarah Parker';

  @override
  String? get email => 'sarah@example.test';

  @override
  String? get photoURL => null;
}

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, content) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: content!,
  ),
  home: child,
);

void main() {
  testWidgets('profile header uses authenticated identity and edit action', (
    tester,
  ) async {
    var edits = 0;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ProfileHeaderCard(user: _ProfileUser(), onEdit: () => edits++),
        ),
      ),
    );

    expect(find.text('Sarah Parker'), findsOneWidget);
    expect(find.text('sarah@example.test'), findsOneWidget);
    expect(find.text('SP'), findsOneWidget);
    await tester.tap(find.byType(ProfileHeaderCard));
    expect(edits, 1);
  });

  testWidgets('appearance saves only the supported local preview preference', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _app(
        AppearancePage(
          initialDarkModePreference: false,
          onPreferenceChanged: changes.add,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('appearance-dark')));
    await tester.pump();

    expect(changes, [true]);
    expect(find.textContaining('Dark preview preference is saved'), findsOne);
    expect(find.textContaining('Velora remains in Light mode'), findsOne);
    expect(find.text('Unavailable'), findsOne);
    await tester.scrollUntilVisible(
      find.text('Not supported in the current app theme'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Not supported in the current app theme'), findsOne);
  });

  for (final size in [
    const Size(320, 568),
    const Size(393, 852),
    const Size(768, 1024),
  ]) {
    testWidgets('appearance is scroll-safe at ${size.width} with 2x text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _app(
          AppearancePage(
            initialDarkModePreference: false,
            onPreferenceChanged: (_) {},
          ),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Reduced Motion'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Reduced Motion'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
