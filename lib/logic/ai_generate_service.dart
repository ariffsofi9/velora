import '../models/inventory_item.dart';
import 'ai_cache_service.dart';
import 'ai_quota_service.dart';

class AiGenerateService {
  final AiCacheService _cache = AiCacheService();
  final AiQuotaService _quota = AiQuotaService();

  Future<Map<String, dynamic>> generate({
    required String type,
    required List<InventoryItem> items,
    required Future<String> Function() fetcher,
  }) async {
    final cached = await _cache.getCachedResult(type: type, items: items);

    if (cached != null && cached.isNotEmpty) {
      return {
        'result': cached,
        'isCached': true,
        'signature': _cache.buildCurrentSignature(items),
      };
    }

    final result = await fetcher();

    if (_isError(result)) {
      return {'result': result, 'isError': true};
    }

    await _cache.saveResult(type: type, items: items, result: result);

    await _quota.addUsage();

    return {
      'result': result,
      'isCached': false,
      'signature': _cache.buildCurrentSignature(items),
    };
  }

  bool _isError(String text) {
    final lower = text.toLowerCase();

    return lower.contains('failed') ||
        lower.contains('rate limit') ||
        lower.contains('no ai suggestion') ||
        lower.contains('quota') ||
        lower.contains('api key') ||
        lower.contains('try again');
  }
}
