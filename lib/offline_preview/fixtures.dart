import 'package:flutter/material.dart';

import '../models/inventory_item.dart';

enum PreviewRole { owner, staff }

enum PreviewScenario {
  cafe('Café samples'),
  bakery('Bakery samples'),
  restaurant('Restaurant samples'),
  loading('Loading inventory'),
  empty('Empty inventory'),
  error('Inventory error');

  const PreviewScenario(this.label);
  final String label;
}

typedef _Sample = (
  String name,
  String category,
  int quantity,
  String unit,
  int expiryDays,
  int used,
);
typedef PreviewMovement = (String label, int delta, int balance, DateTime date);

class PreviewRecipe {
  const PreviewRecipe(
    this.title,
    this.category,
    this.minutes,
    this.icon,
    this.ingredients,
    this.preparation,
  );

  final String title;
  final String category;
  final int minutes;
  final IconData icon;
  final List<String> ingredients;
  final String preparation;
}

final class OfflinePreviewFixtures {
  final DateTime now;
  const OfflinePreviewFixtures(this.now);

  static const team = [
    ('Aisyah Rahman', 'Owner'),
    ('Amir Tan', 'Staff'),
    ('Siti Lim', 'Staff'),
  ];

  static const recipes = [
    PreviewRecipe(
      'Tomato Pasta',
      'Main Dish',
      25,
      Icons.dinner_dining,
      ['Tomatoes', 'Pasta', 'Olive oil'],
      'Simmer the tomatoes, then toss the sauce with cooked pasta.',
    ),
    PreviewRecipe(
      'Vegetable Fried Rice',
      'Main Dish',
      20,
      Icons.rice_bowl_outlined,
      ['Rice', 'Carrot', 'Spring onion'],
      'Stir-fry the vegetables and fold in the cooked rice.',
    ),
    PreviewRecipe(
      'Iced Oat Latte',
      'Drink',
      5,
      Icons.local_cafe_outlined,
      ['Coffee', 'Oat milk', 'Ice'],
      'Pour oat milk over ice and finish with a shot of coffee.',
    ),
  ];

  List<InventoryItem> inventory(PreviewScenario scenario) => [
    for (final (name, category, quantity, unit, expiryDays, _) in _samples(
      scenario,
    ))
      InventoryItem(
        id: name,
        name: name,
        category: category,
        quantity: quantity,
        unit: unit,
        expiryDate: DateTime(now.year, now.month, now.day + expiryDays),
        imageUrl: '',
        createdAt: now.subtract(const Duration(days: 2)),
      ),
  ];

  List<PreviewMovement> history(PreviewScenario scenario, InventoryItem item) {
    for (final (name, _, quantity, _, _, used) in _samples(scenario)) {
      if (name != item.id) continue;
      return [
        if (used > 0)
          (
            'Stock out',
            -used,
            quantity,
            now.subtract(const Duration(hours: 2)),
          ),
        ('Initial stock', quantity + used, quantity + used, item.createdAt),
      ];
    }
    return const [];
  }

  List<_Sample> _samples(PreviewScenario scenario) => switch (scenario) {
    PreviewScenario.cafe => const [
      ('Arabica beans', 'Coffee', 8, 'kg', 31, 2),
      ('Oat milk', 'Dairy alternatives', 4, 'L', 2, 3),
      ('Vanilla syrup', 'Beverages', 6, 'bottles', 19, 0),
    ],
    PreviewScenario.bakery => const [
      ('Bread flour', 'Grains', 20, 'kg', 55, 5),
      ('Unsalted butter', 'Dairy', 3, 'kg', 1, 1),
      ('Fresh yeast', 'Baking supplies', 5, 'packs', -1, 2),
    ],
    PreviewScenario.restaurant => const [
      ('Chicken breast', 'Meat', 12, 'kg', 2, 4),
      ('Cherry tomatoes', 'Vegetables', 4, 'kg', 3, 2),
      ('Jasmine rice', 'Grains', 30, 'kg', 72, 6),
    ],
    PreviewScenario.loading ||
    PreviewScenario.empty ||
    PreviewScenario.error => const [],
  };
}
