// lib/services/offline_queue_service_native.dart
// Native implementation: SQLite-backed persistent offline message queue.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/queued_message.dart';

/// Persistent offline send queue. Used by [OfflineRetryManager] to replay
/// chat sends that failed because the network was unavailable.
class OfflineQueueService {
  OfflineQueueService._();

  static final OfflineQueueService instance = OfflineQueueService._();

  /// Override database path/factory for tests (in-memory SQLite).
  @visibleForTesting
  static String? debugDatabasePath;
  @visibleForTesting
  static DatabaseFactory? debugDatabaseFactory;

  static const String _dbName = 'offline_queue.db';
  static const int _dbVersion = 1;
  static const Uuid _uuid = Uuid();

  Database? _db;
  bool _ffiInitialized = false;
  final StreamController<List<QueuedMessage>> _watchCtrl =
      StreamController<List<QueuedMessage>>.broadcast();

  Future<Database> _open() async {
    if (_db != null) return _db!;

    DatabaseFactory factory;
    if (debugDatabaseFactory != null) {
      factory = debugDatabaseFactory!;
    } else {
      if (!_ffiInitialized) {
        if (Platform.isLinux || Platform.isWindows) {
          sqfliteFfiInit();
          databaseFactory = databaseFactoryFfi;
        }
        _ffiInitialized = true;
      }
      factory = databaseFactory;
    }

    String dbPath;
    if (debugDatabasePath != null) {
      dbPath = debugDatabasePath!;
    } else {
      final baseDir = await getApplicationSupportDirectory();
      dbPath = p.join(baseDir.path, _dbName);
    }

    if (kDebugMode) {
      debugPrint('[OfflineQueue] Opening SQLite at $dbPath');
    }

    _db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE pending_messages (
              id TEXT PRIMARY KEY,
              chat_id TEXT NOT NULL,
              message_json TEXT NOT NULL,
              attempt_count INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_pending_chat ON pending_messages (chat_id)',
          );
          await db.execute(
            'CREATE INDEX idx_pending_created ON pending_messages (created_at)',
          );
        },
      ),
    );

    return _db!;
  }

  /// Open/migrate the underlying DB. Safe to call multiple times.
  Future<void> init() async {
    await _open();
  }

  Future<String> enqueue({
    required String chatId,
    required Map<String, dynamic> sendPayload,
    String? id,
  }) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final queueId = id ?? _uuid.v4();
    final msg = QueuedMessage(
      id: queueId,
      chatId: chatId,
      sendPayload: sendPayload,
      attemptCount: 0,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert(
      'pending_messages',
      msg.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (kDebugMode) {
      debugPrint(
        '[OfflineQueue] enqueued id=$queueId chat=$chatId '
        'payload_keys=${sendPayload.keys.length}',
      );
    }
    await _emit();
    return queueId;
  }

  Future<void> markFailed(String id, String error) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      'pending_messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final current = QueuedMessage.fromRow(rows.first);
    await db.update(
      'pending_messages',
      {
        'attempt_count': current.attemptCount + 1,
        'last_error': error,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (kDebugMode) {
      debugPrint('[OfflineQueue] markFailed id=$id err_len=${error.length}');
    }
    await _emit();
  }

  Future<void> incrementAttempts(String id) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawUpdate(
      'UPDATE pending_messages '
      'SET attempt_count = attempt_count + 1, updated_at = ? '
      'WHERE id = ?',
      [now, id],
    );
    await _emit();
  }

  Future<void> remove(String id) async {
    final db = await _open();
    await db.delete('pending_messages', where: 'id = ?', whereArgs: [id]);
    if (kDebugMode) {
      debugPrint('[OfflineQueue] removed id=$id');
    }
    await _emit();
  }

  Future<List<QueuedMessage>> listForChat(String chatId) async {
    final db = await _open();
    final rows = await db.query(
      'pending_messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at ASC',
    );
    return rows.map(QueuedMessage.fromRow).toList(growable: false);
  }

  Future<List<QueuedMessage>> listAll() async {
    final db = await _open();
    final rows = await db.query(
      'pending_messages',
      orderBy: 'created_at ASC',
    );
    return rows.map(QueuedMessage.fromRow).toList(growable: false);
  }

  Future<QueuedMessage?> getById(String id) async {
    final db = await _open();
    final rows = await db.query(
      'pending_messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return QueuedMessage.fromRow(rows.first);
  }

  Future<int> count() async {
    final db = await _open();
    final res = await db.rawQuery('SELECT COUNT(*) AS c FROM pending_messages');
    if (res.isEmpty) return 0;
    final v = res.first['c'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Stream<List<QueuedMessage>> watch() => _watchCtrl.stream;

  Future<void> _emit() async {
    if (_watchCtrl.isClosed) return;
    try {
      _watchCtrl.add(await listAll());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OfflineQueue] watch emit failed: $e');
      }
    }
  }

  /// Test helper — clears every queued entry.
  @visibleForTesting
  Future<void> debugClearAll() async {
    final db = await _open();
    await db.delete('pending_messages');
    await _emit();
  }

  /// Close DB + stream. Tests reset between cases.
  @visibleForTesting
  Future<void> debugReset() async {
    await _db?.close();
    _db = null;
  }
}
