// Uses the resolved web bindings for this isolated qualification target.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import '../services/platform_journal_store.dart';

Never _unavailable() => throw const PlatformJournalFailure();

/// IndexedDB journal storage. A callback works on one bounded
/// snapshot. A write serializes at a native compare-and-set of that snapshot.
final class IndexedDbJournalEngine implements TransactionalJournalEngine {
  static const databaseName = 'velora-synthetic-inventory-recovery-v1';
  static const invitationDatabase = 'velora-real-staff-invitation-v1';
  static const inventoryDatabase = 'velora-real-inventory-recovery-v1';
  static const journalStore = 'journal';
  static const receiptStore = 'synthetic_receipt';
  static const snapshotKey = 'snapshot';
  static const _empty = '{"revision":0,"rows":{}}';
  static const _timeout = Duration(seconds: 2);

  final web.IDBDatabase _database;
  final String _storeName;

  IndexedDbJournalEngine._(this._database, this._storeName);

  static Future<IndexedDbJournalEngine> open({
    String name = databaseName,
    String store = journalStore,
    web.IDBFactory? Function()? factory,
  }) async {
    try {
      final production =
          name == invitationDatabase || name == inventoryDatabase;
      if ((!name.startsWith(databaseName) && !production) ||
          (production && store != journalStore) ||
          (store != journalStore && store != receiptStore)) {
        _unavailable();
      }
      final backend = (factory ?? (() => web.window.indexedDB))();
      if (backend == null) _unavailable();
      var rejected = false;
      final request = backend.open(name, 1);
      request.onblocked = ((web.Event _) => rejected = true).toJS;
      request.onupgradeneeded = ((web.IDBVersionChangeEvent event) {
        final upgrade = request.transaction!;
        if (event.oldVersion != 0 || rejected) {
          upgrade.abort();
          return;
        }
        try {
          final db = request.result as web.IDBDatabase;
          for (final name in [journalStore, receiptStore]) {
            db.createObjectStore(name).put(_empty.toJS, snapshotKey.toJS);
          }
        } catch (_) {
          upgrade.abort();
        }
      }).toJS;
      final opening = _requestResult(request).then((value) {
        final db = value as web.IDBDatabase;
        if (rejected) {
          db.close();
          _unavailable();
        }
        return db;
      });
      final db = await opening.timeout(
        _timeout,
        onTimeout: () {
          rejected = true;
          _unavailable();
        },
      );
      if (db.objectStoreNames.length != 2 ||
          !db.objectStoreNames.contains(journalStore) ||
          !db.objectStoreNames.contains(receiptStore)) {
        db.close();
        _unavailable();
      }
      db.onversionchange = ((web.Event _) => db.close()).toJS;
      return IndexedDbJournalEngine._(db, store);
    } catch (_) {
      _unavailable();
    }
  }

  void close() => _database.close();

  static Future<JSAny?> _requestResult(web.IDBRequest request) {
    final result = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => result.complete(request.result)).toJS;
    request.onerror = ((web.Event _) {
      result.completeError(const PlatformJournalFailure());
    }).toJS;
    return result.future;
  }

  Future<String> _native({String? expected, String? replacement}) async {
    final strict = replacement != null && _database.name == inventoryDatabase;
    final tx = strict
        ? _database.transaction(
            _storeName.toJS,
            'readwrite',
            web.IDBTransactionOptions(durability: 'strict'),
          )
        : _database.transaction(
            _storeName.toJS,
            replacement == null ? 'readonly' : 'readwrite',
          );
    if (strict && tx.durability != 'strict') {
      tx.abort();
      _unavailable();
    }
    final completion = Completer<bool>();
    tx.oncomplete = ((web.Event _) => completion.complete(true)).toJS;
    tx.onabort = ((web.Event _) => completion.complete(false)).toJS;
    final store = tx.objectStore(_storeName);
    final read = store.get(snapshotKey.toJS);
    String? raw;
    read.onsuccess = ((web.Event _) {
      try {
        final value = read.result;
        if (value == null || !value.isA<JSString>()) _unavailable();
        raw = (value as JSString).toDart;
        if (replacement != null) {
          if (raw != expected) {
            _unavailable();
          }
          // Queue the write while the native success event has an active
          // transaction. An uncanceled write error aborts the transaction.
          store.put(replacement.toJS, snapshotKey.toJS);
        }
      } catch (_) {
        tx.abort();
      }
    }).toJS;
    try {
      if (!await completion.future.timeout(_timeout) || raw == null) {
        _unavailable();
      }
      return raw!;
    } catch (_) {
      try {
        tx.abort();
      } catch (_) {
        // The browser may already have ended the transaction.
      }
      _unavailable();
    }
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(JournalStorageTransaction tx) action,
  ) async {
    try {
      final raw = await _native();
      final snapshot = _Snapshot.decode(raw);
      final T result;
      try {
        result = await action(snapshot).timeout(_timeout);
      } finally {
        snapshot.closed = true;
      }
      if (snapshot.failed) _unavailable();
      if (snapshot.changed) {
        if (snapshot.revision == _maxRevision) {
          _unavailable();
        }
        final next = snapshot.encode();
        await _native(expected: raw, replacement: next);
      }
      return result;
    } catch (_) {
      _unavailable();
    }
  }
}

const _maxRevision = 9007199254740991;
const _maxBytes = 2 * 1024 * 1024;
final _asciiKey = RegExp(r'^[!-~]+$');

final class _Snapshot implements JournalStorageTransaction {
  final int revision;
  final Map<String, String> _rows = {};
  bool closed = false;
  bool failed = false;
  bool changed = false;
  _Snapshot(this.revision);

  factory _Snapshot.decode(Object? raw) {
    if (raw is! String ||
        raw.length > _maxBytes ||
        utf8.encode(raw).length > _maxBytes) {
      _unavailable();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded.length != 2) _unavailable();
    final revision = decoded['revision'];
    final rows = decoded['rows'];
    if (revision is! int ||
        revision < 0 ||
        revision > _maxRevision ||
        rows is! Map ||
        rows.length > 512 ||
        (revision == 0) != rows.isEmpty) {
      _unavailable();
    }
    final snapshot = _Snapshot(revision);
    for (final entry in rows.entries) {
      snapshot._put(entry.key, entry.value);
    }
    return snapshot;
  }

  String encode() {
    final value = jsonEncode({'revision': revision + 1, 'rows': _rows});
    if (utf8.encode(value).length > _maxBytes) _unavailable();
    return value;
  }

  Never _reject() {
    failed = true;
    _unavailable();
  }

  String _key(Object? key) {
    if (closed ||
        failed ||
        key is! String ||
        key.length > 4096 ||
        _asciiKey.stringMatch(key) != key) {
      _reject();
    }
    return key;
  }

  void _put(Object? key, Object? value) {
    final address = _key(key);
    if (value is! String ||
        value.length > 16384 ||
        utf8.encode(value).length > 16384) {
      _reject();
    }
    try {
      if (jsonDecode(value) is! Map) _reject();
    } catch (_) {
      _reject();
    }
    _rows[address] = value;
    if (_rows.length > 512) _reject();
  }

  @override
  Future<Object?> read(String key) async => _rows[_key(key)];

  @override
  Future<void> put(String key, String encodedRecord) async {
    _put(key, encodedRecord);
    changed = true;
  }

  @override
  Future<List<String>> scan(
    String prefix, {
    String? after,
    required int limit,
  }) async {
    _key(prefix);
    if (limit < 1 ||
        limit > 101 ||
        (after != null && !_key(after).startsWith(prefix))) {
      _reject();
    }
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
