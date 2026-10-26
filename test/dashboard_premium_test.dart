import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/dashboard/dashboard_page.dart';
import 'package:velora/screens/home/widgets_home/notification_bell.dart';
import 'package:velora/screens/notifications/notification_page.dart';
import 'package:velora/widgets/dashboard/dashboard_content.dart';
import 'package:velora/widgets/dashboard/dashboard_header.dart';
import 'package:velora/widgets/dashboard/inventory_health_card.dart';
import 'dashboard_test_fakes.dart';
import 'package:velora/widgets/dashboard/activity_thumbnail.dart';

class _Observer extends NavigatorObserver {
  Route<dynamic>? route;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      this.route = route;
}

Widget _app(Widget child, {NavigatorObserver? observer}) => MaterialApp(
  theme: AppTheme.light,
  navigatorObservers: [?observer],
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'Missing and device-local ingredient images show a neutral fallback',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const Row(
            children: [
              ActivityThumbnail(imageUrl: ''),
              ActivityThumbnail(imageUrl: '/device/milk.png'),
            ],
          ),
        ),
      );
      expect(find.byIcon(Icons.kitchen_outlined), findsNWidgets(2));
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets('Stored HTTPS ingredient URL is used without an invented image', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const ActivityThumbnail(imageUrl: 'https://example.invalid/milk.png'),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as NetworkImage).url,
      'https://example.invalid/milk.png',
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.kitchen_outlined), findsOneWidget);
  });

  final cases = [
    (const InventoryHealthCard(), 'Your inventory is empty'),
    (const InventoryHealthCard(total: 4), 'Your inventory looks healthy'),
    (
      const InventoryHealthCard(total: 4, nearExpiry: 1),
      'Your inventory needs attention',
    ),
    (
      const InventoryHealthCard(total: 4, lowStock: 1),
      'Your inventory needs attention',
    ),
    (
      const InventoryHealthCard(unavailable: true),
      'Inventory health unavailable',
    ),
  ];
  for (final (card, message) in cases) {
    testWidgets(
      'Health message: $message (${card.nearExpiry}/${card.lowStock})',
      (tester) async {
        await tester.pumpWidget(_app(card));
        expect(find.text(message), findsOneWidget);
      },
    );
  }

  testWidgets('Empty live inventory displays zero counts and guidance', (
    tester,
  ) async {
    final db = dashboardFirestore();
    db.collections['inventory'] = dashboardCollection([]);
    await tester.pumpWidget(
      _app(DashboardPage(firestore: db, onCheckNotifications: () {})),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('total-count'))).data,
      '0',
    );
    await tester.scrollUntilVisible(find.text('Your inventory is empty'), 150);
    expect(
      find.text('Add your first item to start tracking stock.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Inventory failure displays unavailable health, not zero statistics',
    (tester) async {
      final db = dashboardFirestore();
      db.collections['inventory'] = DashboardCollection(
        Stream.error(StateError('offline')),
      );
      await tester.pumpWidget(
        _app(DashboardPage(firestore: db, onCheckNotifications: () {})),
      );
      await tester.pumpAndSettle();
      expect(find.text('Inventory health unavailable'), findsOneWidget);
      expect(find.byKey(const ValueKey('total-count')), findsNothing);
    },
  );

  testWidgets(
    'Summary and both status cards open the existing Inventory destination',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          DashboardContent(
            totalItems: 6,
            nearExpiry: 3,
            lowStock: 4,
            notificationBell: const SizedBox(),
            recentActivity: const SizedBox(),
            onInventoryTap: () => taps++,
            onAddTap: () {},
            onSuggestionTap: () {},
            onAlertTap: () {},
          ),
        ),
      );
      for (final key in [
        'total-count',
        'near-expiry-count',
        'low-stock-count',
      ]) {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
      }
      expect(taps, 3);
    },
  );

  testWidgets(
    'Header uses only the supplied first name and shows current date',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const DashboardHeader(
            notificationBell: SizedBox(),
            firstName: 'Alex Taylor',
          ),
        ),
      );
      expect(find.text('Welcome back, Alex \u{1F44B}'), findsOneWidget);
      final context = tester.element(find.byType(DashboardHeader));
      expect(
        find.text(
          MaterialLocalizations.of(
            context,
          ).formatMediumDate(DateTime.now()).toUpperCase(),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Bell retains unread badge and notification destination', (
    tester,
  ) async {
    final observer = _Observer();
    await tester.pumpWidget(
      _app(
        NotificationBell(firestore: dashboardFirestore()),
        observer: observer,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.notifications_rounded));
    final route = observer.route! as MaterialPageRoute<dynamic>;
    expect(
      route.builder(tester.element(find.byType(NotificationBell))),
      isA<NotificationPage>(),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
