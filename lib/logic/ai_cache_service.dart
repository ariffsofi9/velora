import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/inventory_item.dart';

class AiCacheService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// 🔍 GET CACHE
  Future<Map<String, dynamic>?> getCacheDoc({
    required String type,
    required List<InventoryItem> items,
  }) async {
    final key = _buildCacheKey(type, items);

    final doc = await _firestore.collection('ai_cache').doc(key).get();

    if (!doc.exists) return null;

    final data = doc.data();
    if (data == null) return null;

    final createdAt = data['createdAt'];
    if (createdAt is! Timestamp) return null;

    final age = DateTime.now().difference(createdAt.toDate());

    /// expire after 24h
    if (age.inHours > 24) return null;

    return data;
  }

  Future<String?> getCachedResult({
    required String type,
    required List<InventoryItem> items,
  }) async {
    final data = await getCacheDoc(type: type, items: items);

    if (data == null) return null;

    final result = data['result'];

    if (result == null || _isBadResult(result.toString())) {
      return null;
    }

    return result;
  }

  Future<String?> getCachedSignature({
    required String type,
    required List<InventoryItem> items,
  }) async {
    final data = await getCacheDoc(type: type, items: items);
    return data?['signature'];
  }

  /// 💾 SAVE
  Future<void> saveResult({
    required String type,
    required List<InventoryItem> items,
    required String result,
  }) async {
    if (_isBadResult(result)) return;

    final key = _buildCacheKey(type, items);

    await _firestore.collection('ai_cache').doc(key).set({
      'type': type,
      'result': result,
      'signature': _buildSignature(items),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  bool _isBadResult(String text) {
    final lower = text.toLowerCase();

    return lower.contains('failed') ||
        lower.contains('rate limit') ||
        lower.contains('quota') ||
        lower.contains('api key') ||
        lower.contains('try again');
  }

  String _buildCacheKey(String type, List<InventoryItem> items) {
    final signature = '$type-${_buildSignature(items)}';
    return _simpleHash(signature);
  }

  String buildCurrentSignature(List<InventoryItem> items) {
    return _buildSignature(items);
  }

  String _buildSignature(List<InventoryItem> items) {
    final sorted = [...items]..sort((a, b) => a.name.compareTo(b.name));

    return sorted
        .map((item) {
          final date = item.expiryDate.toIso8601String().split('T').first;
          return '${item.name}_${item.quantity}_$date';
        })
        .join('|');
  }

  String _simpleHash(String input) {
    var hash = 5381;
    for (final c in input.codeUnits) {
      hash = ((hash << 5) + hash) + c;
      hash = hash & 0x7fffffff;
    }
    return hash.toString();
  }
}
