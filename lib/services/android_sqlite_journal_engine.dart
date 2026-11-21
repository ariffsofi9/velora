import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_journal_store.dart';
import 'workspace_session.dart';

const _maxRecords = 512;
const _maxBytes = 2 * 1024 * 1024;
const _maxRevision = 9007199254740991;
final _asciiKey = RegExp(r'^[!-~]+$');

Never _unavailable() => throw const PlatformJournalFailure();

/// Offline Android qualification adapter. The caller owns the verified session.
/// A read-only callback serializes at snapshot time. A write callback serializes
/// at commit only if no writer changed the partition since that snapshot.
final class AndroidSqliteJournalEngine implements TransactionalJournalEngine {
  static const channelName = 'velora/android_sqlite_journal';
  static const projectId = 'velora-spark-test';

  final WorkspaceSession workspace;
  final MethodChannel _channel;

  AndroidSqliteJournalEngine({
    required this.workspace,
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel;

  @override
  Future<T> transaction<T>(
    Future<T> Function(JournalStorageTransaction tx) action,
  ) async {
    try {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
        _unavailable();
      }
      workspace.requireActive();
      final scope = {
        'projectId': projectId,
        'uid': workspace.uid,
        'cafeId': workspace.cafeId,
      };
      final response = await _channel.invokeMapMethod<String, Object?>(
        'snapshot',
        scope,
      );
      workspace.requireActive();
      final revision = response?['revision'];
      final rows = response?['rows'];
      if (response?.length != 2 ||
          revision is! int ||
          revision < 0 ||
          revision > _maxRevision ||
          rows is! Map ||
          rows.length > _maxRecords ||
          (revision == 0) != rows.isEmpty) {
        _unavailable();
      }
      String segment(String value) =>
          base64Url.encode(utf8.encode(value)).replaceAll('=', '');
      final prefix =
          'journal/1/${segment(projectId)}/${segment(workspace.uid)}/';
      final tx = _Snapshot(prefix);
      for (final entry in rows.entries) {
        tx._add(entry.key, entry.value);
      }
      if (tx._bytes > _maxBytes) _unavailable();

      final T result;
      try {
        result = await action(tx);
      } finally {
        tx._closed = true;
      }
      workspace.requireActive();
      if (tx._failed) _unavailable();
      if (tx._writes.isNotEmpty) {
        if (revision == _maxRevision) _unavailable();
        final committed = await _channel.invokeMethod<int>('commit', {
          ...scope,
          'revision': revision,
          'writes': tx._writes,
        });
        if (committed != revision + 1) _unavailable();
        workspace.requireActive();
      }
      return result;
    } catch (_) {
      _unavailable();
    }
  }
}

final class _Snapshot implements JournalStorageTransaction {
  final String _prefix;
  final _rows = <String, String>{};
  final _writes = <String, String>{};
  int _bytes = 0;
  bool _closed = false;
  bool _failed = false;
  _Snapshot(this._prefix);

  void _check() {
    if (_closed || _failed) _unavailable();
  }

  Never _reject() {
    _failed = true;
    _unavailable();
  }

  String _key(Object? value) {
    if (value is! String ||
        value.length > 4096 ||
        !value.startsWith(_prefix) ||
        _asciiKey.stringMatch(value) != value) {
      _reject();
    }
    return value;
  }

  void _add(Object? key, Object? value) {
    final address = _key(key);
    if (value is! String || value.isEmpty || value.length > 16384) _reject();
    final size = utf8.encode(value).length;
    if (size > 16384) _reject();
    final old = _rows[address];
    _bytes += old == null
        ? address.length + size
        : size - utf8.encode(old).length;
    _rows[address] = value;
    if (_rows.length > _maxRecords || _bytes > _maxBytes) _reject();
  }

  @override
  Future<Object?> read(String key) async {
    _check();
    return _rows[_key(key)];
  }

  @override
  Future<void> put(String key, String encodedRecord) async {
    _check();
    _add(key, encodedRecord);
    _writes[key] = encodedRecord;
  }

  @override
  Future<List<String>> scan(
    String prefix, {
    String? after,
    required int limit,
  }) async {
    _check();
    _key(prefix);
    if (after != null && !_key(after).startsWith(prefix)) _reject();
    if (limit < 1 || limit > 101) _reject();
    final keys =
        _rows.keys
            .where(
              (key) =>
                  key.startsWith(prefix) &&
                  (after == null || key.compareTo(after) > 0),
            )
            .toList()
          ..sort();
    return keys.take(limit).toList();
  }
}
