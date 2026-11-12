import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/secure_ai_suggestions.dart';
import 'package:velora/services/secure_ai_service.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/auth/workspace_session_boundary.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/recipe_suggestions_content.dart';
import 'secure_ai_service_test.dart' as fixtures;

class _Inventory extends Fake implements WorkspaceInventoryRepository {
  @override
  final WorkspaceSession session;
  _Inventory(this.session);

  @override
  Stream<List<InventoryItem>> watchItems() => Stream.value(const []);
}

void main() {
  for (final entry in {
    'sign-in-required': 'Sign in again to use AI suggestions.',
    'email-unverified': 'Verify your email before requesting AI suggestions.',
    'account-disabled': 'AI access is unavailable for this account.',
    'ticket-expired':
        'This AI ticket expired. No automatic replacement was issued.',
    'ticket-replayed':
        'This AI ticket was already used. Results cannot be retrieved.',
    'workspace-busy':
        'Workspace AI is busy or paused. Inventory remains available.',
    'outcome-unknown':
        'AI request outcome is unknown. No automatic retry was made.',
  }.entries) {
    testWidgets('reviewed reason ${entry.key} has accurate safe copy', (
      tester,
    ) async {
      final session = fixtures.session();
      final service = SecureAiService(
        currentSession: () => session,
        transport: MockSecureAiTransport(
          (_) async => throw SecureAiTransportException(
            'unavailable',
            reason: entry.key,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SecureAiSuggestions(
              workspaceSession: session,
              service: service,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Generate Recipes'));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Mock dish'), findsNothing);
    });
  }
  testWidgets(
    'SuggestionsPage injects secure mock while keeping inventory insights',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = fixtures.session();
      final service = SecureAiService(
        currentSession: () => session,
        transport: MockSecureAiTransport(
          (data) async => data['operation'] == 'issue'
              ? fixtures.issued()
              : fixtures.result(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SuggestionsPage(
            workspaceSession: session,
            repository: _Inventory(session),
            aiService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SecureAiSuggestions), findsOneWidget);
      expect(find.text('Inventory Insights'), findsOneWidget);
      await tester.ensureVisible(find.text('Generate Recipes'));
      await tester.tap(find.text('Generate Recipes'));
      await tester.pumpAndSettle();
      expect(find.text('Mock dish'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final width in [320.0, 1280.0]) {
    testWidgets('secure mock panel fits $width at doubled text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = fixtures.session();
      final service = SecureAiService(
        currentSession: () => session,
        transport: MockSecureAiTransport(
          (data) async => data['operation'] == 'issue'
              ? fixtures.issued()
              : fixtures.result(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SecureAiSuggestions(
                  workspaceSession: session,
                  service: service,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Generate Recipes'));
      await tester.pumpAndSettle();
      expect(find.text('Mock dish'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('mock loading, duplicate protection and explicit demo success', (
    tester,
  ) async {
    final session = fixtures.session();
    final pending = Completer<Object?>();
    var calls = 0;
    final service = SecureAiService(
      currentSession: () => session,
      transport: MockSecureAiTransport((data) async {
        calls++;
        if (data['operation'] == 'issue') return fixtures.issued();
        return await pending.future;
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecureAiSuggestions(
            workspaceSession: session,
            service: service,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Generate Recipes'));
    await tester.tap(find.text('Generate Recipes'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(calls, 2);
    pending.complete(fixtures.result());
    await tester.pumpAndSettle();
    expect(find.text('Mock dish'), findsOneWidget);
    expect(find.text('Demo suggestions — sample data'), findsOneWidget);
    expect(
      find.text('Mock demo only. No AI provider is called.'),
      findsOneWidget,
    );
  });
  for (final entry in {
    'resource-exhausted':
        'AI request limit reached. Inventory remains available.',
    'unavailable':
        'AI suggestions are unavailable. Inventory remains available.',
    'deadline-exceeded': 'AI response timed out. No automatic retry was made.',
  }.entries) {
    testWidgets('${entry.key} safe UI', (tester) async {
      final session = fixtures.session();
      final service = SecureAiService(
        currentSession: () => session,
        transport: MockSecureAiTransport(
          (_) async => throw SecureAiTransportException(entry.key),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SecureAiSuggestions(
              workspaceSession: session,
              service: service,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Generate Recipes'));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Mock dish'), findsNothing);
    });
  }
  testWidgets('default unavailable is disabled without workspace/network', (
    tester,
  ) async {
    final service = SecureAiService(currentSession: () => null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecureAiSuggestions(workspaceSession: null, service: service),
        ),
      ),
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      find.textContaining('unavailable until secure service'),
      findsOneWidget,
    );
  });
  testWidgets('workspace replacement drops late result', (tester) async {
    var session = fixtures.session();
    final pending = Completer<Object?>();
    final service = SecureAiService(
      currentSession: () => session,
      transport: MockSecureAiTransport(
        (data) async =>
            data['operation'] == 'issue' ? fixtures.issued() : pending.future,
      ),
    );
    Widget page() => MaterialApp(
      home: Scaffold(
        body: SecureAiSuggestions(workspaceSession: session, service: service),
      ),
    );
    await tester.pumpWidget(page());
    await tester.tap(find.text('Generate Recipes'));
    await tester.pump();
    session = fixtures.session('b');
    await tester.pumpWidget(page());
    pending.complete(fixtures.result());
    await tester.pumpAndSettle();
    expect(find.text('Mock dish'), findsNothing);
    expect(find.text('View recipe'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'secure recipe details preserve fields and return without another request',
    (tester) async {
      final session = fixtures.session();
      final transport = _DetailTransport();
      final service = SecureAiService(
        currentSession: () => session,
        transport: transport,
      );
      await tester.pumpWidget(_detailApp(session, service));
      await _generateAndOpen(tester);
      final details = tester.widget<RecipePresentationDetails>(
        find.byType(RecipePresentationDetails),
      );
      expect(details.recipe.title, 'Mock dish');
      expect(details.recipe.ingredients.single.name, 'Ingredient ID: milk-id');
      expect(details.recipe.ingredients.single.quantity, '0.125');
      expect(details.recipe.ingredients.single.unit, 'L');
      expect(details.recipe.instructions, ['Stir for 4 minutes.']);
      expect(details.recipe.description, 'Uses eligible stock.');
      expect(details.recipe.preparation, isEmpty);
      expect(
        find.text('Injected mock recipe - no AI provider was called.'),
        findsOneWidget,
      );
      expect(find.textContaining('Sample recipe'), findsNothing);
      expect(find.text('Cook Now'), findsNothing);
      expect(transport.calls.length, 2);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Mock dish'), findsOneWidget);
      expect(transport.calls.length, 2);
    },
  );

  for (final replacement in [
    'identity',
    'account',
    'cafe',
    'generation',
    'service',
    'dispose',
    'invalidate',
  ]) {
    testWidgets('open details fail closed on $replacement and cannot revive', (
      tester,
    ) async {
      var session = fixtures.session();
      var service = SecureAiService(
        currentSession: () => session,
        transport: _DetailTransport(),
      );
      final home = ValueNotifier<Widget>(_detailPanel(session, service));
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<Widget>(
            valueListenable: home,
            builder: (_, child, _) => child,
          ),
        ),
      );
      await _generateAndOpen(tester);
      if (replacement == 'dispose') {
        home.value = const Scaffold(body: Text('Source removed'));
      } else {
        if (replacement == 'invalidate') {
          session.invalidate();
        } else if (replacement == 'service') {
          service = SecureAiService(
            currentSession: () => session,
            transport: _DetailTransport(),
          );
        } else {
          session = WorkspaceSession.fromVerified(
            CafeWorkspace(
              cafeId: replacement == 'cafe' ? 'b' : 'a',
              uid: replacement == 'account' ? 'other-user' : 'staff',
              ownerUid: 'owner',
              role: CafeRole.staff,
              membershipGeneration: replacement == 'generation' ? 1 : 0,
            ),
          );
        }
        home.value = _detailPanel(session, service);
      }
      await tester.pumpAndSettle();
      expect(find.text('Mock dish'), findsNothing);
      expect(
        find.text(
          'This recipe is no longer available because workspace access changed.',
        ),
        findsOneWidget,
      );
      home.value = _detailPanel(session, service);
      await tester.pumpAndSettle();
      expect(find.text('Mock dish'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      home.dispose();
    });
  }

  testWidgets('captured detail action rejects a replaced service session', (
    tester,
  ) async {
    var session = fixtures.session();
    final service = SecureAiService(
      currentSession: () => session,
      transport: _DetailTransport(),
    );
    await tester.pumpWidget(_detailApp(session, service));
    await tester.tap(find.text('Generate Recipes'));
    await tester.pumpAndSettle();
    final action = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'View recipe'))
        .onPressed!;
    session = fixtures.session('b');
    action();
    await tester.pumpAndSettle();
    expect(find.byType(RecipePresentationDetails), findsNothing);
  });

  for (final event in ['logout', 'revocation']) {
    testWidgets('workspace boundary removes secure details on $event', (
      tester,
    ) async {
      final ids = StreamController<String?>.broadcast();
      final authority = StreamController<bool>.broadcast();
      final session = fixtures.session();
      final service = SecureAiService(
        currentSession: () => session,
        transport: _DetailTransport(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceSessionBoundary(
            session: session,
            identities: ids.stream,
            authority: authority.stream,
            resolve: () async => CafeWorkspace(
              cafeId: session.cafeId,
              uid: session.uid,
              ownerUid: session.ownerUid,
              role: session.role,
              membershipGeneration: session.membershipGeneration,
            ),
            child: _detailPanel(session, service),
          ),
        ),
      );
      authority.add(true);
      await tester.pumpAndSettle();
      await _generateAndOpen(tester);
      if (event == 'logout') {
        ids.add(null);
      } else {
        authority.add(false);
      }
      await tester.pumpAndSettle();
      expect(find.byType(RecipePresentationDetails), findsNothing);
      expect(find.text('Mock dish'), findsNothing);
      expect(session.isActive, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      unawaited(ids.close());
      unawaited(authority.close());
    });
  }

  for (final mode in ['loading', 'empty', 'invalid']) {
    testWidgets('$mode results expose no detail action', (tester) async {
      final pending = Completer<Object?>();
      final session = fixtures.session();
      final service = SecureAiService(
        currentSession: () => session,
        transport: MockSecureAiTransport((data) async {
          if (data['operation'] == 'issue') return fixtures.issued();
          if (mode == 'loading') return pending.future;
          if (mode == 'invalid') return {'invalid': true};
          return {
            ...fixtures.result(),
            'status': 'no_suggestions',
            'recipes': [],
          };
        }),
      );
      await tester.pumpWidget(_detailApp(session, service));
      expect(find.text('View recipe'), findsNothing);
      await tester.tap(find.text('Generate Recipes'));
      if (mode == 'loading') {
        await tester.pump();
      } else {
        await tester.pumpAndSettle();
      }
      expect(find.text('View recipe'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      if (mode == 'loading') {
        pending.complete(fixtures.result());
        await tester.pump();
      }
    });
  }
}

Widget _detailPanel(WorkspaceSession session, SecureAiService service) =>
    Scaffold(
      body: SingleChildScrollView(
        child: SecureAiSuggestions(workspaceSession: session, service: service),
      ),
    );
Widget _detailApp(WorkspaceSession session, SecureAiService service) =>
    MaterialApp(home: _detailPanel(session, service));
Future<void> _generateAndOpen(WidgetTester tester) async {
  await tester.tap(find.text('Generate Recipes'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('View recipe'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('View recipe'));
  await tester.pumpAndSettle();
  expect(find.byType(RecipePresentationDetails), findsOneWidget);
}

class _DetailTransport implements SecureAiTransport {
  final calls = <Map<String, Object>>[];
  @override
  bool get available => true;
  @override
  bool get isDemo => true;
  @override
  Future<Object?> call(Map<String, Object> data) async {
    calls.add(data);
    if (data['operation'] == 'issue') return fixtures.issued();
    return {
      ...fixtures.result(),
      'recipes': [
        {
          'title': 'Mock dish',
          'ingredients': [
            {'itemId': 'milk-id', 'quantity': 0.125, 'unit': 'L'},
          ],
          'steps': ['Stir for 4 minutes.'],
          'whyRecommended': 'Uses eligible stock.',
        },
      ],
    };
  }
}
