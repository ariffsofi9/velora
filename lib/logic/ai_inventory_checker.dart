import '../models/inventory_item.dart';
import 'ai_cache_service.dart';

class AiInventoryChecker {
  final AiCacheService _cacheService = AiCacheService();

  bool isInventoryChanged({
    required List<InventoryItem> items,
    required String lastSignature,
    required String resultText,
  }) {
    if (resultText.isEmpty || lastSignature.isEmpty) return false;

    final lower = resultText.toLowerCase();

    if (lower.contains('failed') ||
        lower.contains('rate limit') ||
        lower.contains('quota') ||
        lower.contains('error')) {
      return false;
    }

    final current = _cacheService.buildCurrentSignature(items);

    return current != lastSignature;
  }
}
