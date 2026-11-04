// lib/services/offline_blob_store_web.dart
//
// IndexedDB store for outbox bytes on web (voice recordings, offline
// images). One object store, `blobs`; the value is `[bytes, writtenAtMs]`.
// IndexedDB keeps much more than SharedPreferences (localStorage, ~5 MB),
// and survives a reload like the native files do.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

abstract final class OfflineBlobStore {
  static const String _dbName = 'chuk_offline_outbox';
  static const String _store = 'blobs';

  static Future<web.IDBDatabase>? _db;

  static bool get isSupported {
    try {
      return web.window.indexedDB.isA<web.IDBFactory>();
    } catch (_) {
      return false;
    }
  }

  static Future<web.IDBDatabase> _open() => _db ??= _openOnce().catchError((
    Object e,
  ) {
    _db = null;
    throw e;
  });

  static Future<web.IDBDatabase> _openOnce() {
    final Completer<web.IDBDatabase> done = Completer<web.IDBDatabase>();
    final web.IDBOpenDBRequest request = web.window.indexedDB.open(_dbName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final web.IDBDatabase db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_store)) db.createObjectStore(_store);
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (!done.isCompleted) {
        done.complete(request.result as web.IDBDatabase);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('IndexedDB open failed'));
      }
    }).toJS;
    return done.future;
  }

  static Future<JSAny?> _request(
    String mode,
    web.IDBRequest Function(web.IDBObjectStore store) make,
  ) async {
    final web.IDBDatabase db = await _open();
    final web.IDBTransaction tx = db.transaction(_store.toJS, mode);
    final web.IDBRequest request = make(tx.objectStore(_store));
    final Completer<JSAny?> done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('IndexedDB request failed'));
      }
    }).toJS;
    return done.future;
  }

  static Future<void> put(String key, Uint8List bytes) async {
    final JSArray<JSAny> value = <JSAny>[
      bytes.toJS,
      DateTime.now().millisecondsSinceEpoch.toJS,
    ].toJS;
    await _request('readwrite', (s) => s.put(value, key.toJS));
  }

  static List<JSAny?>? _entry(JSAny? raw) {
    if (raw == null || !raw.isA<JSArray>()) return null;
    return (raw as JSArray<JSAny?>).toDart;
  }

  static Future<Uint8List?> get(String key) async {
    final List<JSAny?>? entry = _entry(
      await _request('readonly', (s) => s.get(key.toJS)),
    );
    if (entry == null || entry.isEmpty) return null;
    final JSAny? data = entry.first;
    if (data == null || !data.isA<JSUint8Array>()) return null;
    return (data as JSUint8Array).toDart;
  }

  static Future<bool> exists(String key) async {
    final JSAny? count = await _request('readonly', (s) => s.count(key.toJS));
    return count != null &&
        count.isA<JSNumber>() &&
        (count as JSNumber).toDartInt > 0;
  }

  static Future<void> delete(String key) async {
    await _request('readwrite', (s) => s.delete(key.toJS));
  }

  static Future<List<String>> _keys() async {
    final JSAny? raw = await _request('readonly', (s) => s.getAllKeys());
    if (raw == null || !raw.isA<JSArray>()) return const <String>[];
    return <String>[
      for (final JSAny? k in (raw as JSArray<JSAny?>).toDart)
        if (k != null && k.isA<JSString>()) (k as JSString).toDart,
    ];
  }

  static Future<void> deletePrefix(String prefix) async {
    for (final String key in await _keys()) {
      if (key.startsWith(prefix)) await delete(key);
    }
  }

  static Future<List<({String key, DateTime modified})>> list(
    String prefix,
  ) async {
    final out = <({String key, DateTime modified})>[];
    for (final String key in await _keys()) {
      if (!key.startsWith(prefix)) continue;
      final List<JSAny?>? entry = _entry(
        await _request('readonly', (s) => s.get(key.toJS)),
      );
      final JSAny? at = entry != null && entry.length > 1 ? entry[1] : null;
      final int ms = at != null && at.isA<JSNumber>()
          ? (at as JSNumber).toDartInt
          : 0;
      out.add((key: key, modified: DateTime.fromMillisecondsSinceEpoch(ms)));
    }
    return out;
  }
}
