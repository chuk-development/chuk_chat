// lib/services/local_chat_cache_native.dart
// Native implementation: SQLite database for chat payload cache.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/services/chat_cache_search_text.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_rows.dart';
import 'package:chuk_chat/services/payload_compression.dart';

class LocalChatCacheService {
  static const String _dbName = 'chat_cache.db';
  static const int _dbVersion = 6;

  /// Payloads are compressed before they hit the `payload` column: a deflate
  /// payload frame (see payload_compression.dart), the frame format the
  /// cloud uses too. Rows written before v3 are gzip blobs or plain TEXT and
  /// still read.
  ///
  /// A chat is JSON with long, repetitive tool results, so it compresses
  /// about 4x. That shrinks the file, the platform-channel traffic and the
  /// memory each read allocates. The cache takes deflate, not the cloud's
  /// bzip2: a chat is opened from here, and bzip2 decodes several times
  /// slower for a few percent.
  ///
  /// Every payload is framed, even a short one where the frame gains
  /// nothing: an app from before v3 cannot read a frame and skips the row,
  /// while plain TEXT holding v3 JSON it would misread as v1.

  /// From this payload size on a row is encoded in a background isolate.
  static const int _backgroundEncodeMinChars = 16 * 1024;

  /// Old SharedPreferences key prefixes (for migration).
  static const String _oldV2PrefsKey = 'cached_chats_v2-';
  static const String _oldV1PrefsKey = 'cached_encrypted_chats_v1-';

  /// Old v3 JSON file prefix (for migration from previous file-based cache).
  static const String _oldV3FilePrefix = 'chat_cache_v3_';

  const LocalChatCacheService._();

  static Database? _db;
  static bool _ffiInitialized = false;

  // ─── DB lifecycle ─────────────────────────────────────────────────────

  static Future<Database> _getDb() async {
    if (_db != null) return _db!;

    // Initialize FFI for Linux/Windows desktop.
    if (!_ffiInitialized) {
      if (Platform.isLinux || Platform.isWindows) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      _ffiInitialized = true;
    }

    final baseDir = await getApplicationSupportDirectory();
    final dbPath = p.join(baseDir.path, _dbName);

    if (kDebugMode) {
      debugPrint('🗄️ [CacheService] Opening SQLite DB at $dbPath');
    }

    bool needsVacuum = false;

    _db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE chat_cache (
            id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            title TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT,
            is_starred INTEGER NOT NULL DEFAULT 0,
            search_text TEXT,
            PRIMARY KEY (user_id, id)
          )
        ''');
        // No index on (user_id) alone: the primary key (user_id, id)
        // already serves every lookup by user.
        await db.execute(
          'CREATE INDEX idx_chat_cache_user_updated '
          'ON chat_cache (user_id, updated_at DESC, created_at DESC)',
        );
        // Generic key-value store for larger cached data (projects, etc.)
        await db.execute('''
          CREATE TABLE kv_cache (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await _createSkillsTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS kv_cache (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_chat_cache_user_updated '
            'ON chat_cache (user_id, updated_at DESC, created_at DESC)',
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE chat_cache ADD COLUMN search_text TEXT',
          );
          await _compressExistingPayloads(db);
          needsVacuum = true;
        }
        if (oldVersion < 5) {
          await _createSkillsTable(db);
        }
        if (oldVersion < 6) {
          // Redundant: the primary key (user_id, id) has user_id as prefix.
          await db.execute('DROP INDEX IF EXISTS idx_chat_cache_user');
        }
      },
    );

    // Compression frees a large part of the file, but SQLite keeps the
    // pages. VACUUM has to run outside the upgrade transaction.
    if (needsVacuum) {
      try {
        await _db!.execute('VACUUM');
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ [CacheService] VACUUM after upgrade failed: $e');
        }
      }
    }

    return _db!;
  }

  /// Rewrite every legacy plaintext payload as gzip and fill `search_text`.
  ///
  /// Reads in byte-bounded batches for the same reason [load] does: the
  /// pre-migration cache can hold tens of megabytes, and one `SELECT`
  /// over all of it exceeds what the platform channel can allocate.
  static Future<void> _compressExistingPayloads(Database db) async {
    final index = await db.rawQuery(
      'SELECT rowid AS rid, LENGTH(payload) AS size FROM chat_cache',
    );
    if (index.isEmpty) return;

    final stopwatch = Stopwatch()..start();
    int migrated = 0;
    final batch = <Object?>[];
    int batchBytes = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final placeholders = List.filled(batch.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT rowid AS rid, payload FROM chat_cache '
        'WHERE rowid IN ($placeholders)',
        List<Object?>.from(batch),
      );
      final writes = db.batch();
      for (final row in rows) {
        final raw = row['payload'];
        // Already a BLOB (interrupted earlier run) — leave it alone.
        if (raw is! String) continue;
        writes.update(
          'chat_cache',
          {
            'payload': _encodePayload(raw),
            'search_text': buildChatSearchText(raw),
          },
          where: 'rowid = ?',
          whereArgs: [row['rid']],
        );
        migrated++;
      }
      await writes.commit(noResult: true);
      batch.clear();
      batchBytes = 0;
    }

    for (final row in index) {
      final size = (row['size'] as num?)?.toInt() ?? 0;
      if (batch.isNotEmpty && batchBytes + size > _batchByteBudget) {
        await flush();
      }
      batch.add(row['rid']);
      batchBytes += size;
    }
    await flush();

    if (kDebugMode) {
      debugPrint(
        '🗜️ [CacheService] Compressed $migrated payloads in '
        '${stopwatch.elapsedMilliseconds}ms',
      );
    }
  }

  /// Close the cached handle and forget migration state.
  ///
  /// Tests point the application support directory at a fresh temp dir per
  /// case. Without this the static handle would outlive that directory and
  /// every later write would hit a deleted file.
  @visibleForTesting
  static Future<void> debugReset() async {
    await _db?.close();
    _db = null;
    _migrationChecked.clear();
  }

  // ─── Generic KV cache (for projects, etc.) ─────────────────────────────

  /// Read a cached value by key.
  static Future<String?> kvGet(String key) async {
    final db = await _getDb();
    final rows = await db.query(
      'kv_cache',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// Write a cached value by key.
  static Future<void> kvSet(String key, String value) async {
    final db = await _getDb();
    await db.insert('kv_cache', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Write [value] under [key] only when the key holds nothing yet. Returns
  /// true when this call wrote it. The check and the write run in one
  /// transaction, so a newer value another writer stored in between is never
  /// overwritten — which is what a one-time migration of an old copy needs.
  static Future<bool> kvSetIfAbsent(String key, String value) async {
    final db = await _getDb();
    return db.transaction((txn) async {
      final rows = await txn.query(
        'kv_cache',
        columns: ['key'],
        where: 'key = ?',
        whereArgs: [key],
      );
      if (rows.isNotEmpty) return false;
      await txn.insert('kv_cache', {'key': key, 'value': value});
      return true;
    });
  }

  /// Delete a cached value by key.
  static Future<void> kvDelete(String key) async {
    final db = await _getDb();
    await db.delete('kv_cache', where: 'key = ?', whereArgs: [key]);
  }

  // ─── Skills store ──────────────────────────────────────────────────────
  //
  // The local source of truth for the user's skills. Rows are PLAINTEXT here,
  // matching chat_cache: the encryption key lives on the same device, so a
  // second at-rest layer is theatre. The Supabase mirror keeps the SKILL.md
  // encrypted; catalog_name and baseline_hash are not secret (a catalog name
  // and a hash of it), so they stay plaintext on both sides.

  static Future<void> _createSkillsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS skills (
        id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        source TEXT NOT NULL,
        catalog_name TEXT,
        baseline_hash TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (user_id, id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_skills_user ON skills (user_id)',
    );
  }

  /// Every stored skill for [userId], newest first.
  static Future<List<Map<String, dynamic>>> skillRows(String userId) async {
    final db = await _getDb();
    return db.query(
      'skills',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at DESC',
    );
  }

  /// Insert or replace one skill row. [row] must carry id, user_id, source and
  /// updated_at; catalog_name and baseline_hash are optional.
  static Future<void> upsertSkill(Map<String, dynamic> row) async {
    final db = await _getDb();
    await db.insert(
      'skills',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteSkill(String userId, String id) async {
    final db = await _getDb();
    await db.delete(
      'skills',
      where: 'user_id = ? AND id = ?',
      whereArgs: [userId, id],
    );
  }

  /// Replace the whole skill set for [userId] in one transaction — used when a
  /// server sync is the authority and the local copy must match it exactly.
  static Future<void> replaceSkills(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final db = await _getDb();
    await db.transaction((txn) async {
      await txn.delete('skills', where: 'user_id = ?', whereArgs: [userId]);
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'skills',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ─── Public helpers ───────────────────────────────────────────────────

  static Map<String, dynamic> buildPlaintextRow({
    required String id,
    required String payload,
    required String createdAt,
    required bool isStarred,
    String? updatedAt,
    String? title,
  }) => buildPlaintextCacheRow(
    id: id,
    payload: payload,
    createdAt: createdAt,
    isStarred: isStarred,
    updatedAt: updatedAt,
    title: title,
  );

  // ─── Public API ───────────────────────────────────────────────────────

  static Future<void> replaceAll(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final sanitized = <Map<String, dynamic>>[
      for (final row in rows) ?_sanitizeRow(row),
    ];
    final dbRows = await _toDbRows(userId, sanitized);
    final db = await _getDb();
    final batch = db.batch();
    batch.delete('chat_cache', where: 'user_id = ?', whereArgs: [userId]);
    for (final dbRow in dbRows) {
      batch.insert('chat_cache', dbRow);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> upsert(String userId, Map<String, dynamic> row) async {
    final s = _sanitizeRow(row);
    if (s == null) return;
    final dbRows = await _toDbRows(userId, [s]);
    final db = await _getDb();
    await db.insert(
      'chat_cache',
      dbRows.single,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Replace the payload of one row with [payload], but only while the row
  /// is still the one the caller read: same `updated_at`, same stored size.
  /// Returns whether it was written. For the background upgrade of old rows
  /// to v3, which must never overwrite a save that came in meanwhile.
  static Future<bool> replacePayloadIfUnchanged(
    String userId,
    String chatId, {
    required String payload,
    required String? expectedUpdatedAt,
    required int expectedStoredLength,
  }) async {
    final dbRows = await _toDbRows(userId, [
      <String, dynamic>{'id': chatId, 'payload': payload},
    ]);
    final encoded = dbRows.single;
    final db = await _getDb();
    final count = await db.rawUpdate(
      'UPDATE chat_cache SET payload = ?, search_text = ? '
      'WHERE user_id = ? AND id = ? AND updated_at IS ? '
      'AND LENGTH(payload) = ?',
      [
        encoded['payload'],
        encoded['search_text'],
        userId,
        chatId,
        expectedUpdatedAt,
        expectedStoredLength,
      ],
    );
    return count > 0;
  }

  // ─── Maintenance: payload v3 upgrade ──────────────────────────────────

  static const String _backupName = 'chat_cache.backup.db';

  static Future<String> _dbPath() async =>
      p.join((await getApplicationSupportDirectory()).path, _dbName);

  static Future<String> _backupPath() async =>
      p.join((await getApplicationSupportDirectory()).path, _backupName);

  /// Ids of [userId]'s rows that are not a payload frame yet (plain TEXT or
  /// the gzip BLOB of before v3). Reads no payloads.
  static Future<List<String>> idsNeedingPayloadUpgrade(String userId) async {
    await _runMigrations(userId);
    final db = await _getDb();
    final rows = await db.rawQuery(
      "SELECT id FROM chat_cache WHERE user_id = ? AND "
      "(typeof(payload) != 'blob' OR substr(payload, 1, 1) != x'00')",
      [userId],
    );
    return [for (final row in rows) row['id'] as String];
  }

  /// Write a consistent copy of the whole cache next to it
  /// (`VACUUM INTO`), replacing an older backup. Returns its path.
  static Future<String> backupDatabase() async {
    final db = await _getDb();
    final path = await _backupPath();
    final file = File(path);
    if (await file.exists()) await file.delete();
    await db.execute('VACUUM INTO ?', [path]);
    return path;
  }

  /// Put the backup of [backupDatabase] back in place of the cache. The
  /// handle is closed first and reopened by the next call.
  static Future<void> restoreBackup() async {
    final backup = File(await _backupPath());
    if (!await backup.exists()) {
      throw StateError('No chat cache backup to restore');
    }
    await _db?.close();
    _db = null;
    _migrationChecked.clear();
    final dbPath = await _dbPath();
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final side = File('$dbPath$suffix');
      if (await side.exists()) await side.delete();
    }
    await backup.copy(dbPath);
  }

  /// Remove the backup of [backupDatabase], if there is one.
  static Future<void> deleteBackup() async {
    final file = File(await _backupPath());
    if (await file.exists()) await file.delete();
  }

  /// Whether a backup of [backupDatabase] exists.
  static Future<bool> hasBackup() async => File(await _backupPath()).exists();

  /// Set `updated_at` of one row to [value], but only while it is still
  /// [expected]: the cloud row was rewritten with a new timestamp, and the
  /// cache must follow it or the next sync downloads the chat again.
  static Future<bool> updateUpdatedAtIfEqual(
    String userId,
    String chatId, {
    required String expected,
    required String value,
  }) async {
    final db = await _getDb();
    final count = await db.rawUpdate(
      'UPDATE chat_cache SET updated_at = ? '
      'WHERE user_id = ? AND id = ? AND updated_at = ?',
      [value, userId, chatId, expected],
    );
    return count > 0;
  }

  /// One row with its payload decoded, plus what
  /// [replacePayloadIfUnchanged] needs to detect a change: the stored
  /// payload length and whether the row is already a v3-era frame.
  static Future<({Map<String, dynamic> row, int storedLength, bool framed})?>
  loadRawById(String userId, String chatId) async {
    final db = await _getDb();
    final rows = await db.rawQuery(
      'SELECT *, LENGTH(payload) AS stored_length FROM chat_cache '
      'WHERE user_id = ? AND id = ? LIMIT 1',
      [userId, chatId],
    );
    if (rows.isEmpty) return null;
    final raw = rows.first;
    final stored = raw['payload'];
    return (
      row: _fromDbRow(raw),
      storedLength: (raw['stored_length'] as num?)?.toInt() ?? 0,
      framed: stored is List<int> && isPayloadFrame(stored),
    );
  }

  /// Encode rows for the table. Large payloads are compressed (and their
  /// search text extracted) in a background isolate.
  static Future<List<Map<String, dynamic>>> _toDbRows(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    var chars = 0;
    for (final row in rows) {
      chars += (row['payload'] as String).length;
    }
    final encoded = chars < _backgroundEncodeMinChars
        ? _encodePayloads([for (final row in rows) row['payload'] as String])
        : await compute(_encodePayloads, [
            for (final row in rows) row['payload'] as String,
          ]);
    return [
      for (var i = 0; i < rows.length; i++)
        _toDbRow(userId, rows[i], encoded[i]),
    ];
  }

  static Future<void> delete(String userId, String chatId) async {
    final db = await _getDb();
    await db.delete(
      'chat_cache',
      where: 'user_id = ? AND id = ?',
      whereArgs: [userId, chatId],
    );
  }

  static Future<void> updateStarred(
    String userId,
    String chatId,
    bool isStarred,
  ) async {
    final db = await _getDb();
    await db.update(
      'chat_cache',
      {'is_starred': isStarred ? 1 : 0},
      where: 'user_id = ? AND id = ?',
      whereArgs: [userId, chatId],
    );
  }

  /// Byte budget for one sqflite result batch.
  ///
  /// Every query result crosses the platform method channel as a single
  /// `ByteBuffer` allocated on the Java heap (256 MB growth limit on
  /// Android). A full-table `SELECT` over a mature cache reaches tens of
  /// megabytes and dies in `StandardMethodCodec.encodeSuccessEnvelope`
  /// with an `OutOfMemoryError` before Dart ever sees a row. Batching by
  /// payload bytes — not by row count — keeps every envelope small no
  /// matter how the chats are sized.
  static const int _batchByteBudget = 4 * 1024 * 1024;

  /// Columns of `chat_cache` without the heavy `payload` blob.
  static const String _metaColumns =
      'id, title, created_at, updated_at, is_starred';

  /// Load cached chats without their payloads.
  ///
  /// The sidebar only renders titles and timestamps. Reading the payload
  /// column for that is what made startup allocate the whole cache at
  /// once.
  static Future<List<Map<String, dynamic>>> loadMeta(String userId) async {
    await _runMigrations(userId);

    final db = await _getDb();
    final rows = await db.rawQuery(
      'SELECT $_metaColumns FROM chat_cache WHERE user_id = ? '
      'ORDER BY created_at DESC',
      [userId],
    );

    return rows.map(_fromDbMetaRow).toList(growable: false);
  }

  /// Fetch full rows for an index of `{rid, size}` records, splitting the
  /// reads so no single result batch exceeds [_batchByteBudget].
  ///
  /// [index] must already be in the wanted order; [orderBy] repeats that
  /// order inside each batch so the concatenated result stays sorted.
  static Future<List<Map<String, dynamic>>> _fetchBatched(
    Database db,
    List<Map<String, Object?>> index, {
    required String orderBy,
  }) async {
    final results = <Map<String, dynamic>>[];
    final batch = <Object?>[];
    int batchBytes = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final placeholders = List.filled(batch.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT * FROM chat_cache WHERE rowid IN ($placeholders) '
        'ORDER BY $orderBy',
        List<Object?>.from(batch),
      );
      results.addAll(rows.map(_fromDbRow));
      batch.clear();
      batchBytes = 0;
    }

    for (final row in index) {
      final size = (row['size'] as num?)?.toInt() ?? 0;
      // Flush before adding when this row would push the batch over
      // budget, so a single oversized chat still travels on its own.
      if (batch.isNotEmpty && batchBytes + size > _batchByteBudget) {
        await flush();
      }
      batch.add(row['rid']);
      batchBytes += size;
    }
    await flush();

    return results;
  }

  /// Count cached chats for one user.
  static Future<int> count(String userId) async {
    await _runMigrations(userId);
    final db = await _getDb();
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM chat_cache WHERE user_id = ?',
      [userId],
    );
    if (result.isEmpty) return 0;
    final value = result.first['count'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// Load one cached chat row by chat ID.
  static Future<Map<String, dynamic>?> loadById(
    String userId,
    String chatId,
  ) async {
    await _runMigrations(userId);
    final db = await _getDb();
    final rows = await db.query(
      'chat_cache',
      where: 'user_id = ? AND id = ?',
      whereArgs: [userId, chatId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromDbRow(rows.first);
  }

  /// Fast case-insensitive search over title + plaintext payload.
  /// Uses parameterized SQL to avoid injection.
  static Future<List<Map<String, dynamic>>> search(
    String userId,
    String query, {
    int limit = 100,
  }) async {
    await _runMigrations(userId);
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <Map<String, dynamic>>[];

    final db = await _getDb();
    final cappedLimit = limit.clamp(1, 500).toInt();
    final escaped = _escapeLikePattern(trimmed.toLowerCase());
    final pattern = '%$escaped%';

    // Match inside SQLite and return only row ids plus payload sizes, then
    // read the matching payloads in byte-bounded batches. Selecting the
    // payloads directly can exceed the method-channel envelope limit —
    // `cappedLimit` bounds the row count, not the bytes behind it.
    const String orderBy = 'COALESCE(updated_at, created_at) DESC';
    final index = await db.rawQuery(
      '''
      SELECT rowid AS rid, LENGTH(payload) AS size
      FROM chat_cache
      WHERE user_id = ?
        AND (
          LOWER(COALESCE(title, '')) LIKE ? ESCAPE '\\'
          OR COALESCE(search_text, '') LIKE ? ESCAPE '\\'
        )
      ORDER BY $orderBy
      LIMIT ?
      ''',
      [userId, pattern, pattern, cappedLimit],
    );
    if (index.isEmpty) return const <Map<String, dynamic>>[];

    final rows = await _fetchBatched(db, index, orderBy: orderBy);
    return List<Map<String, dynamic>>.unmodifiable(rows);
  }

  /// Run all pending migrations (v1/v2/v3 → SQLite).
  /// Call this early at startup to clean up SharedPreferences even if
  /// `load()` is not called (sidebar uses the lightweight title cache).
  /// Also cleans up old SharedPreferences data to shrink the prefs file.
  static Future<void> ensureMigrated(String userId) async {
    try {
      await _runMigrations(userId);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CacheService] SQLite migration failed: $e');
      }
    }

    // Always clean up old SharedPreferences data (v1 + v2) to shrink the
    // prefs file. Data is available from Supabase — safe to delete.
    await _cleanupOldPrefsData(userId);
  }

  /// Remove old bulky cache data from SharedPreferences.
  /// This is critical for fixing the Linux startup freeze regardless of
  /// whether SQLite migration succeeds.
  static Future<void> _cleanupOldPrefsData(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Remove v2 plaintext cache.
      final v2Key = '$_oldV2PrefsKey$userId';
      if (prefs.containsKey(v2Key)) {
        await prefs.remove(v2Key);
        if (kDebugMode) {
          debugPrint(
            '🧹 [CacheService] Removed old v2 cache from SharedPreferences',
          );
        }
      }

      // Remove ALL v1 encrypted caches (current user + any old test accounts).
      // Also remove stale model cache and old workspace cache.
      final keysToRemove = prefs
          .getKeys()
          .where(
            (k) =>
                k.startsWith('cached_encrypted_chats_v1') ||
                k == 'cached_models_v1' ||
                k == 'cached_projects',
          )
          .toList();

      for (final key in keysToRemove) {
        await prefs.remove(key);
      }

      if (keysToRemove.isNotEmpty && kDebugMode) {
        debugPrint(
          '🧹 [CacheService] Removed ${keysToRemove.length} old cache keys '
          'from SharedPreferences',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CacheService] SharedPreferences cleanup failed: $e');
      }
    }
  }

  static Future<void> clear(String userId) async {
    final db = await _getDb();
    await db.delete('chat_cache', where: 'user_id = ?', whereArgs: [userId]);
  }

  // ─── Migration: v1 encrypted SharedPreferences → SQLite ───────────────

  static Future<bool> hasOldEncryptedCache(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_oldV1PrefsKey$userId');
  }

  static Future<bool> migrateFromEncrypted(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final oldKey = '$_oldV1PrefsKey$userId';
    final raw = prefs.getString(oldKey);
    if (raw == null) return false;

    if (kDebugMode) {
      debugPrint('🔄 [CacheService] Migrating from encrypted v1 → SQLite...');
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await prefs.remove(oldKey);
        return false;
      }
      if (decoded['version'] != 1) {
        await prefs.remove(oldKey);
        return false;
      }
      final chatsRaw = decoded['chats'];
      if (chatsRaw is! List) {
        await prefs.remove(oldKey);
        return false;
      }

      final encPayloads = <String>[];
      final encTitles = <String?>[];
      final entries = <Map<String, dynamic>>[];

      for (final entry in chatsRaw) {
        if (entry is! Map<String, dynamic>) continue;
        final id = entry['id'];
        final enc = entry['encrypted_payload'];
        if (id is! String || enc is! String) continue;
        encPayloads.add(enc);
        encTitles.add(entry['encrypted_title'] as String?);
        entries.add(entry);
      }

      if (encPayloads.isEmpty) {
        await prefs.remove(oldKey);
        return false;
      }

      final decPayloads = await EncryptionService.decryptBatchInBackground(
        encPayloads,
      );

      final titleTexts = <String>[];
      final titleIdx = <int>[];
      for (int i = 0; i < encTitles.length; i++) {
        final t = encTitles[i];
        if (t != null && t.isNotEmpty) {
          titleTexts.add(t);
          titleIdx.add(i);
        }
      }
      final decTitles = titleTexts.isNotEmpty
          ? await EncryptionService.decryptBatchInBackground(titleTexts)
          : <String?>[];

      final titleMap = <int, String?>{};
      for (int j = 0; j < titleIdx.length; j++) {
        titleMap[titleIdx[j]] = decTitles[j];
      }

      final rows = <Map<String, dynamic>>[];
      for (int i = 0; i < entries.length; i++) {
        final dec = decPayloads[i];
        if (dec == null) continue;
        final e = entries[i];
        rows.add(
          buildPlaintextRow(
            id: e['id'] as String,
            payload: dec,
            createdAt:
                e['created_at'] as String? ??
                DateTime.now().toUtc().toIso8601String(),
            isStarred: (e['is_starred'] as bool?) ?? false,
            updatedAt: e['updated_at'] as String?,
            title: titleMap[i],
          ),
        );
      }

      await replaceAll(userId, rows);
      await prefs.remove(oldKey);

      if (kDebugMode) {
        debugPrint(
          '✅ [CacheService] Migrated ${rows.length} chats from v1 → SQLite',
        );
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CacheService] v1 migration failed: $e');
      }
      await prefs.remove(oldKey);
      return false;
    }
  }

  // ─── Auto-migration (v2 SharedPrefs + v3 JSON file → SQLite) ──────────

  static final Set<String> _migrationChecked = {};

  static Future<void> _runMigrations(String userId) async {
    if (_migrationChecked.contains(userId)) return;
    _migrationChecked.add(userId);

    // Check if we already have data in SQLite.
    final db = await _getDb();
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM chat_cache WHERE user_id = ?',
      [userId],
    );
    final count = result.isNotEmpty ? result.first.values.first as int? : null;
    if (count != null && count > 0) return;

    // Try migrating from v3 JSON file first (most recent format).
    if (await _migrateV3File(userId)) return;

    // Then try v2 SharedPreferences.
    await _migrateV2Prefs(userId);
  }

  static Future<bool> _migrateV3File(String userId) async {
    try {
      final baseDir = await getApplicationSupportDirectory();
      final file = File(p.join(baseDir.path, '$_oldV3FilePrefix$userId.json'));
      if (!await file.exists()) return false;

      final raw = await file.readAsString();
      if (raw.isEmpty) return false;

      if (kDebugMode) {
        final sizeMb = (raw.length / 1024 / 1024).toStringAsFixed(1);
        debugPrint(
          '🔄 [CacheService] Migrating v3 JSON file ($sizeMb MB) → SQLite...',
        );
      }

      final rows = await compute(_parseJsonCacheInIsolate, raw);
      if (rows.isEmpty) return false;

      await replaceAll(userId, rows);

      // Delete old file.
      await file.delete();

      if (kDebugMode) {
        debugPrint(
          '✅ [CacheService] Migrated ${rows.length} chats from v3 file → SQLite',
        );
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CacheService] v3 file migration failed: $e');
      }
      return false;
    }
  }

  static Future<bool> _migrateV2Prefs(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final oldKey = '$_oldV2PrefsKey$userId';
      final raw = prefs.getString(oldKey);
      if (raw == null || raw.isEmpty) return false;

      if (kDebugMode) {
        final sizeMb = (raw.length / 1024 / 1024).toStringAsFixed(1);
        debugPrint(
          '🔄 [CacheService] Migrating v2 SharedPreferences '
          '($sizeMb MB) → SQLite...',
        );
      }

      final rows = await compute(_parseJsonCacheInIsolate, raw);
      if (rows.isEmpty) return false;

      await replaceAll(userId, rows);

      // Remove from SharedPreferences.
      await prefs.remove(oldKey);

      if (kDebugMode) {
        debugPrint(
          '✅ [CacheService] Migrated ${rows.length} chats from v2 prefs → SQLite',
        );
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CacheService] v2 prefs migration failed: $e');
      }
      return false;
    }
  }

  // ─── Row conversion ───────────────────────────────────────────────────

  /// Encode a payload for storage: always a deflate frame (see above).
  static Object _encodePayload(String payload) => compressPayloadFast(payload);

  /// Decode a stored payload. Accepts payload frames, the gzip BLOBs of
  /// v4/v5 and legacy plain TEXT, so every row ever written still reads.
  static String _decodePayload(Object? stored) {
    if (stored is String) return stored;
    if (stored is List<int>) return decodeStoredPayload(stored);
    throw StateError('Unsupported payload storage type: ${stored.runtimeType}');
  }

  static Map<String, dynamic> _toDbRow(
    String userId,
    Map<String, dynamic> row,
    _EncodedPayload encoded,
  ) {
    return {
      'id': row['id'],
      'user_id': userId,
      'payload': encoded.stored,
      'title': row['title'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
      'is_starred': row['is_starred'] == true ? 1 : 0,
      'search_text': encoded.searchText,
    };
  }

  /// Map a payload-less row (see [loadMeta]). The `payload` key is absent
  /// rather than empty so a caller that needs it fails loudly instead of
  /// silently treating a chat as having no messages.
  static Map<String, dynamic> _fromDbMetaRow(Map<String, dynamic> row) {
    return <String, dynamic>{
      'id': row['id'] as String,
      'created_at': row['created_at'] as String,
      'is_starred': (row['is_starred'] as int?) == 1,
      if (row['updated_at'] != null) 'updated_at': row['updated_at'],
      if (row['title'] != null) 'title': row['title'],
    };
  }

  static Map<String, dynamic> _fromDbRow(Map<String, dynamic> row) {
    return <String, dynamic>{
      'id': row['id'] as String,
      'payload': _decodePayload(row['payload']),
      'created_at': row['created_at'] as String,
      'is_starred': (row['is_starred'] as int?) == 1,
      if (row['updated_at'] != null) 'updated_at': row['updated_at'],
      if (row['title'] != null) 'title': row['title'],
    };
  }

  static Map<String, dynamic>? _sanitizeRow(Map<String, dynamic> row) =>
      sanitizeCacheRow(row);

  static String _escapeLikePattern(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }
}

// ─── Top-level isolate functions ────────────────────────────────────────────

/// A payload as the table stores it, with its search text.
typedef _EncodedPayload = ({Object stored, String? searchText});

List<_EncodedPayload> _encodePayloads(List<String> payloads) => [
  for (final payload in payloads)
    (
      stored: LocalChatCacheService._encodePayload(payload),
      searchText: buildChatSearchText(payload),
    ),
];

/// Parse JSON cache data in a background isolate (for migration reads).
List<Map<String, dynamic>> _parseJsonCacheInIsolate(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final version = decoded['version'];
  if (version is! int || (version != 2 && version != 3)) return const [];
  final chatsRaw = decoded['chats'];
  if (chatsRaw is! List) return const [];

  final chats = <Map<String, dynamic>>[];
  for (final entry in chatsRaw) {
    if (entry is! Map<String, dynamic>) continue;
    final id = entry['id'];
    final payload = entry['payload'];
    if (id is! String || payload is! String) continue;

    String? createdAt;
    final raw = entry['created_at'];
    if (raw is String) {
      createdAt = raw;
    } else if (raw == null) {
      createdAt = DateTime.now().toUtc().toIso8601String();
    } else {
      continue;
    }

    chats.add(<String, dynamic>{
      'id': id,
      'payload': payload,
      'created_at': createdAt,
      'is_starred': (entry['is_starred'] as bool?) ?? false,
      if (entry['updated_at'] is String) 'updated_at': entry['updated_at'],
      if (entry['title'] is String) 'title': entry['title'],
    });
  }
  return chats;
}
