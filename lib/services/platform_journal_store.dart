import 'dart:async';
import 'dart:convert';
import 'invitation_recovery_service.dart';
import 'mutation_recovery_service.dart';

/// Provider qualification contract, not a durability implementation. Invoke the
/// callback at most once in a serializable transaction. Reads, writes and the
/// primary-key scan/index share one snapshot/commit. Return its result ONLY after
/// completed commit acknowledgement; abort/unknown outcomes must throw. No retry.
/// Transaction handles cannot escape their callback. No engine default exists.
abstract interface class TransactionalJournalEngine {
  Future<T> transaction<T>(
    Future<T> Function(JournalStorageTransaction tx) action,
  );
}

abstract interface class JournalStorageTransaction {
  Future<Object?> read(String key);
  Future<void> put(String key, String encodedRecord);

  /// Native primary-key index, atomically maintained by put, not a separately
  /// updated application index. Ascending ASCII keys, prefix-only, exclusive
  /// after, at most limit rows; return a complete prefix when fewer than limit.
  /// Never silently omit committed records. No delete/clear API is supplied.
  Future<List<String>> scan(String prefix, {String? after, required int limit});
}

class PlatformJournalFailure implements Exception {
  const PlatformJournalFailure();
  @override
  String toString() => 'Journal storage unavailable.';
}

Never _bad() => throw const PlatformJournalFailure();
const _safe = 9007199254740991;
bool _integer(Object? n, [int min = 0]) => n is int && n >= min && n <= _safe;
bool _id(Object? s) =>
    s is String &&
    s.isNotEmpty &&
    s.length <= 128 &&
    s.trim() == s &&
    !['.', '..'].contains(s) &&
    !RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(s);
void _namespace(String project, String uid) {
  if (!['velora-spark-test', 'velora-73222'].contains(project) || !_id(uid)) {
    _bad();
  }
  _canonical(uid);
}

Object? _canonical(Object? value, [int depth = 0]) {
  if (depth > 6) _bad();
  if (value == null || value is bool || value is int && value.abs() <= _safe) {
    return value;
  }
  if (value is String) {
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length ||
            value.codeUnitAt(i) < 0xdc00 ||
            value.codeUnitAt(i) > 0xdfff) {
          _bad();
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        _bad();
      }
    }
    return value;
  }
  if (value is List && value.length <= 100) {
    return value.map((v) => _canonical(v, depth + 1)).toList();
  }
  if (value is Map &&
      value.length <= 32 &&
      value.keys.every((k) => k is String)) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key], depth + 1)};
  }
  _bad();
}

String _encode(Object? value) {
  final encoded = jsonEncode(_canonical(value));
  if (utf8.encode(encoded).length > 16384) _bad();
  return encoded;
}

Map<String, Object> _copy(Object? value) {
  final decoded = jsonDecode(_encode(value));
  if (decoded is! Map<String, dynamic>) _bad();
  return Map<String, Object>.from(decoded);
}

String _segment(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');
String _prefix(String project, String uid) =>
    'journal/1/${_segment(project)}/${_segment(uid)}/';

class _Address {
  final String project, uid, kind, journalKey;
  _Address(this.project, this.uid, this.kind, this.journalKey) {
    _namespace(project, uid);
  }
  String get suffix => '$kind/${_segment(journalKey)}';
  String get head => '${_prefix(project, uid)}records/$suffix';
  String get historyPrefix => '${_prefix(project, uid)}history/$suffix/';
  String history(int sequence) =>
      '$historyPrefix${sequence.toString().padLeft(16, '0')}';
}

class _Record {
  final _Address address;
  final int sequence;
  final Map<String, Object> payload;
  final bool pending;
  _Record(this.address, this.sequence, this.payload, this.pending);
  String get encoded => _encode({
    'formatVersion': 1,
    'kind': address.kind,
    'projectId': address.project,
    'uid': address.uid,
    'journalKey': address.journalKey,
    'sequence': sequence,
    'payload': payload,
  });
}

/// Evidence only: no dispatch permit or replay method can be reconstructed.
class PendingJournalRecord {
  final String kind, journalKey;
  final Map<String, Object> _payload;
  PendingJournalRecord._(_Record record)
    : kind = record.address.kind,
      journalKey = record.address.journalKey,
      _payload = _copy(record.payload);
  Map<String, Object> get payload => _copy(_payload);
}

class PendingJournalPage {
  final List<PendingJournalRecord> records;
  final String? nextCursor;
  PendingJournalPage._(List<PendingJournalRecord> records, this.nextCursor)
    : records = List.unmodifiable(records);
}

/// Fully injected and unwired. No database, Preferences, platform channel or
/// physical durability claim. Engines must qualify the contract above separately.
/// Writes retain immutable history in the same transaction as the indexed head.
/// Capacity is enforced by the engine by failing writes, never by evicting data.
class PlatformJournalStore {
  final TransactionalJournalEngine engine;
  final String Function(String) sha256;
  final Duration timeout;
  late final MutationJournalPersistence mutations = _Mutations(this);
  late final InvitationJournalPersistence invitations = _Invitations(this);
  PlatformJournalStore({
    required this.engine,
    required this.sha256,
    this.timeout = const Duration(seconds: 3),
  }) {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 30)) {
      _bad();
    }
  }
  Future<T> _run<T>(
    Future<T> Function(JournalStorageTransaction) action,
  ) async {
    try {
      return await engine.transaction(action).timeout(timeout);
    } catch (_) {
      _bad();
    }
  }

  _Address _mutation(String key) {
    if (utf8.encode(key).length > 2048) _bad();
    final raw = jsonDecode(key);
    if (raw is! List ||
        raw.length != 4 ||
        raw.any((v) => v is! String) ||
        jsonEncode(raw) != key ||
        !['create', 'update', 'adjust-stock', 'lifecycle'].contains(raw[2]) ||
        !_id(raw[3])) {
      _bad();
    }
    return _Address(raw[0] as String, raw[1] as String, 'mutation', key);
  }

  _Address _invitation(String project, String uid) =>
      _Address(project, uid, 'invitation', jsonEncode([project, uid]));
  _Address _fromHead(String head, String project, String uid) {
    final prefix = '${_prefix(project, uid)}records/';
    if (!head.startsWith(prefix)) _bad();
    final parts = head.substring(prefix.length).split('/');
    if (parts.length != 2 || parts[1].isEmpty) _bad();
    final key = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    if (_segment(key) != parts[1]) _bad();
    final address = parts[0] == 'mutation'
        ? _mutation(key)
        : parts[0] == 'invitation'
        ? _invitation(project, uid)
        : null;
    if (address == null ||
        address.head != head ||
        address.project != project ||
        address.uid != uid ||
        address.journalKey != key) {
      _bad();
    }
    return address;
  }

  Future<Map<String, Object>> _validate(_Address address, Object? raw) async {
    final value = _copy(raw);
    if (address.kind == 'invitation') {
      return PendingInvitationOperation.parse(
        value,
        address.project,
        address.uid,
      ).toJson();
    }
    final key = jsonDecode(address.journalKey) as List;
    // Reuse the canonical journal parser/digest/ack checks without duplicating
    // its private state machine. This reader performs no engine writes or I/O.
    final journal = MutationRecoveryJournal(
      _ValueReader(value),
      sha256: sha256,
      timeout: timeout,
    );
    final parsed = await journal.load(
      address.project,
      address.uid,
      key[2] as String,
      key[3] as String,
    );
    if (parsed == null) _bad();
    return parsed.toJson();
  }

  Future<_Record?> _read(JournalStorageTransaction tx, _Address address) async {
    final raw = await tx.read(address.head);
    if (raw == null) {
      final history = await tx.scan(address.historyPrefix, limit: 1);
      final indexed = await tx.scan(address.head, limit: 1);
      if (history.isNotEmpty ||
          indexed.length > 1 ||
          indexed.any((key) => !key.startsWith(address.head)) ||
          indexed.contains(address.head)) {
        _bad();
      }
      return null;
    }
    if (raw is! String || utf8.encode(raw).length > 16384) _bad();
    final data = jsonDecode(raw);
    if (data is! Map ||
        data.length != 7 ||
        data['formatVersion'] is! int ||
        data['formatVersion'] != 1 ||
        data['kind'] != address.kind ||
        data['projectId'] != address.project ||
        data['uid'] != address.uid ||
        data['journalKey'] != address.journalKey ||
        !_integer(data['sequence'], 1)) {
      _bad();
    }
    final payload = await _validate(address, data['payload']);
    final sequence = data['sequence'] as int;
    if (address.kind == 'mutation' && payload['revision'] != sequence) _bad();
    final record = _Record(
      address,
      sequence,
      payload,
      address.kind == 'invitation' ||
          !['acknowledged', 'rejected'].contains(payload['state']),
    );
    final historical = await tx.read(address.history(sequence));
    if (historical is! String ||
        historical.length > 16384 ||
        _encode(jsonDecode(historical)) != record.encoded) {
      _bad();
    }
    final indexed = await tx.scan(address.head, limit: 1);
    if (indexed.length != 1 || indexed.single != address.head) _bad();
    return record;
  }

  Future<void> _write(JournalStorageTransaction tx, _Record record) async {
    if (await tx.read(record.address.history(record.sequence)) != null) _bad();
    await tx.put(record.address.history(record.sequence), record.encoded);
    await tx.put(record.address.head, record.encoded);
  }

  /// Scans at most limit+1 HEADS, including settled records. An empty pending
  /// page can have nextCursor: callers must continue explicitly, never replay.
  /// Validates look-ahead too. Cursor is exclusive and bound to project/UID.
  Future<PendingJournalPage> pending(
    String project,
    String uid, {
    int limit = 20,
    String? cursor,
  }) async {
    try {
      _namespace(project, uid);
      if (limit < 1 || limit > 100) _bad();
      if (cursor != null) _fromHead(cursor, project, uid);
      return await _run((tx) async {
        final prefix = '${_prefix(project, uid)}records/';
        final keys = await tx.scan(prefix, after: cursor, limit: limit + 1);
        if (keys.length > limit + 1) _bad();
        String? previous = cursor;
        final records = <PendingJournalRecord>[];
        for (var i = 0; i < keys.length; i++) {
          final key = keys[i];
          if (!key.startsWith(prefix) ||
              previous != null && key.compareTo(previous) <= 0) {
            _bad();
          }
          final record = await _read(tx, _fromHead(key, project, uid));
          if (record == null) _bad();
          if (i < limit && record.pending) {
            records.add(PendingJournalRecord._(record));
          }
          previous = key;
        }
        return PendingJournalPage._(
          records,
          keys.length > limit ? keys[limit - 1] : null,
        );
      });
    } catch (_) {
      _bad();
    }
  }
}

class _ValueReader implements MutationJournalPersistence {
  final Object value;
  _ValueReader(this.value);
  @override
  Future<Object?> read(String key) async => value;
  @override
  Future<bool> compareAndSet(
    String key,
    int? revision,
    Map<String, Object> value,
  ) => throw const PlatformJournalFailure();
}

class _Mutations implements MutationJournalPersistence {
  final PlatformJournalStore store;
  _Mutations(this.store);
  @override
  Future<Object?> read(String key) async {
    try {
      final address = store._mutation(key);
      return await store._run(
        (tx) async => (await store._read(tx, address))?.payload,
      );
    } catch (_) {
      throw const MutationRecoveryFailure();
    }
  }

  @override
  Future<bool> compareAndSet(
    String key,
    int? revision,
    Map<String, Object> value,
  ) async {
    try {
      final address = store._mutation(key), snapshot = _copy(value);
      if (revision != null && !_integer(revision, 1)) _bad();
      final next = await store._validate(address, snapshot);
      if (next['revision'] != (revision ?? 0) + 1) _bad();
      return await store._run((tx) async {
        final current = await store._read(tx, address);
        if (current?.sequence != revision) return false;
        if (current != null &&
            (current.payload['payloadDigest'] != next['payloadDigest'] ||
                _encode(current.payload['request']) !=
                    _encode(next['request']) ||
                current.payload['everUncertain'] == true &&
                    next['everUncertain'] != true ||
                current.payload.containsKey('result') &&
                    _encode(current.payload['result']) !=
                        _encode(next['result']))) {
          _bad();
        }
        await store._write(
          tx,
          _Record(
            address,
            next['revision'] as int,
            next,
            !['acknowledged', 'rejected'].contains(next['state']),
          ),
        );
        return true;
      });
    } catch (_) {
      throw const MutationRecoveryFailure();
    }
  }
}

class _Invitations implements InvitationJournalPersistence {
  final PlatformJournalStore store;
  _Invitations(this.store);
  @override
  Future<Object?> read(String projectId, String uid) async {
    try {
      final address = store._invitation(projectId, uid);
      return await store._run(
        (tx) async => (await store._read(tx, address))?.payload,
      );
    } catch (_) {
      throw const InvitationRecoveryFailure();
    }
  }

  @override
  Future<bool> compareAndSet(
    String projectId,
    String uid,
    Object? expected,
    Map<String, Object> value,
  ) async {
    try {
      final address = store._invitation(projectId, uid),
          snapshot = _copy(value);
      final original = expected == null ? null : _copy(expected);
      final next = await store._validate(address, snapshot);
      if (original != null) await store._validate(address, original);
      return await store._run((tx) async {
        final current = await store._read(tx, address);
        if ((current == null) != (original == null) ||
            current != null && _encode(current.payload) != _encode(original)) {
          return false;
        }
        final sequence = (current?.sequence ?? 0) + 1;
        if (!_integer(sequence, 1)) _bad();
        await store._write(tx, _Record(address, sequence, next, true));
        return true;
      });
    } catch (_) {
      throw const InvitationRecoveryFailure();
    }
  }
}
