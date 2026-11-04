import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/suggestions/suggestions_page.dart';
import 'package:velora/screens/suggestions/widgets_suggestions/recipe_suggestions_content.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Source implements WorkspaceInventoryDataSource {
  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) =>
      throw StateError('Presentation must not perform one-shot reads.');
  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) =>
      Stream.value([
        WorkspaceInventoryDocument(
          id: 'milk',
          data: {
            'name': 'Fresh Milk',
            'category': 'Dairy',
            'quantity': 1,
            'unit': 'L',
            'expiryDate': DateTime.now().add(const Duration(days: 1)),
            'createdAt': DateTime(2026),
            'imageUrl': '',
          },
        ),
      ]);
}

Widget _app(Widget child, double scale) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, widget) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: widget!,
  ),
  home: child,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'demo state selection and retry stay local at 320px and doubled text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 852);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: RecipeSuggestionsContent(),
            ),
          ),
          2,
        ),
      );
      await tester.ensureVisible(find.text('Preview sample recipes'));
      await tester.tap(find.text('Preview sample recipes'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<RecipeDemoState>),
      );
      await tester.tap(find.byType(DropdownButtonFormField<RecipeDemoState>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Loading').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Loading sample preview…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<RecipeDemoState>),
      );
      await tester.tap(find.byType(DropdownButtonFormField<RecipeDemoState>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Error').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Retry preview'));
      await tester.tap(find.text('Retry preview'));
      await tester.pumpAndSettle();
      expect(find.text(sampleRecipe.title), findsOneWidget);
      await tester.ensureVisible(find.text('Close preview'));
      await tester.tap(find.text('Close preview'));
      await tester.pumpAndSettle();
      expect(find.text(sampleRecipe.title), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Generate Recipes'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'recipe details meet labelled target, target size and text contrast guidelines',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _app(const RecipePresentationDetails(recipe: sampleRecipe), 1),
        );
        await tester.pumpAndSettle();
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      } finally {
        semantics.dispose();
      }
    },
  );
  for (final width in [320.0, 393.0, 768.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      void viewport(WidgetTester tester) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 852);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      for (final state in RecipeDemoState.values) {
        testWidgets('Demo ${state.name} fits $width at ${scale}x', (
          tester,
        ) async {
          viewport(tester);
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: RecipeDemoResult(state: state, onRetry: () {}),
                ),
              ),
              scale,
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byType(Image), findsNothing);
          if (state == RecipeDemoState.results) {
            expect(find.text(sampleRecipe.title), findsOneWidget);
          }
        });
      }
      testWidgets(
        'Recipe Details fits $width at ${scale}x and expands without fabricated data',
        (tester) async {
          viewport(tester);
          await tester.pumpWidget(
            _app(const RecipePresentationDetails(recipe: sampleRecipe), scale),
          );
          await tester.pumpAndSettle();
          expect(find.text('No recipe image provided'), findsOneWidget);
          expect(find.byType(Image), findsNothing);
          await tester.scrollUntilVisible(find.text('Ingredients'), 150);
          await tester.tap(find.text('Ingredients'));
          await tester.pumpAndSettle();
          expect(find.text('1 pcs · Banana'), findsNothing);
          await tester.tap(find.text('Ingredients'));
          await tester.pumpAndSettle();
          expect(find.text('200 ml · Milk'), findsOneWidget);
          await tester.scrollUntilVisible(find.text('How to Make It'), 150);
          await tester.pumpAndSettle();
          expect(find.text(sampleRecipe.instructions.last), findsOneWidget);
          expect(find.text('Cook Now'), findsNothing);
          expect(find.text('Save Recipe'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'AI Tips with live insights and demo controls fits $width at ${scale}x',
        (tester) async {
          viewport(tester);
          final session = WorkspaceSession.fromVerified(
            const CafeWorkspace(
              cafeId: 'demo',
              uid: 'staff',
              ownerUid: 'owner',
              role: CafeRole.staff,
            ),
          );
          await tester.pumpWidget(
            _app(
              SuggestionsPage(
                workspaceSession: session,
                repository: WorkspaceInventoryRepository(
                  session: session,
                  dataSource: _Source(),
                ),
              ),
              scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Generate Recipes'),
                )
                .onPressed,
            isNull,
          );
          await tester.ensureVisible(find.text('Preview sample recipes'));
          await tester.tap(find.text('Preview sample recipes'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(sampleRecipe.title));
          await tester.tap(find.text(sampleRecipe.title));
          await tester.pumpAndSettle();
          expect(find.text('Recipe Details'), findsOneWidget);
          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Fresh Milk').first);
          expect(find.text('Fresh Milk'), findsWidgets);
          expect(find.text('Smart Restock Suggestions'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'missing details are explicit; exact decimal quantities and supplied cues survive',
    (tester) async {
      const recipe = RecipePresentation(
        title: 'Supplied recipe',
        ingredients: [RecipeIngredientPresentation('Milk', '0.125', 'L')],
        instructions: ['Simmer for 4 minutes, stirring, until thickened.'],
      );
      await tester.pumpWidget(
        _app(const RecipePresentationDetails(recipe: recipe), 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('0.125 L · Milk'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Preparation'), 150);
      expect(find.text('No preparation notes supplied.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(recipe.instructions.single),
        150,
      );
      expect(find.text(recipe.instructions.single), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.star), findsNothing);
      expect(find.byIcon(Icons.share), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
