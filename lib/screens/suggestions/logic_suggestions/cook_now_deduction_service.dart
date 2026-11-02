import 'package:cloud_firestore/cloud_firestore.dart';

class CookNowDeductionResult {
  final bool success;
  final String message;
  final List<String> usedItems;
  final List<String> skippedItems;

  const CookNowDeductionResult({
    required this.success,
    required this.message,
    required this.usedItems,
    required this.skippedItems,
  });
}

class CookNowDeductionService {
  static const bool isSupported = false;
  static const String unavailableMessage =
      'Cook Now is unavailable until secure workspace inventory deduction is enabled.';

  // Keep the optional argument temporarily for compatibility with tests or
  // callers that previously injected Firestore. It is deliberately unused.
  CookNowDeductionService({FirebaseFirestore? firestore});

  Future<CookNowDeductionResult> deductRecipeIngredients({
    required String userId,
    required String recipeTitle,
    required List<String> ingredients,
    required int portions,
  }) async => const CookNowDeductionResult(
    success: false,
    message: unavailableMessage,
    usedItems: [],
    skippedItems: [],
  );
}
