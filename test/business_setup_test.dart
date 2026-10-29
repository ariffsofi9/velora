import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/main.dart' show VeloraApp;
import 'package:velora/screens/business_setup/business_setup_page.dart';
import 'package:velora/screens/business_setup/business_setup_widgets.dart';

Widget setupApp({double scale = 1, double keyboard = 0}) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      viewInsets: EdgeInsets.only(bottom: keyboard),
    ),
    child: child!,
  ),
  home: const BusinessSetupPage(),
);

Future<void> tapSetup(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> enterBusiness(WidgetTester tester, {bool address = true}) async {
  await tester.enterText(
    find.byKey(const ValueKey('business-name')),
    '  Sunrise Cafe  ',
  );
  if (address) {
    await tester.enterText(
      find.byKey(const ValueKey('business-address')),
      '12 Market Street',
    );
  }
  await tapSetup(tester, find.byKey(const ValueKey('type-Bakery')));
  await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
}

SetupChoices choices(WidgetTester tester, String group) =>
    tester.widget<SetupChoices>(
      find.byWidgetPredicate(
        (widget) => widget is SetupChoices && widget.group == group,
      ),
    );

void main() {
  testWidgets('Disabled reminders are accurately reported in the summary', (
    tester,
  ) async {
    await tester.pumpWidget(setupApp());
    await enterBusiness(tester, address: false);
    await tapSetup(tester, find.byKey(const ValueKey('expiry-reminders')));
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('summary-Expiry Reminders')))
          .data,
      'Disabled',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('summary-Reminder Timing')))
          .data,
      'Disabled',
    );
    expect(
      find.byKey(const ValueKey('summary-Business Address')),
      findsNothing,
    );
  });

  testWidgets(
    'Leaving the preview does not persist or reuse a business draft',
    (tester) async {
      await tester.pumpWidget(setupApp());
      await enterBusiness(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(setupApp());
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('business-name')))
            .controller!
            .text,
        isEmpty,
      );
      expect(choices(tester, 'type').selected, isNull);
    },
  );
  testWidgets('Step 1 validates name and type, while address stays optional', (
    tester,
  ) async {
    await tester.pumpWidget(setupApp());
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    expect(find.text('Please enter your business name.'), findsOneWidget);
    expect(find.text('Please select a business type.'), findsOneWidget);
    await enterBusiness(tester, address: false);
    expect(find.text('Set Up Your Inventory'), findsOneWidget);
  });

  testWidgets(
    'Business type chips are text-only in three columns and two rows',
    (tester) async {
      await tester.pumpWidget(setupApp());
      final group = find.byWidgetPredicate(
        (widget) => widget is SetupChoices && widget.group == 'type',
      );
      expect(
        find.descendant(of: group, matching: find.byType(Icon)),
        findsNothing,
      );
      final positions = [
        for (final value in [
          'Restaurant',
          'Caf\u00e9',
          'Bakery',
          'Catering',
          'Cloud Kitchen',
          'Other',
        ])
          tester.getTopLeft(find.byKey(ValueKey('type-$value'))),
      ];
      expect(positions[0].dy, positions[1].dy);
      expect(positions[1].dy, positions[2].dy);
      expect(positions[3].dy, positions[4].dy);
      expect(positions[4].dy, positions[5].dy);
      expect(positions[3].dy, greaterThan(positions[0].dy));
      expect(positions[0].dx, lessThan(positions[1].dx));
      expect(positions[1].dx, lessThan(positions[2].dx));
    },
  );

  testWidgets(
    'Defaults, disabled timing and back navigation preserve entered state',
    (tester) async {
      await tester.pumpWidget(setupApp());
      await enterBusiness(tester);
      expect(choices(tester, 'unit').selected, 'kg');
      expect(choices(tester, 'timing').selected, '3');
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('low-stock-alerts')))
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('expiry-reminders')))
            .value,
        isTrue,
      );
      await tapSetup(tester, find.byKey(const ValueKey('unit-L')));
      await tapSetup(tester, find.byKey(const ValueKey('timing-7')));
      await tapSetup(tester, find.byKey(const ValueKey('low-stock-alerts')));
      await tapSetup(tester, find.byKey(const ValueKey('expiry-reminders')));
      expect(choices(tester, 'timing').onSelected, isNull);
      expect(
        tester.widget<InkWell>(find.byKey(const ValueKey('timing-1'))).onTap,
        isNull,
      );
      await tapSetup(tester, find.byKey(const ValueKey('setup-back')));
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('business-name')))
            .controller!
            .text,
        '  Sunrise Cafe  ',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('business-address')),
            )
            .controller!
            .text,
        '12 Market Street',
      );
      expect(choices(tester, 'type').selected, 'Bakery');
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(choices(tester, 'unit').selected, 'L');
      expect(choices(tester, 'timing').selected, '7');
      expect(choices(tester, 'timing').onSelected, isNull);
      await tapSetup(tester, find.byKey(const ValueKey('expiry-reminders')));
      expect(choices(tester, 'timing').selected, '7');
      expect(choices(tester, 'timing').onSelected, isNotNull);
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(find.text('Your setup preview is ready'), findsOneWidget);
      expect(
        tester.getBottomRight(find.byKey(const ValueKey('setup-dashboard'))).dy,
        lessThanOrEqualTo(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        ),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Name')))
            .data,
        'Sunrise Cafe',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Type')))
            .data,
        'Bakery',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Inventory Unit')))
            .data,
        'L',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('summary-Low Stock Alerts')),
            )
            .data,
        'Disabled',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Reminder Timing')))
            .data,
        '7 days before',
      );
      expect(find.textContaining('Preview only'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('setup-dashboard')))
            .onPressed,
        isNull,
      );
      await tapSetup(tester, find.text('Edit inventory preferences'));
      expect(find.text('Set Up Your Inventory'), findsOneWidget);
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      await tapSetup(tester, find.text('Edit Setup'));
      expect(find.text('Set Up Your Business'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('business-name')),
        'Updated Cafe',
      );
      await tapSetup(tester, find.byKey(const ValueKey('type-Other')));
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Name')))
            .data,
        'Updated Cafe',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Type')))
            .data,
        'Other',
      );
    },
  );

  testWidgets('System Back returns to previous step and retains form values', (
    tester,
  ) async {
    await tester.pumpWidget(setupApp());
    await enterBusiness(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Set Up Your Business'), findsOneWidget);
    expect(choices(tester, 'type').selected, 'Bakery');
  });

  testWidgets(
    'Production named preview route opens without Firebase initialization',
    (tester) async {
      await tester.pumpWidget(const VeloraApp());
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/business-setup');
      await tester.pumpAndSettle();
      expect(find.byType(BusinessSetupPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
  );

  for (final width in [320.0, 393.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('All steps fit $width with text scale $scale and keyboard', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(setupApp(scale: scale, keyboard: 220));
        await enterBusiness(tester, address: false);
        expect(tester.takeException(), isNull);
        await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
        await tester.ensureVisible(
          find.byKey(const ValueKey('setup-dashboard')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('setup-dashboard'))).height,
          greaterThanOrEqualTo(48),
        );
      });
    }
  }
}
