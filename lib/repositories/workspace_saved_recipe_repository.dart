import 'dart:async';
import '../models/saved_recipe.dart';
import '../services/workspace_session.dart';

enum SavedRecipeFailure {
  session,
  permission,
  stale,
  conflict,
  invalid,
  invalidData,
  notFound,
  unavailable,
}

class SavedRecipeException implements Exception {
  final SavedRecipeFailure failure;
  final bool outcomeUnknown;
  const SavedRecipeException(this.failure, {this.outcomeUnknown = false});
  @override
  String toString() => 'Saved recipes unavailable: ${failure.name}';
}

/// Trusted routing context, never server authority or a token verifier.
class SavedRecipeSession {
  final String projectId, uid;
  final int revision;
  final bool emailVerified;
  final WorkspaceSession workspace;
  const SavedRecipeSession({
    required this.projectId,
    required this.uid,
    required this.revision,
    required this.emailVerified,
    required this.workspace,
  });
  bool matches(SavedRecipeSession? other) =>
      other != null &&
      projectId == other.projectId &&
      uid == other.uid &&
      revision == other.revision &&
      emailVerified == other.emailVerified &&
      identical(workspace, other.workspace);
  bool get valid =>
      projectId == 'velora-spark-test' &&
      emailVerified &&
      SavedRecipeValidation.integer(revision) &&
      workspace.isActive &&
      SavedRecipeValidation.id(uid) &&
      uid == workspace.uid &&
      SavedRecipeValidation.id(workspace.cafeId) &&
      SavedRecipeValidation.id(workspace.ownerUid) &&
      SavedRecipeValidation.integer(workspace.membershipGeneration) &&
      workspace.isOwner == (uid == workspace.ownerUid);
}

/// Later transport owns fresh token acquisition, endpoint binding, redirect and
/// wire-byte limits. This port has no mutation operation and no SDK defaults.
abstract interface class SavedRecipeReadPort {
  Future<Object?> read(
    SavedRecipeSession session,
    String operation,
    Map<String, Object?> request,
  );
}

abstract interface class SavedRecipeObservationPort {
  Future<Object?> reconcile(
    SavedRecipeSession session,
    Map<String, Object?> request,
  );
}

class SessionSavedRecipeCursor {
  final SavedRecipeCursor wire;
  final SavedRecipeSession _session;
  SessionSavedRecipeCursor._(this.wire, this._session);
}

class SavedRecipesPage {
  final List<SavedRecipeSummary> items;
  final SessionSavedRecipeCursor? nextCursor;
  SavedRecipesPage._(this.items, this.nextCursor);
}

/// One session episode only. No HTTP/Firebase initialization, retries, digest
/// computation or durable recovery claims. Mutations always fail before I/O.
class WorkspaceSavedRecipeRepository {
  final SavedRecipeReadPort readPort;
  final SavedRecipeObservationPort observationPort;
  final SavedRecipeSession? Function() currentSession;
  final Duration timeout;
  late final SavedRecipeSession _session;
  late final StreamSubscription<SavedRecipeSession?> _subscription;
  final _changes = StreamController<void>.broadcast(sync: true);
  bool _invalid = false;
  Stream<void> get sessionChanges => _changes.stream;
  WorkspaceSavedRecipeRepository({
    required this.readPort,
    required this.observationPort,
    required this.currentSession,
    required Stream<SavedRecipeSession?> sessionChanges,
    this.timeout = const Duration(seconds: 15),
  }) {
    SavedRecipeSession? s;
    try {
      s = currentSession();
    } catch (_) {
      throw const SavedRecipeException(SavedRecipeFailure.session);
    }
    if (s == null ||
        !s.valid ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 30)) {
      throw const SavedRecipeException(SavedRecipeFailure.session);
    }
    _session = s;
    _subscription = sessionChanges.listen(
      (value) {
        if (!_session.matches(value) || value?.valid != true) _invalidate();
      },
      onError: (Object _) => _invalidate(),
      onDone: _invalidate,
    );
  }
  void _invalidate() {
    if (_invalid) return;
    _invalid = true;
    if (!_changes.isClosed) _changes.add(null);
  }

  void _check() {
    bool valid;
    try {
      valid = !_invalid && _session.valid && _session.matches(currentSession());
    } catch (_) {
      valid = false;
    }
    if (!valid) {
      _invalidate();
      throw const SavedRecipeException(SavedRecipeFailure.session);
    }
  }

  Map<String, Object?> get _expectations => Map.unmodifiable({
    'expectedCafeId': _session.workspace.cafeId,
    'expectedMembershipGeneration': _session.workspace.membershipGeneration,
  });

  Future<T> _perform<T>(
    Future<Object?> Function() dispatch,
    T Function(Object?) parse, {
    bool observation = false,
  }) async {
    try {
      _check();
      final raw = await Future<Object?>.sync(() {
        _check();
        return dispatch();
      }).timeout(timeout);
      _check();
      SavedRecipeValidation.bound(raw, 65536);
      final result = parse(raw);
      _check();
      return result;
    } on SavedRecipeException catch (error) {
      throw SavedRecipeException(
        error.failure,
        outcomeUnknown: observation || error.outcomeUnknown,
      );
    } on FormatException {
      throw SavedRecipeException(
        SavedRecipeFailure.invalidData,
        outcomeUnknown: observation,
      );
    } catch (_) {
      throw SavedRecipeException(
        SavedRecipeFailure.unavailable,
        outcomeUnknown: observation,
      );
    }
  }

  void _cursor(SavedRecipeCursor c, String mode, int limit) {
    final expected = {
      'projectId': _session.projectId,
      'cafeId': _session.workspace.cafeId,
      'uid': _session.uid,
      'membershipGeneration': _session.workspace.membershipGeneration,
      'mode': mode,
      'limit': limit,
    };
    if (expected.entries.any((e) => c.data[e.key] != e.value)) {
      SavedRecipeValidation.invalid();
    }
  }

  Future<SavedRecipesPage> list({
    required String mode,
    required int limit,
    SessionSavedRecipeCursor? cursor,
  }) async {
    _check();
    if (!['active', 'archived', 'all'].contains(mode) ||
        limit < 1 ||
        limit > 20 ||
        (cursor != null && !_session.matches(cursor._session))) {
      throw const SavedRecipeException(SavedRecipeFailure.invalid);
    }
    if (cursor != null) {
      try {
        _cursor(cursor.wire, mode, limit);
      } on FormatException {
        throw const SavedRecipeException(SavedRecipeFailure.invalid);
      }
    }
    final request = Map<String, Object?>.unmodifiable({
      ..._expectations,
      'mode': mode,
      'limit': limit,
      'cursor': cursor?.wire.data,
    });
    return _perform(() => readPort.read(_session, 'list', request), (raw) {
      final d = SavedRecipeValidation.fields(raw, [
        'schemaVersion',
        'cafeId',
        'items',
        'nextCursor',
      ]);
      if (d['schemaVersion'] != 1 ||
          d['cafeId'] != _session.workspace.cafeId ||
          d['items'] is! List ||
          (d['items'] as List).length > limit) {
        SavedRecipeValidation.invalid();
      }
      final items = (d['items'] as List).map(SavedRecipeSummary.parse).toList();
      var previous = cursor?.wire.afterId ?? '';
      for (final item in items) {
        if (item.recipeId.compareTo(previous) <= 0 ||
            (mode != 'all' && item.isArchived != (mode == 'archived'))) {
          SavedRecipeValidation.invalid();
        }
        previous = item.recipeId;
      }
      final next = d['nextCursor'] == null
          ? null
          : SavedRecipeCursor.parse(d['nextCursor']);
      if (next != null) {
        _cursor(next, mode, limit);
        if (items.length != limit || next.afterId != previous) {
          SavedRecipeValidation.invalid();
        }
      }
      return SavedRecipesPage._(
        List.unmodifiable(items),
        next == null ? null : SessionSavedRecipeCursor._(next, _session),
      );
    });
  }

  Future<SavedRecipe> get(String recipeId) async {
    _check();
    if (!SavedRecipeValidation.recipeId(recipeId)) {
      throw const SavedRecipeException(SavedRecipeFailure.invalid);
    }
    final request = Map<String, Object?>.unmodifiable({
      ..._expectations,
      'recipeId': recipeId,
    });
    return _perform(() => readPort.read(_session, 'get', request), (raw) {
      final d = SavedRecipeValidation.fields(raw, [
        'schemaVersion',
        'cafeId',
        'item',
      ]);
      if (d['schemaVersion'] != 1 || d['cafeId'] != _session.workspace.cafeId) {
        SavedRecipeValidation.invalid();
      }
      final item = SavedRecipe.parse(
        d['item'],
        projectId: _session.projectId,
        cafeId: _session.workspace.cafeId,
      );
      if (item.recipeId != recipeId) SavedRecipeValidation.invalid();
      return item;
    });
  }

  Future<SavedRecipeAcknowledgement> save(SavedRecipeSaveIntent intent) async {
    throw const SavedRecipeException(SavedRecipeFailure.unavailable);
  }

  Future<SavedRecipeAcknowledgement> lifecycle(
    SavedRecipeLifecycleIntent intent,
  ) async {
    throw const SavedRecipeException(SavedRecipeFailure.unavailable);
  }

  Future<SavedRecipeReconciliation> reconcile(
    SavedRecipeIntent originalIntent,
  ) async {
    try {
      _check();
    } on SavedRecipeException {
      throw const SavedRecipeException(
        SavedRecipeFailure.session,
        outcomeUnknown: true,
      );
    }
    if (originalIntent.request['expectedCafeId'] != _session.workspace.cafeId ||
        originalIntent.request['expectedMembershipGeneration'] !=
            _session.workspace.membershipGeneration) {
      throw const SavedRecipeException(
        SavedRecipeFailure.stale,
        outcomeUnknown: true,
      );
    }
    final request = Map<String, Object?>.unmodifiable({
      'operation': originalIntent.operation,
      'request': originalIntent.request,
    });
    return _perform(
      () => observationPort.reconcile(_session, request),
      (raw) => SavedRecipeReconciliation.parse(raw, originalIntent),
      observation: true,
    );
  }

  Future<void> dispose() async {
    _invalidate();
    try {
      await _subscription.cancel().timeout(timeout);
    } finally {
      unawaited(_changes.close());
    }
  }
}
