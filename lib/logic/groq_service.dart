/// Disabled compatibility shim for legacy suggestion internals.
/// Secure AI access belongs to the injected SecureAiService boundary.
class GroqService {
  GroqService();

  Future<Map<String, dynamic>> generateRecipes({
    required List<Map<String, dynamic>> inventoryItems,
  }) async => {
    'status': 'error',
    'message':
        'AI service is unavailable. No direct provider request was made.',
    'recipes': <Map<String, dynamic>>[],
  };
}
