import '../models/inventory_item.dart';

class CookNowService {
  Future<void> cookRecipe(List<InventoryItem> usedItems) async {
    throw UnsupportedError(
      'Cook Now is unavailable until secure workspace inventory deduction is enabled.',
    );
  }
}
