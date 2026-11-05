import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import '../models/fake_recipe_response.dart';
import '../models/cafe_workspace.dart';
import 'firebase_emulator_config.dart';
import 'workspace_resolver.dart';
import 'workspace_session.dart';

enum RecipeClientFailure {
  disabled,
  authentication,
  membership,
  contextChanged,
  duplicate,
  limited,
  invalidRequest,
  invalidResponse,
  unavailable,
}

class RecipeClientException implements Exception {
  final RecipeClientFailure failure;
  const RecipeClientException(this.failure);
  @override
  String toString() => 'Fake recipe connectivity failed: ${failure.name}.';
}

abstract interface class FakeRecipeCallable {
  String get projectId;
  Future<Map<String, dynamic>> invoke(Map<String, Object> data);
}

class FirebaseFakeRecipeCallable implements FakeRecipeCallable {
  @override
  String get projectId => Firebase.app().options.projectId;
  @override
  Future<Map<String, dynamic>> invoke(Map<String, Object> data) async {
    // Enforce routing here as well as at application startup. No production URL.
    if (!FirebaseEmulatorConfig.recipeConnectivity ||
        FirebaseEmulatorConfig.ai1Mock ||
        !FirebaseEmulatorConfig.enabled ||
        FirebaseEmulatorConfig.staffDemo ||
        FirebaseEmulatorConfig.host != '127.0.0.1' ||
        projectId != FirebaseEmulatorConfig.recipeProject) {
      throw const RecipeClientException(RecipeClientFailure.disabled);
    }
    final functions = FirebaseFunctions.instanceFor(
      app: Firebase.app(),
      region: 'asia-southeast1',
    );
    functions.useFunctionsEmulator('127.0.0.1', 45001);
    return (await functions
            .httpsCallable('suggestRecipes')
            .call<Map<String, dynamic>>(data))
        .data;
  }
}

class FakeRecipeClient {
  static const profileEnabled =
      FirebaseEmulatorConfig.recipeConnectivity &&
      FirebaseEmulatorConfig.enabled &&
      !FirebaseEmulatorConfig.staffDemo &&
      !FirebaseEmulatorConfig.ai1Mock &&
      FirebaseEmulatorConfig.host == '127.0.0.1';
  final WorkspaceSession session;
  final FirebaseAuth? auth;
  final WorkspaceResolver? resolver;
  final FakeRecipeCallable? callable;
  FakeRecipeClient({
    required this.session,
    this.auth,
    this.resolver,
    this.callable,
  });
  FirebaseAuth get _auth => auth ?? FirebaseAuth.instance;

  /// UI convenience only; authorization is always repeated by generate/backend.
  bool get isAvailable {
    if (!profileEnabled) return false;
    try {
      return (callable ?? FirebaseFakeRecipeCallable()).projectId ==
              FirebaseEmulatorConfig.recipeProject &&
          _auth.currentUser?.uid == session.uid;
    } catch (_) {
      return false;
    }
  }

  Stream<User?> get authChanges => _auth.authStateChanges();
  Future<void> _authorize() async {
    if (_auth.currentUser?.uid != session.uid) {
      throw const RecipeClientException(RecipeClientFailure.authentication);
    }
    final context = await (resolver ?? WorkspaceResolver(auth: _auth))
        .resolve();
    if (_auth.currentUser?.uid != session.uid ||
        context.uid != session.uid ||
        context.cafeId != session.cafeId ||
        context.ownerUid != session.ownerUid ||
        context.role != session.role) {
      throw const RecipeClientException(RecipeClientFailure.contextChanged);
    }
  }

  Future<FakeRecipeResponse> generate({
    required String requestId,
    int maxRecipes = 1,
  }) async {
    // Check compile-time opt-in before accessing Firebase, Auth or transport.
    if (!FirebaseEmulatorConfig.recipeConnectivity ||
        FirebaseEmulatorConfig.ai1Mock ||
        !FirebaseEmulatorConfig.enabled ||
        FirebaseEmulatorConfig.staffDemo ||
        FirebaseEmulatorConfig.host != '127.0.0.1') {
      throw const RecipeClientException(RecipeClientFailure.disabled);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(requestId) ||
        maxRecipes < 1 ||
        maxRecipes > 3) {
      throw const RecipeClientException(RecipeClientFailure.invalidRequest);
    }
    final transport = callable ?? FirebaseFakeRecipeCallable();
    if (transport.projectId != FirebaseEmulatorConfig.recipeProject) {
      throw const RecipeClientException(RecipeClientFailure.disabled);
    }
    final response = await withVerifiedSession(
      () =>
          transport.invoke({'requestId': requestId, 'maxRecipes': maxRecipes}),
    );
    try {
      return FakeRecipeResponse.parse(response, requestId, maxRecipes);
    } catch (_) {
      throw const RecipeClientException(RecipeClientFailure.invalidResponse);
    }
  }

  /// Shared session validation only. Each transport must enforce its own profile
  /// and project before calling this method. No role/cafe authority is sent.
  Future<T> withVerifiedSession<T>(Future<T> Function() action) async {
    var changed = false;
    var uid = _auth.currentUser?.uid;
    final subscription = _auth.authStateChanges().listen(
      (user) {
        if (user?.uid != uid) changed = true;
        uid = user?.uid;
      },
      onError: (Object _) {
        changed = true;
      },
    );
    try {
      await _authorize();
      if (changed) {
        throw const RecipeClientException(RecipeClientFailure.contextChanged);
      }
      final response = await action();
      await _authorize();
      if (changed) {
        throw const RecipeClientException(RecipeClientFailure.contextChanged);
      }
      return response;
    } on RecipeClientException {
      rethrow;
    } on WorkspaceResolutionException catch (error) {
      throw RecipeClientException(
        error.failure == WorkspaceFailure.unavailable
            ? RecipeClientFailure.unavailable
            : RecipeClientFailure.membership,
      );
    } on FirebaseFunctionsException catch (error) {
      throw RecipeClientException(switch (error.code) {
        'unauthenticated' => RecipeClientFailure.authentication,
        'permission-denied' => RecipeClientFailure.membership,
        'aborted' => RecipeClientFailure.contextChanged,
        'already-exists' => RecipeClientFailure.duplicate,
        'resource-exhausted' => RecipeClientFailure.limited,
        'invalid-argument' => RecipeClientFailure.invalidRequest,
        'failed-precondition' => RecipeClientFailure.disabled,
        _ => RecipeClientFailure.unavailable,
      });
    } catch (_) {
      throw const RecipeClientException(RecipeClientFailure.unavailable);
    } finally {
      await subscription.cancel();
    }
  }
}
