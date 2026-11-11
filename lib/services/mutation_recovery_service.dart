import 'dart:convert';

/// Implementations must provide durable atomic CAS across tabs/processes and
/// acknowledge completed writes. A null revision means absence. No default OS
/// storage is supplied; Preferences read-then-write does not meet this contract.
abstract interface class MutationJournalPersistence {
  Future<Object?> read(String key);
  Future<bool> compareAndSet(
    String key,
    int? revision,
    Map<String, Object> value,
  );
}

class MutationRecoveryFailure implements Exception {
  final bool outcomeUnknown;
  const MutationRecoveryFailure({this.outcomeUnknown = true});
  @override
  String toString() => 'Inventory recovery unavailable.';
}

const _safe = 9007199254740991;
bool _id(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 128 &&
    value.trim() == value &&
    !['.', '..'].contains(value) &&
    !RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(value);
bool _int(Object? value, [int min = 0]) =>
    value is int && value >= min && value <= _safe;
Never _bad() => throw const MutationRecoveryFailure();
const _fields = <String, List<String>>{
  'create': [
    'idempotencyKey',
    'name',
    'category',
    'quantity',
    'unit',
    'expiryDate',
    'imageUrl',
  ],
  'update': [
    'idempotencyKey',
    'itemId',
    'expectedVersion',
    'name',
    'category',
    'unit',
    'expiryDate',
    'imageUrl',
  ],
  'adjust-stock': [
    'idempotencyKey',
    'itemId',
    'expectedVersion',
    'direction',
    'quantity',
    'reason',
  ],
  'lifecycle': ['idempotencyKey', 'itemId', 'expectedVersion', 'action'],
};

/// This canonical JSON is a CLIENT journal integrity binding, not the server's
/// differently normalized receipt digest. The server recomputes its own digest
/// from the exact original request during explicit observation.
String mutationJournalCanonicalJson(
  String operation,
  Map<String, Object> request,
) {
  final fields = _fields[operation];
  if (fields == null ||
      request.keys.any(
        (key) => ![
          ...fields,
          'expectedCafeId',
          'expectedMembershipGeneration',
        ].contains(key),
      ) ||
      request.values.any((v) => v is! String && v is! int) ||
      !_id(request['expectedCafeId']) ||
      !_int(request['expectedMembershipGeneration']) ||
      !_id(request['idempotencyKey']) ||
      (request['idempotencyKey'] as String).length < 16 ||
      utf8.encode(jsonEncode(request)).length > 4096) {
    _bad();
  }
  final required = fields.where((key) => key != 'reason');
  if (required.any((key) => !request.containsKey(key))) _bad();
  if (operation != 'create' &&
      (!_id(request['itemId']) || !_int(request['expectedVersion'], 1))) {
    _bad();
  }
  if (operation == 'create' && !_int(request['quantity'])) _bad();
  if (operation == 'adjust-stock' &&
      (!_int(request['quantity'], 1) ||
          !['in', 'out'].contains(request['direction']))) {
    _bad();
  }
  if (operation == 'lifecycle' &&
      !['archive', 'restore'].contains(request['action'])) {
    _bad();
  }
  for (final key in [
    'name',
    'category',
    'unit',
    'expiryDate',
    'imageUrl',
    'reason',
  ]) {
    if (request.containsKey(key) && request[key] is! String) _bad();
  }
  final keys = request.keys.toList()..sort();
  return jsonEncode({
    'operation': operation,
    'request': {for (final key in keys) key: request[key]},
  });
}

Map<String, Object> validateMutationAcknowledgement(
  String operation,
  Map<String, Object> request,
  Object? raw, {
  bool historical = false,
}) {
  if (raw is! Map ||
      raw.keys.any((key) => key is! String) ||
      raw['cafeId'] != request['expectedCafeId']) {
    _bad();
  }
  final data = Map<String, Object>.from(raw);
  final expectedKeys = switch (operation) {
    'create' => ['cafeId', 'itemId', 'created'],
    'update' => ['cafeId', 'itemId', 'updated', 'version'],
    'adjust-stock' => [
      'cafeId',
      'itemId',
      'direction',
      'quantity',
      'resultingQuantity',
      'version',
      'adjusted',
    ],
    'lifecycle' => ['cafeId', 'itemId', 'lifecycleState', 'version', 'changed'],
    _ => <String>[],
  };
  if (expectedKeys.isEmpty ||
      data.length != expectedKeys.length ||
      data.keys.any((key) => !expectedKeys.contains(key))) {
    _bad();
  }
  if (operation == 'create') {
    if (data['itemId'] is! String ||
        !RegExp(r'^item_[0-9a-f]{64}$').hasMatch(data['itemId'] as String) ||
        (data['itemId'] as String).trim() != data['itemId'] ||
        data['created'] is! bool ||
        (historical && data['created'] != true)) {
      _bad();
    }
  } else {
    if (data['itemId'] != request['itemId'] || !_int(data['version'], 1)) {
      _bad();
    }
    final version = request['expectedVersion'] as int;
    if (operation == 'update') {
      if (data['updated'] is! bool ||
          data['version'] != version + (data['updated'] == true ? 1 : 0)) {
        _bad();
      }
    } else if (operation == 'adjust-stock') {
      if (data['direction'] != request['direction'] ||
          data['quantity'] != request['quantity'] ||
          !_int(data['quantity'], 1) ||
          !_int(data['resultingQuantity']) ||
          data['version'] != version + 1 ||
          data['adjusted'] is! bool ||
          (historical && data['adjusted'] != true) ||
          (data['direction'] == 'in' &&
              (data['resultingQuantity'] as int) <
                  (request['quantity'] as int))) {
        _bad();
      }
    } else if (data['lifecycleState'] !=
            (request['action'] == 'archive' ? 'archived' : 'active') ||
        data['version'] != version + 1 ||
        data['changed'] is! bool ||
        (historical && data['changed'] != true)) {
      _bad();
    }
  }
  return Map.unmodifiable(data);
}

class PendingMutationOperation {
  final String projectId, uid, operation, payloadDigest, state;
  final int revision;
  final bool everUncertain;
  final Map<String, Object> request;
  final Map<String, Object>? result;
  const PendingMutationOperation._(
    this.projectId,
    this.uid,
    this.operation,
    this.payloadDigest,
    this.state,
    this.revision,
    this.everUncertain,
    this.request,
    this.result,
  );
  String get stableKey => request['idempotencyKey'] as String;
  String get storageKey => jsonEncode([projectId, uid, operation, stableKey]);
  bool get unresolved => !['acknowledged', 'rejected'].contains(state);
  Map<String, Object> get observationEnvelope => {
    'operation': operation,
    'request': request,
  };
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'projectId': projectId,
    'uid': uid,
    'operation': operation,
    'payloadDigest': payloadDigest,
    'state': state,
    'revision': revision,
    'everUncertain': everUncertain,
    'request': request,
    'result': ?result,
  };
  PendingMutationOperation _next(
    String state, {
    bool? uncertain,
    Map<String, Object>? result,
  }) => PendingMutationOperation._(
    projectId,
    uid,
    operation,
    payloadDigest,
    state,
    revision + 1,
    uncertain ?? everUncertain,
    request,
    result,
  );
}

/// A successful originating prepare grants exactly one dispatch. This capability
/// is never serialized/reconstructed, so restart cannot become permission to send.
class MutationDispatchPermit {
  final MutationRecoveryJournal _owner;
  PendingMutationOperation _record;
  bool _used = false, _finished = false;
  MutationDispatchPermit._(this._owner, this._record);
}

class MutationReceiptObservation {
  final bool committed;
  final Map<String, Object>? result;
  const MutationReceiptObservation._(this.committed, this.result);
  static MutationReceiptObservation parse(
    PendingMutationOperation operation,
    Object? raw,
  ) {
    try {
      if (raw is! Map) _bad();
      if (raw.length == 1 && raw['state'] == 'unknown') {
        return const MutationReceiptObservation._(false, null);
      }
      if (raw.length != 2 ||
          raw['state'] != 'committed' ||
          !raw.containsKey('result')) {
        _bad();
      }
      return MutationReceiptObservation._(
        true,
        validateMutationAcknowledgement(
          operation.operation,
          operation.request,
          raw['result'],
          historical: true,
        ),
      );
    } catch (_) {
      _bad();
    }
  }
}

class MutationRecoveryJournal {
  // A durable rejection is evidence, not a reconstructed dispatch capability.
  // Only this originating instance may explicitly retry its known rejection.
  final _retryable = <String, int>{};
  final MutationJournalPersistence persistence;

  /// Trusted injected SHA-256 of UTF-8 input, returning 64 lowercase hex digits.
  /// No default cryptographic/provider or durable platform implementation exists.
  final String Function(String) sha256;
  final Duration timeout;
  MutationRecoveryJournal(
    this.persistence, {
    required this.sha256,
    this.timeout = const Duration(seconds: 3),
  }) {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 30)) {
      _bad();
    }
  }
  String _digest(String value) {
    final digest = sha256(value);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        digest.trim() != digest) {
      _bad();
    }
    return digest;
  }

  void _namespace(String project, String uid) {
    if (!['velora-spark-test', 'velora-73222'].contains(project) || !_id(uid)) {
      _bad();
    }
  }

  PendingMutationOperation _parse(
    Object raw,
    String project,
    String uid,
    String operation,
    String key,
  ) {
    if (raw is! Map ||
        raw.length != (raw.containsKey('result') ? 10 : 9) ||
        raw.keys.any(
          (k) => ![
            'schemaVersion',
            'projectId',
            'uid',
            'operation',
            'payloadDigest',
            'state',
            'revision',
            'everUncertain',
            'request',
            'result',
          ].contains(k),
        ) ||
        raw['schemaVersion'] is! int ||
        raw['schemaVersion'] != 1 ||
        raw['projectId'] != project ||
        raw['uid'] != uid ||
        raw['operation'] != operation ||
        !_int(raw['revision'], 1) ||
        raw['everUncertain'] is! bool ||
        raw['request'] is! Map ||
        ![
          'prepared',
          'dispatched',
          'unknown',
          'acknowledged',
          'rejected',
        ].contains(raw['state'])) {
      _bad();
    }
    final request = Map<String, Object>.from(raw['request'] as Map);
    final canonical = mutationJournalCanonicalJson(operation, request);
    if (request['idempotencyKey'] != key ||
        raw['payloadDigest'] != _digest(canonical) ||
        (raw['state'] == 'rejected' && raw['everUncertain'] != false) ||
        (raw['state'] == 'unknown' && raw['everUncertain'] != true) ||
        (['prepared', 'dispatched'].contains(raw['state']) &&
            raw['everUncertain'] != false) ||
        (raw['state'] != 'acknowledged' && raw.containsKey('result'))) {
      _bad();
    }
    final result = raw['state'] == 'acknowledged'
        ? validateMutationAcknowledgement(operation, request, raw['result'])
        : null;
    return PendingMutationOperation._(
      project,
      uid,
      operation,
      raw['payloadDigest'] as String,
      raw['state'] as String,
      raw['revision'] as int,
      raw['everUncertain'] as bool,
      Map.unmodifiable(request),
      result,
    );
  }

  Future<PendingMutationOperation?> load(
    String project,
    String uid,
    String operation,
    String key,
  ) async {
    try {
      _namespace(project, uid);
      if (!_fields.containsKey(operation) || !_id(key)) _bad();
      final raw = await persistence
          .read(jsonEncode([project, uid, operation, key]))
          .timeout(timeout);
      return raw == null ? null : _parse(raw, project, uid, operation, key);
    } catch (_) {
      _bad();
    }
  }

  Future<MutationDispatchPermit> prepare({
    required String projectId,
    required String uid,
    required String operation,
    required Map<String, Object> request,
  }) async {
    try {
      _namespace(projectId, uid);
      final canonical = mutationJournalCanonicalJson(operation, request);
      final digest = _digest(canonical);
      final previous = await load(
        projectId,
        uid,
        operation,
        request['idempotencyKey'] as String,
      );
      if (previous != null &&
          (previous.state != 'rejected' ||
              previous.everUncertain ||
              _retryable[previous.storageKey] != previous.revision ||
              mutationJournalCanonicalJson(operation, previous.request) !=
                  canonical)) {
        throw MutationRecoveryFailure(
          outcomeUnknown: previous.unresolved || previous.everUncertain,
        );
      }
      final record = PendingMutationOperation._(
        projectId,
        uid,
        operation,
        digest,
        'prepared',
        (previous?.revision ?? 0) + 1,
        false,
        Map.unmodifiable(Map<String, Object>.from(request)),
        null,
      );
      _retryable.remove(record.storageKey);
      await _cas(record, previous?.revision);
      return MutationDispatchPermit._(this, record);
    } on MutationRecoveryFailure {
      rethrow;
    } catch (_) {
      _bad();
    }
  }

  Future<void> _cas(PendingMutationOperation next, int? previous) async {
    _parse(
      next.toJson(),
      next.projectId,
      next.uid,
      next.operation,
      next.stableKey,
    );
    if (!await persistence
        .compareAndSet(next.storageKey, previous, next.toJson())
        .timeout(timeout)) {
      _bad();
    }
  }

  void _permit(MutationDispatchPermit permit) {
    if (!identical(permit._owner, this) || permit._finished) _bad();
  }

  Future<void> markDispatched(MutationDispatchPermit permit) async {
    try {
      _permit(permit);
      if (permit._used) _bad();
      permit._used = true;
      final next = permit._record._next('dispatched');
      await _cas(next, permit._record.revision);
      permit._record = next;
    } catch (_) {
      _bad();
    }
  }

  Future<void> finish(
    MutationDispatchPermit permit, {
    Map<String, Object>? result,
    bool uncertain = false,
  }) async {
    try {
      _permit(permit);
      permit._finished = true;
      if (result != null && (!permit._used || uncertain)) _bad();
      final ack = result == null
          ? null
          : validateMutationAcknowledgement(
              permit._record.operation,
              permit._record.request,
              result,
            );
      final next = permit._record._next(
        ack != null
            ? 'acknowledged'
            : uncertain
            ? 'unknown'
            : 'rejected',
        uncertain: permit._record.everUncertain || uncertain,
        result: ack,
      );
      await _cas(next, permit._record.revision);
      permit._record = next;
      if (next.state == 'rejected') _retryable[next.storageKey] = next.revision;
    } catch (_) {
      _bad();
    }
  }

  Future<void> recordObservation(
    PendingMutationOperation operation,
    MutationReceiptObservation observation,
  ) async {
    try {
      final current = await load(
        operation.projectId,
        operation.uid,
        operation.operation,
        operation.stableKey,
      );
      if (current == null ||
          current.revision != operation.revision ||
          current.payloadDigest != operation.payloadDigest ||
          mutationJournalCanonicalJson(current.operation, current.request) !=
              mutationJournalCanonicalJson(
                operation.operation,
                operation.request,
              )) {
        _bad();
      }
      if (!observation.committed || current.state == 'acknowledged') return;
      // Absence and later definite failures never clear earlier uncertainty.
      await _cas(
        current._next(
          'acknowledged',
          uncertain: current.everUncertain || current.unresolved,
          result: observation.result,
        ),
        current.revision,
      );
    } catch (_) {
      _bad();
    }
  }
}
