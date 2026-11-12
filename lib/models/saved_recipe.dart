import 'dart:convert';

/// Wire validation only. Digest strings remain server evidence: this library
/// does not implement ECMAScript canonicalization or verify SHA-256 content.
abstract final class SavedRecipeValidation {
  static Never invalid() =>
      throw const FormatException('Invalid saved recipe data.');
  static Map<String, Object?> fields(Object? raw, List<String> keys) {
    if (raw is! Map ||
        raw.length != keys.length ||
        raw.keys.any((k) => k is! String || !keys.contains(k))) {
      invalid();
    }
    return Map<String, Object?>.from(raw);
  }

  static bool integer(Object? n, [int min = 0]) =>
      n is num &&
      n.isFinite &&
      n >= min &&
      n <= 9007199254740991 &&
      n == n.truncateToDouble();
  static bool text(Object? value, int max) {
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        value.trim() != value ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
      return false;
    }
    final units = value.codeUnits;
    for (var i = 0; i < units.length; i++) {
      if (units[i] >= 0xd800 && units[i] <= 0xdbff) {
        if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          return false;
        }
      } else if (units[i] >= 0xdc00 && units[i] <= 0xdfff) {
        return false;
      }
    }
    return true;
  }

  static bool id(Object? s) =>
      text(s, 128) &&
      s != '.' &&
      s != '..' &&
      !RegExp(r'[/\\]').hasMatch(s as String);
  static bool digest(Object? s) =>
      s is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(s);
  static bool recipeId(Object? s) =>
      s is String && RegExp(r'^recipe_[a-f0-9]{64}$').hasMatch(s);
  static void bound(Object? value, int max) {
    if (utf8.encode(jsonEncode(value)).length > max) invalid();
  }

  static String instant(Object? value) {
    if (value is! String ||
        !RegExp(
          r'^(?:\d{4}|[+-]\d{6})-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$',
        ).hasMatch(value)) {
      invalid();
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != value) {
      invalid();
    }
    return value;
  }

  static Object? freeze(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable(
        value.map((k, v) => MapEntry(k as String, freeze(v))),
      );
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(freeze));
    return value;
  }
}

class SavedRecipeIngredient {
  final String itemId, unit;
  final num quantity;
  SavedRecipeIngredient._(this.itemId, this.quantity, this.unit);
  factory SavedRecipeIngredient.parse(Object? raw) {
    final d = SavedRecipeValidation.fields(raw, ['itemId', 'quantity', 'unit']);
    final q = d['quantity'];
    if (!SavedRecipeValidation.id(d['itemId']) ||
        q is! num ||
        !q.isFinite ||
        q <= 0 ||
        q > 1000000 ||
        !['kg', 'g', 'L', 'ml', 'pcs'].contains(d['unit']) ||
        (d['unit'] == 'pcs' && q != q.truncateToDouble())) {
      SavedRecipeValidation.invalid();
    }
    return SavedRecipeIngredient._(
      d['itemId'] as String,
      q,
      d['unit'] as String,
    );
  }
  Map<String, Object?> toJson() =>
      Map.unmodifiable({'itemId': itemId, 'quantity': quantity, 'unit': unit});
}

class SavedRecipeContent {
  final String title, whyRecommended;
  final List<SavedRecipeIngredient> ingredients;
  final List<String> steps;
  SavedRecipeContent._(
    this.title,
    this.ingredients,
    this.steps,
    this.whyRecommended,
  );
  factory SavedRecipeContent.parse(Object? raw) {
    final d = SavedRecipeValidation.fields(raw, [
      'title',
      'ingredients',
      'steps',
      'whyRecommended',
    ]);
    final ingredients = d['ingredients'], steps = d['steps'];
    if (!SavedRecipeValidation.text(d['title'], 100) ||
        !SavedRecipeValidation.text(d['whyRecommended'], 300) ||
        ingredients is! List ||
        ingredients.isEmpty ||
        ingredients.length > 10 ||
        steps is! List ||
        steps.isEmpty ||
        steps.length > 8 ||
        steps.any((s) => !SavedRecipeValidation.text(s, 300))) {
      SavedRecipeValidation.invalid();
    }
    final parsed = ingredients.map(SavedRecipeIngredient.parse).toList();
    if (parsed.map((i) => i.itemId).toSet().length != parsed.length) {
      SavedRecipeValidation.invalid();
    }
    final result = SavedRecipeContent._(
      d['title'] as String,
      List.unmodifiable(parsed),
      List<String>.unmodifiable(steps),
      d['whyRecommended'] as String,
    );
    SavedRecipeValidation.bound(result.toJson(), 16384);
    return result;
  }
  Map<String, Object?> toJson() => Map.unmodifiable({
    'title': title,
    'ingredients': List.unmodifiable(ingredients.map((i) => i.toJson())),
    'steps': steps,
    'whyRecommended': whyRecommended,
  });
}

class SavedRecipeAttribution {
  final String kind;
  final String? provider, ticketId;
  SavedRecipeAttribution._(this.kind, this.provider, this.ticketId);
  factory SavedRecipeAttribution.parse(Object? raw) {
    final d = SavedRecipeValidation.fields(raw, [
      'kind',
      'provider',
      'ticketId',
    ]);
    if (!['unspecified', 'claimed-ai', 'sample', 'mock'].contains(d['kind']) ||
        ![null, 'groq'].contains(d['provider']) ||
        (d['ticketId'] != null &&
            !SavedRecipeValidation.digest(d['ticketId'])) ||
        (d['kind'] != 'claimed-ai' &&
            (d['provider'] != null || d['ticketId'] != null))) {
      SavedRecipeValidation.invalid();
    }
    return SavedRecipeAttribution._(
      d['kind'] as String,
      d['provider'] as String?,
      d['ticketId'] as String?,
    );
  }
  Map<String, Object?> toJson() => Map.unmodifiable({
    'kind': kind,
    'provider': provider,
    'ticketId': ticketId,
  });
}

class SavedRecipeProvenance {
  final String source, evidence;
  final SavedRecipeAttribution attribution;
  SavedRecipeProvenance._(this.source, this.evidence, this.attribution);
  factory SavedRecipeProvenance.parse(Map<String, Object?> data) {
    if (data['source'] != 'workspace-submitted' ||
        data['provenanceEvidence'] != 'unverified-attribution') {
      SavedRecipeValidation.invalid();
    }
    return SavedRecipeProvenance._(
      'workspace-submitted',
      'unverified-attribution',
      SavedRecipeAttribution.parse(data['submittedAttribution']),
    );
  }
}

class SavedRecipeSummary {
  final String recipeId, title, createdAt, updatedAt;
  final int version;
  final bool isArchived;
  final SavedRecipeProvenance provenance;
  SavedRecipeSummary._(
    this.recipeId,
    this.title,
    this.createdAt,
    this.updatedAt,
    this.version,
    this.isArchived,
    this.provenance,
  );
  factory SavedRecipeSummary.parse(Object? raw) {
    final d = SavedRecipeValidation.fields(raw, [
      'recipeId',
      'title',
      'source',
      'provenanceEvidence',
      'submittedAttribution',
      'version',
      'isArchived',
      'createdAt',
      'updatedAt',
    ]);
    if (!SavedRecipeValidation.recipeId(d['recipeId']) ||
        !SavedRecipeValidation.text(d['title'], 100) ||
        !SavedRecipeValidation.integer(d['version'], 1) ||
        d['isArchived'] is! bool) {
      SavedRecipeValidation.invalid();
    }
    final created = SavedRecipeValidation.instant(d['createdAt']),
        updated = SavedRecipeValidation.instant(d['updatedAt']);
    final version = (d['version'] as num).toInt();
    if (DateTime.parse(updated).isBefore(DateTime.parse(created)) ||
        (version == 1 && (d['isArchived'] == true || created != updated))) {
      SavedRecipeValidation.invalid();
    }
    return SavedRecipeSummary._(
      d['recipeId'] as String,
      d['title'] as String,
      created,
      updated,
      version,
      d['isArchived'] as bool,
      SavedRecipeProvenance.parse(d),
    );
  }
}

class SavedRecipe {
  final Map<String, Object?> data;
  final SavedRecipeContent recipe;
  final SavedRecipeProvenance provenance;
  SavedRecipe._(this.data, this.recipe, this.provenance);
  String get recipeId => data['recipeId'] as String;
  String get cafeId => data['cafeId'] as String;
  int get version => (data['version'] as num).toInt();
  bool get isArchived => data['isArchived'] as bool;
  factory SavedRecipe.parse(
    Object? raw, {
    required String projectId,
    required String cafeId,
  }) {
    final d = SavedRecipeValidation.fields(raw, [
      'schemaVersion',
      'projectId',
      'cafeId',
      'recipeId',
      'contentDigest',
      'recipe',
      'source',
      'provenanceEvidence',
      'submittedAttribution',
      'createdBy',
      'updatedBy',
      'createdAt',
      'updatedAt',
      'version',
      'isArchived',
      'archivedBy',
      'archivedAt',
    ]);
    if (d['schemaVersion'] != 1 ||
        d['projectId'] != projectId ||
        d['cafeId'] != cafeId ||
        !SavedRecipeValidation.recipeId(d['recipeId']) ||
        !SavedRecipeValidation.digest(d['contentDigest']) ||
        !SavedRecipeValidation.id(d['createdBy']) ||
        !SavedRecipeValidation.id(d['updatedBy']) ||
        !SavedRecipeValidation.integer(d['version'], 1) ||
        d['isArchived'] is! bool) {
      SavedRecipeValidation.invalid();
    }
    final content = SavedRecipeContent.parse(d['recipe']);
    final created = SavedRecipeValidation.instant(d['createdAt']),
        updated = SavedRecipeValidation.instant(d['updatedAt']);
    if (DateTime.parse(updated).isBefore(DateTime.parse(created))) {
      SavedRecipeValidation.invalid();
    }
    if (d['isArchived'] == true) {
      if (!SavedRecipeValidation.id(d['archivedBy']) ||
          d['archivedBy'] != d['updatedBy'] ||
          SavedRecipeValidation.instant(d['archivedAt']) != updated) {
        SavedRecipeValidation.invalid();
      }
    } else if (d['archivedBy'] != null || d['archivedAt'] != null) {
      SavedRecipeValidation.invalid();
    }
    if (d['version'] == 1 &&
        (d['isArchived'] == true ||
            created != updated ||
            d['createdBy'] != d['updatedBy'])) {
      SavedRecipeValidation.invalid();
    }
    SavedRecipeValidation.bound(d, 32768);
    return SavedRecipe._(
      SavedRecipeValidation.freeze(d) as Map<String, Object?>,
      content,
      SavedRecipeProvenance.parse(d),
    );
  }
}

class SavedRecipeCursor {
  final Map<String, Object?> data;
  SavedRecipeCursor._(this.data);
  String get afterId => data['afterId'] as String;
  factory SavedRecipeCursor.parse(Object? raw) {
    final d = SavedRecipeValidation.fields(raw, [
      'schemaVersion',
      'projectId',
      'cafeId',
      'uid',
      'membershipGeneration',
      'mode',
      'limit',
      'afterId',
    ]);
    if (d['schemaVersion'] != 1 ||
        !SavedRecipeValidation.id(d['projectId']) ||
        !SavedRecipeValidation.id(d['cafeId']) ||
        !SavedRecipeValidation.id(d['uid']) ||
        !SavedRecipeValidation.integer(d['membershipGeneration']) ||
        !['active', 'archived', 'all'].contains(d['mode']) ||
        !SavedRecipeValidation.integer(d['limit'], 1) ||
        (d['limit'] as num) > 20 ||
        !SavedRecipeValidation.recipeId(d['afterId'])) {
      SavedRecipeValidation.invalid();
    }
    return SavedRecipeCursor._(Map.unmodifiable(d));
  }
}

sealed class SavedRecipeIntent {
  final Map<String, Object?> request;
  final String operation;
  SavedRecipeIntent._(this.operation, Map<String, Object?> data)
    : request = SavedRecipeValidation.freeze(data) as Map<String, Object?> {
    if (!SavedRecipeValidation.id(data['expectedCafeId']) ||
        !SavedRecipeValidation.integer(data['expectedMembershipGeneration']) ||
        data['idempotencyKey'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{16,128}$',
        ).hasMatch(data['idempotencyKey'] as String)) {
      SavedRecipeValidation.invalid();
    }
    SavedRecipeValidation.bound(request, 32768);
  }
}

final class SavedRecipeSaveIntent extends SavedRecipeIntent {
  SavedRecipeSaveIntent({
    required String expectedCafeId,
    required int expectedMembershipGeneration,
    required String idempotencyKey,
    required SavedRecipeContent recipe,
    required SavedRecipeAttribution attribution,
  }) : super._('save', {
         'expectedCafeId': expectedCafeId,
         'expectedMembershipGeneration': expectedMembershipGeneration,
         'idempotencyKey': idempotencyKey,
         'recipe': recipe.toJson(),
         'attribution': attribution.toJson(),
       });
}

final class SavedRecipeLifecycleIntent extends SavedRecipeIntent {
  SavedRecipeLifecycleIntent({
    required String expectedCafeId,
    required int expectedMembershipGeneration,
    required String idempotencyKey,
    required String recipeId,
    required int expectedVersion,
    required String action,
  }) : super._('lifecycle', {
         'expectedCafeId': expectedCafeId,
         'expectedMembershipGeneration': expectedMembershipGeneration,
         'idempotencyKey': idempotencyKey,
         'recipeId': recipeId,
         'expectedVersion': expectedVersion,
         'action': action,
       }) {
    if (!SavedRecipeValidation.recipeId(recipeId) ||
        !SavedRecipeValidation.integer(expectedVersion, 1) ||
        !['archive', 'restore'].contains(action)) {
      SavedRecipeValidation.invalid();
    }
  }
}

class SavedRecipeAcknowledgement {
  final Map<String, Object?> data;
  SavedRecipeAcknowledgement._(this.data);
  bool get changed => data['changed'] as bool;
  bool get replayed => data['replayed'] as bool;
  int get version => (data['version'] as num).toInt();
  factory SavedRecipeAcknowledgement.parse(
    Object? raw, {
    required String cafeId,
    required String operation,
  }) {
    final d = SavedRecipeValidation.fields(raw, [
      'schemaVersion',
      'cafeId',
      'recipeId',
      'contentDigest',
      'version',
      'isArchived',
      'outcome',
      'changed',
      'replayed',
      'requestHash',
      'payloadHash',
    ]);
    const outcomes = {
      'created': ['save', true, false],
      'existing-active': ['save', false, false],
      'existing-archived': ['save', false, true],
      'archived': ['lifecycle', true, true],
      'restored': ['lifecycle', true, false],
    };
    final expected = outcomes[d['outcome']];
    if (d['schemaVersion'] != 1 ||
        d['cafeId'] != cafeId ||
        !SavedRecipeValidation.recipeId(d['recipeId']) ||
        !SavedRecipeValidation.digest(d['contentDigest']) ||
        !SavedRecipeValidation.digest(d['requestHash']) ||
        !SavedRecipeValidation.digest(d['payloadHash']) ||
        !SavedRecipeValidation.integer(d['version'], 1) ||
        d['replayed'] is! bool ||
        expected == null ||
        expected[0] != operation ||
        expected[1] != d['changed'] ||
        expected[2] != d['isArchived'] ||
        (d['outcome'] == 'created' && d['version'] != 1) ||
        (operation == 'lifecycle' && (d['version'] as num) < 2)) {
      SavedRecipeValidation.invalid();
    }
    return SavedRecipeAcknowledgement._(Map.unmodifiable(d));
  }
}

class SavedRecipeReconciliation {
  final SavedRecipeAcknowledgement? result;
  bool get committed => result != null;
  SavedRecipeReconciliation._(this.result);
  factory SavedRecipeReconciliation.parse(
    Object? raw,
    SavedRecipeIntent intent,
  ) {
    if (raw is! Map) SavedRecipeValidation.invalid();
    final d = SavedRecipeValidation.fields(
      raw,
      raw['status'] == 'committed'
          ? ['schemaVersion', 'status', 'result']
          : ['schemaVersion', 'status'],
    );
    if (d['schemaVersion'] != 1 ||
        !['committed', 'unknown'].contains(d['status'])) {
      SavedRecipeValidation.invalid();
    }
    if (d['status'] == 'unknown') return SavedRecipeReconciliation._(null);
    final ack = SavedRecipeAcknowledgement.parse(
      d['result'],
      cafeId: intent.request['expectedCafeId'] as String,
      operation: intent.operation,
    );
    if (!ack.replayed ||
        (intent is SavedRecipeLifecycleIntent &&
            (ack.data['recipeId'] != intent.request['recipeId'] ||
                ack.version != (intent.request['expectedVersion'] as int) + 1 ||
                ack.data['outcome'] !=
                    (intent.request['action'] == 'archive'
                        ? 'archived'
                        : 'restored')))) {
      SavedRecipeValidation.invalid();
    }
    return SavedRecipeReconciliation._(ack);
  }
}
