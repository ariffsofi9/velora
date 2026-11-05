import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/groq_recipe_response.dart';
import 'package:velora/models/fake_recipe_response.dart';

const requestId = 'schema-v2-request-0001';
Map<String, dynamic> payload() => {
  'schemaVersion': 2,
  'provider': 'groq',
  'requestId': requestId,
  'status': 'ok',
  'recipes': [
    {
      'title': 'Smoothie',
      'whyRecommended': 'Uses available ingredients.',
      'ingredients': [
        {'itemId': 'milk', 'quantity': 0.25, 'unit': 'L'},
        {'itemId': 'banana', 'quantity': 1, 'unit': 'pcs'},
      ],
      'steps': ['Blend supplied ingredients.'],
    },
  ],
};
void main() {
  test('valid JSON v2 retains exact quantities, units and immutable lists', () {
    final result = GroqRecipeResponse.parse(
      jsonDecode(jsonEncode(payload())),
      requestId,
      1,
    );
    expect(result.recipes.single.ingredients.first.quantity, 0.25);
    expect(result.recipes.single.ingredients.first.unit, 'L');
    expect(() => result.recipes.clear(), throwsUnsupportedError);
    expect(
      () => result.recipes.single.ingredients.clear(),
      throwsUnsupportedError,
    );
    expect(() => result.recipes.single.steps.clear(), throwsUnsupportedError);
  });
  test('empty response remains empty with no invented fallback', () {
    expect(
      GroqRecipeResponse.parse(
        {...payload(), 'status': 'no_suggestions', 'recipes': []},
        requestId,
        1,
      ).recipes,
      isEmpty,
    );
  });
  final malformed = <String, void Function(Map<String, dynamic>)>{
    'fake provider': (p) => p['provider'] = 'fake',
    'v1': (p) => p['schemaVersion'] = 1,
    'noninteger schema': (p) => p['schemaVersion'] = 2.0,
    'mismatched request': (p) => p['requestId'] = 'other',
    'unknown top field': (p) => p['cache'] = true,
    'missing top field': (p) => p.remove('requestId'),
    'invalid status': (p) => p['status'] = 'cached',
    'inconsistent status': (p) => p['status'] = 'no_suggestions',
    'empty ok': (p) => p['recipes'] = [],
    'too many recipes': (p) => p['recipes'] = List.filled(4, p['recipes'][0]),
    'unknown recipe field': (p) =>
        p['recipes'][0]['ingredientItemIds'] = ['milk'],
    'blank title': (p) => p['recipes'][0]['title'] = ' ',
    'long title': (p) => p['recipes'][0]['title'] = 'a' * 101,
    'missing explanation': (p) => p['recipes'][0].remove('whyRecommended'),
    'long explanation': (p) => p['recipes'][0]['whyRecommended'] = 'a' * 301,
    'empty steps': (p) => p['recipes'][0]['steps'] = [],
    'too many steps': (p) => p['recipes'][0]['steps'] = List.filled(9, 'Step'),
    'long step': (p) => p['recipes'][0]['steps'] = ['a' * 301],
    'control text': (p) => p['recipes'][0]['steps'] = ['bad\nstep'],
    'bidi text': (p) => p['recipes'][0]['title'] = 'bad\u202ename',
    'nontext step': (p) => p['recipes'][0]['steps'] = [1],
    'empty ingredients': (p) => p['recipes'][0]['ingredients'] = [],
    'too many ingredients': (p) => p['recipes'][0]['ingredients'] = List.filled(
      11,
      {'itemId': 'milk', 'quantity': 1, 'unit': 'L'},
    ),
    'duplicate ID': (p) => p['recipes'][0]['ingredients'][1]['itemId'] = 'milk',
    'invalid ID': (p) =>
        p['recipes'][0]['ingredients'][0]['itemId'] = '../milk',
    'unknown ingredient field': (p) =>
        p['recipes'][0]['ingredients'][0]['name'] = 'Milk',
    'missing unit': (p) => p['recipes'][0]['ingredients'][0].remove('unit'),
    'invalid unit': (p) => p['recipes'][0]['ingredients'][0]['unit'] = 'cups',
    'zero quantity': (p) => p['recipes'][0]['ingredients'][0]['quantity'] = 0,
    'negative quantity': (p) =>
        p['recipes'][0]['ingredients'][0]['quantity'] = -1,
    'string quantity': (p) =>
        p['recipes'][0]['ingredients'][0]['quantity'] = '1',
    'boolean quantity': (p) =>
        p['recipes'][0]['ingredients'][0]['quantity'] = true,
    'NaN quantity': (p) =>
        p['recipes'][0]['ingredients'][0]['quantity'] = double.nan,
    'infinite quantity': (p) =>
        p['recipes'][0]['ingredients'][0]['quantity'] = double.infinity,
    'oversized quantity': (p) =>
        p['recipes'][0]['ingredients'][0]['quantity'] = 1000001,
    'fractional pcs': (p) =>
        p['recipes'][0]['ingredients'][1]['quantity'] = 0.5,
  };
  for (final entry in malformed.entries) {
    test('reject ${entry.key}', () {
      final p = payload();
      entry.value(p);
      expect(
        () => GroqRecipeResponse.parse(p, requestId, 3),
        throwsFormatException,
      );
    });
  }
  test('invalid caller bounds and malformed containers fail closed', () {
    for (final value in [
      null,
      [],
      'json',
      {
        'recipes': [null],
      },
    ]) {
      expect(
        () => GroqRecipeResponse.parse(value, requestId, 1),
        throwsFormatException,
      );
    }
    for (final count in [0, 4]) {
      expect(
        () => GroqRecipeResponse.parse(payload(), requestId, count),
        throwsFormatException,
      );
    }
    expect(
      () => GroqRecipeResponse.parse(payload(), 'short', 1),
      throwsFormatException,
    );
    final p = payload();
    p['recipes'] = [p['recipes'][0], p['recipes'][0]];
    expect(
      () => GroqRecipeResponse.parse(p, requestId, 1),
      throwsFormatException,
    );
  });
  test('fake-v1 and Groq-v2 remain mutually incompatible', () {
    expect(
      () => FakeRecipeResponse.parse(payload(), requestId, 1),
      throwsFormatException,
    );
    final fake = {
      'schemaVersion': 1,
      'provider': 'fake',
      'requestId': requestId,
      'status': 'ok',
      'recipes': [
        {
          'title': 'Fixture',
          'ingredientItemIds': ['milk'],
          'steps': ['Supplied step.'],
          'whyRecommended': 'Fake.',
        },
      ],
    };
    expect(
      FakeRecipeResponse.parse(
        fake,
        requestId,
        1,
      ).recipes.single.ingredientItemIds,
      ['milk'],
    );
    expect(
      () => GroqRecipeResponse.parse(fake, requestId, 1),
      throwsFormatException,
    );
  });
}
