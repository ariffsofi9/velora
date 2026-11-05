import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/secure_ai_suggestions.dart';
import 'package:velora/services/secure_ai_service.dart';
import 'secure_ai_service_test.dart' as fixtures;

class _Inventory extends Fake implements WorkspaceInventoryRepository {
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
            repository: _Inventory(),
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
    expect(tester.takeException(), isNull);
  });
}
