import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/groq_recipe_response.dart';
import 'fake_recipe_client.dart';
import 'firebase_emulator_config.dart';
import 'workspace_resolver.dart';
import 'workspace_session.dart';

class FirebaseAi1MockCallable implements FakeRecipeCallable {
  @override
  String get projectId => Firebase.app().options.projectId;
  @override
  Future<Map<String, dynamic>> invoke(Map<String, Object> data) async {
    if (!Ai1MockRecipeClient.profileEnabled ||
        projectId != FirebaseEmulatorConfig.ai1Project) {
      throw const RecipeClientException(RecipeClientFailure.disabled);
    }
    final functions = FirebaseFunctions.instanceFor(region: 'asia-southeast1');
    functions.useFunctionsEmulator('127.0.0.1', 15001);
    return (await functions
            .httpsCallable('suggestMockRecipesV2')
            .call<Map<String, dynamic>>(data))
        .data;
  }
}

/// Mock-only endpoint. A v2 contract is not evidence of a real Groq response.
class Ai1MockRecipeClient {
  static const profileEnabled =
      FirebaseEmulatorConfig.ai1Mock &&
      FirebaseEmulatorConfig.enabled &&
      !FirebaseEmulatorConfig.conflictingProfiles &&
      FirebaseEmulatorConfig.host == '127.0.0.1';
  final WorkspaceSession session;
  final FakeRecipeCallable? callable;
  late final FakeRecipeClient _identity;
  Ai1MockRecipeClient({
    required this.session,
    FirebaseAuth? auth,
    WorkspaceResolver? resolver,
    this.callable,
  }) {
    _identity = FakeRecipeClient(
      session: session,
      auth: auth,
      resolver: resolver,
    );
  }
  bool get isAvailable {
    if (!profileEnabled) return false;
    try {
      return (callable ?? FirebaseAi1MockCallable()).projectId ==
              FirebaseEmulatorConfig.ai1Project &&
          (_identity.auth ?? FirebaseAuth.instance).currentUser?.uid ==
              session.uid;
    } catch (_) {
      return false;
    }
  }

  Stream<User?> get authChanges => _identity.authChanges;
  Future<GroqRecipeResponse> generate({
    required String requestId,
    int maxRecipes = 1,
  }) async {
    if (!profileEnabled) {
      throw const RecipeClientException(RecipeClientFailure.disabled);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(requestId) ||
        maxRecipes < 1 ||
        maxRecipes > 3) {
      throw const RecipeClientException(RecipeClientFailure.invalidRequest);
    }
    final transport = callable ?? FirebaseAi1MockCallable();
    if (transport.projectId != FirebaseEmulatorConfig.ai1Project) {
      throw const RecipeClientException(RecipeClientFailure.disabled);
    }
    final raw = await _identity.withVerifiedSession(
      () =>
          transport.invoke({'requestId': requestId, 'maxRecipes': maxRecipes}),
    );
    try {
      return GroqRecipeResponse.parse(raw, requestId, maxRecipes);
    } catch (_) {
      throw const RecipeClientException(RecipeClientFailure.invalidResponse);
    }
  }
}
