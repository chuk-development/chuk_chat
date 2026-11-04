// lib/services/offline_queue_service_native.dart
// Native implementation: SQLite-backed persistent offline outbox.
//
// Design: docs/OFFLINE_SEND.md. In short:
// * one row per message that could not be sent yet;
// * the payload is sealed with the user's chat key ([OutboxCipher]);
// * every row has an owner ([QueuedMessage.userId]); sign-out wipes them;
// * rows carry a state, attempts, next_attempt_at and a seq for ordering.
//
// Version 1 of the database had plaintext payloads and no owner. Those rows
// are migrated, not dropped: the schema upgrade adds the columns, and the
// first signed-in user claims and seals them ([claimLegacyRows]).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';

/// Persistent offline outbox. Drained by [OfflineRetryManager].
class OfflineQueueService {
  OfflineQueueService._();

  static final OfflineQueueService instance = OfflineQueueService._();

  /// Override database path/factory for tests (in-memory SQLite).
  @visibleForTesting
  static String? debugDatabasePath;
  @visibleForTesting
  static DatabaseFactory? debugDatabaseFactory;

  static const String _dbName = 'offline_queue.db';
  static const int _dbVersion = 2;
  static const Uuid _uuid = Uuid();
  static const String _table = 'pending_messages';

  Database? _db;
  Future<Database>? _opening;
  bool _ffiInitialized = false;
  final StreamController<List<QueuedMessage>> _watchCtrl =
      StreamController<List<QueuedMessage>>.broadcast();

  Future<Database> _open() {
    final db = _db;
    if (db != null) return Future.value(db);
    return _opening ??= _openInner().whenComplete(() => _opening = null);
  }

  Future<Database> _openInner() async {
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
          await _createV1(db);
          await _upgradeToV2(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await _upgradeToV2(db);
        },
      ),
    );
    return _db!;
  }

  /// The version-1 table, kept verbatim so a fresh install and an upgraded
  /// one end in the same schema.
  static Future<void> _createV1(Database db) async {
    await db.execute('''
      CREATE TABLE $_table (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        message_json TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_pending_chat ON $_table (chat_id)');
    await db.execute(
      'CREATE INDEX idx_pending_created ON $_table (created_at)',
    );
  }

  /// Version 2: owner, kind, state, backoff time, order and the sealed flag.
  /// Existing rows keep their payload (plaintext, `encrypted = 0`) and get
  /// a seq in their old created_at order.
  static Future<void> _upgradeToV2(Database db) async {
    await db.execute('ALTER TABLE $_table ADD COLUMN user_id TEXT');
    await db.execute(
      "ALTER TABLE $_table ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'",
    );
    await db.execute(
      "ALTER TABLE $_table ADD COLUMN state TEXT NOT NULL DEFAULT 'queued'",
    );
    await db.execute(
      'ALTER TABLE $_table ADD COLUMN next_attempt_at INTEGER NOT NULL '
      'DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $_table ADD COLUMN seq INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $_table ADD COLUMN encrypted INTEGER NOT NULL DEFAULT 0',
    );
    // Old rows: order by creation time. rowid breaks ties.
    await db.execute(
      'UPDATE $_table SET seq = (SELECT COUNT(*) FROM $_table AS o '
      'WHERE o.created_at < $_table.created_at OR '
      '(o.created_at = $_table.created_at AND o.rowid <= $_table.rowid))',
    );
    await db.execute('CREATE INDEX idx_pending_user ON $_table (user_id)');
  }

  /// Open/migrate the underlying DB. Safe to call multiple times.
  Future<void> init() async {
    await _open();
  }

  // ── Sealing ─────────────────────────────────────────────────────────

  Future<({String value, int encrypted})> _seal(
    Map<String, dynamic> payload,
  ) async {
    final plain = jsonEncode(payload);
    final sealed = await OutboxCipher.seal(plain);
    if (sealed == null) return (value: plain, encrypted: 0);
    return (value: sealed, encrypted: 1);
  }

  Future<QueuedMessage> _fromRow(Map<String, dynamic> row) async {
    final enc = row['encrypted'];
    final raw = row['message_json'];
    if (enc == 1 && raw is String) {
      try {
        final plain = await OutboxCipher.open(raw);
        return QueuedMessage.fromRow(
          row,
          payloadOverride: QueuedMessage.decodePayload(plain),
        );
      } catch (_) {
        // Wrong or missing key. The row stays; it is shown but not sent.
        return QueuedMessage.fromRow(
          row,
          payloadOverride: <String, dynamic>{},
          locked: true,
        );
      }
    }
    return QueuedMessage.fromRow(row);
  }

  Future<List<QueuedMessage>> _fromRows(List<Map<String, dynamic>> rows) async {
    final out = <QueuedMessage>[];
    for (final r in rows) {
      out.add(await _fromRow(r));
    }
    return out;
  }

  /// Seals every plaintext row of [userId] (rows queued before the key was
  /// loaded, rows migrated from version 1). No-op without a key.
  Future<int> sealPlaintextRows(String userId) async {
    if (!OutboxCipher.canOpen()) return 0;
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'encrypted = 0 AND user_id = ?',
      whereArgs: [userId],
    );
    var sealed = 0;
    for (final r in rows) {
      final payload = QueuedMessage.decodePayload(r['message_json']);
      final s = await _seal(payload);
      if (s.encrypted == 0) break;
      await db.update(
        _table,
        {'message_json': s.value, 'encrypted': 1},
        where: 'id = ?',
        whereArgs: [r['id']],
      );
      sealed++;
    }
    return sealed;
  }

  /// Gives rows without an owner (version 1 of the database) to [userId]
  /// and seals them. Returns how many rows were claimed.
  Future<int> claimLegacyRows(String userId) async {
    final db = await _open();
    final n = await db.update(_table, {
      'user_id': userId,
    }, where: 'user_id IS NULL');
    if (n > 0) {
      await sealPlaintextRows(userId);
      await _emit();
    }
    return n;
  }

  // ── Writes ──────────────────────────────────────────────────────────

  Future<int> _nextSeq(Database db) async {
    final res = await db.rawQuery('SELECT MAX(seq) AS m FROM $_table');
    final v = res.isEmpty ? null : res.first['m'];
    final current = v is int ? v : (v is num ? v.toInt() : 0);
    return current + 1;
  }

  Future<String> enqueue({
    required String chatId,
    required Map<String, dynamic> sendPayload,
    String? id,
    String kind = OutboxKind.text,
    String? userId,
    OutboxState state = OutboxState.queued,
  }) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final queueId = id ?? _uuid.v4();
    final owner = userId ?? OutboxCipher.currentUserId();
    final sealed = await _seal(sendPayload);
    await db.transaction((txn) async {
      final seqRes = await txn.rawQuery('SELECT MAX(seq) AS m FROM $_table');
      final v = seqRes.isEmpty ? null : seqRes.first['m'];
      final seq = (v is int ? v : (v is num ? v.toInt() : 0)) + 1;
      await txn.insert(_table, <String, Object?>{
        'id': queueId,
        'chat_id': chatId,
        'message_json': sealed.value,
        'encrypted': sealed.encrypted,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
        'user_id': owner,
        'kind': kind,
        'state': state.name,
        'next_attempt_at': 0,
        'seq': seq,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    if (kDebugMode) {
      debugPrint(
        '[OfflineQueue] enqueued id=$queueId chat=$chatId kind=$kind '
        'sealed=${sealed.encrypted == 1}',
      );
    }
    await _emit();
    return queueId;
  }

  /// Replaces the payload of row [id] (after a transcription or an upload).
  Future<void> updatePayload(String id, Map<String, dynamic> payload) async {
    final db = await _open();
    final sealed = await _seal(payload);
    await db.update(
      _table,
      {
        'message_json': sealed.value,
        'encrypted': sealed.encrypted,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _emit();
  }

  /// Sets the state of row [id]. [error] replaces last_error when given;
  /// [bumpAttempts] adds one attempt.
  Future<void> setState(
    String id,
    OutboxState state, {
    String? error,
    bool clearError = false,
    int? nextAttemptAt,
    bool bumpAttempts = false,
    bool resetAttempts = false,
  }) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final sets = <String>['state = ?', 'updated_at = ?'];
    final args = <Object?>[state.name, now];
    if (error != null) {
      sets.add('last_error = ?');
      args.add(error);
    } else if (clearError) {
      sets.add('last_error = NULL');
    }
    if (nextAttemptAt != null) {
      sets.add('next_attempt_at = ?');
      args.add(nextAttemptAt);
    }
    if (resetAttempts) {
      sets.add('attempt_count = 0');
    } else if (bumpAttempts) {
      sets.add('attempt_count = attempt_count + 1');
    }
    args.add(id);
    await db.rawUpdate(
      'UPDATE $_table SET ${sets.join(', ')} WHERE id = ?',
      args,
    );
    await _emit();
  }

  /// Terminal failure: kept for a manual Retry, never retried by itself.
  Future<void> markFailed(String id, String error) =>
      setState(id, OutboxState.failed, error: error, bumpAttempts: true);

  /// Counts one more attempt without changing the state.
  Future<void> incrementAttempts(String id) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawUpdate(
      'UPDATE $_table '
      'SET attempt_count = attempt_count + 1, updated_at = ? '
      'WHERE id = ?',
      [now, id],
    );
    await _emit();
  }

  /// Manual Retry: back to queued, attempts and backoff cleared.
  Future<void> requeue(String id) => setState(
    id,
    OutboxState.queued,
    clearError: true,
    nextAttemptAt: 0,
    resetAttempts: true,
  );

  /// Rows left in `preparing`/`sending` by a killed app go back to queued.
  /// Called once at startup, before the first flush.
  Future<int> recoverInterrupted() async {
    final db = await _open();
    final n = await db.rawUpdate(
      "UPDATE $_table SET state = 'queued' "
      "WHERE state IN ('preparing', 'sending')",
    );
    if (n > 0) await _emit();
    return n;
  }

  Future<void> remove(String id) async {
    final db = await _open();
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
    if (kDebugMode) {
      debugPrint('[OfflineQueue] removed id=$id');
    }
    await _emit();
  }

  /// Sign-out: deletes every row of [userId], and every row with no owner
  /// (version 1 rows, rows queued before a session was known): the next
  /// account on this device must never claim and send them. Returns the
  /// removed rows so the caller can delete their files (voice recordings,
  /// image blobs).
  Future<List<QueuedMessage>> wipeUser(String userId) async {
    final db = await _open();
    const String where = 'user_id = ? OR user_id IS NULL';
    final rows = await db.query(_table, where: where, whereArgs: [userId]);
    final removed = rows
        .map((r) => QueuedMessage.fromRow(r, payloadOverride: const {}))
        .toList(growable: false);
    await db.delete(_table, where: where, whereArgs: [userId]);
    await _emit();
    return removed;
  }

  // ── Reads ───────────────────────────────────────────────────────────

  Future<List<QueuedMessage>> listForChat(String chatId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'seq ASC, created_at ASC',
    );
    return _fromRows(rows);
  }

  /// Every row in seq order. With [userId] only that user's rows.
  Future<List<QueuedMessage>> listAll({String? userId}) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: userId == null ? null : 'user_id = ?',
      whereArgs: userId == null ? null : [userId],
      orderBy: 'seq ASC, created_at ASC',
    );
    return _fromRows(rows);
  }

  Future<QueuedMessage?> getById(String id) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<int> count({String? userId}) async {
    final db = await _open();
    final res = userId == null
        ? await db.rawQuery('SELECT COUNT(*) AS c FROM $_table')
        : await db.rawQuery(
            'SELECT COUNT(*) AS c FROM $_table WHERE user_id = ?',
            [userId],
          );
    if (res.isEmpty) return 0;
    final v = res.first['c'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Stream<List<QueuedMessage>> watch() => _watchCtrl.stream;

  Future<void> _emit() async {
    if (_watchCtrl.isClosed || !_watchCtrl.hasListener) return;
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
    await db.delete(_table);
    await _emit();
  }

  /// Test helper — raw row access (to prove the payload is sealed).
  @visibleForTesting
  Future<List<Map<String, Object?>>> debugRawRows() async {
    final db = await _open();
    return db.query(_table, orderBy: 'seq ASC');
  }

  /// Test helper — the max seq (unused by production, keeps _nextSeq live).
  @visibleForTesting
  Future<int> debugNextSeq() async => _nextSeq(await _open());

  /// Close DB + stream. Tests reset between cases.
  @visibleForTesting
  Future<void> debugReset() async {
    await _db?.close();
    _db = null;
  }
}
