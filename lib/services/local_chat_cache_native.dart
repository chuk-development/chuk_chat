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

class LocalChatCacheService {
  static const String _dbName = 'chat_cache.db';
  static const int _dbVersion = 4;

  /// Payloads are gzipped before they hit the `payload` column.
  ///
  /// A chat is JSON with long, highly repetitive tool results, so it
  /// compresses about 4x. That shrinks the file, the platform-channel
  /// traffic and the memory each read allocates. Level 4 reaches within
  /// 4% of level 9 at half the CPU time, which matters because the
  /// one-time migration of an existing cache runs at app start.
  static final GZipCodec _payloadCodec = GZipCodec(level: 4);

  /// Below this size the gzip header costs more than it saves.
  static const int _compressMinBytes = 512;

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
        await db.execute(
          'CREATE INDEX idx_chat_cache_user ON chat_cache (user_id)',
        );
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
          await db.execute('ALTER TABLE chat_cache ADD COLUMN search_text TEXT');
          await _compressExistingPayloads(db);
          needsVacuum = true;
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

  /// Delete a cached value by key.
  static Future<void> kvDelete(String key) async {
    final db = await _getDb();
    await db.delete('kv_cache', where: 'key = ?', whereArgs: [key]);
  }

  // ─── Public helpers ───────────────────────────────────────────────────

  static Map<String, dynamic> buildPlaintextRow({
    required String id,
    required String payload,
    required String createdAt,
    required bool isStarred,
    String? updatedAt,
    String? title,
  }) {
    final row = <String, dynamic>{
      'id': id,
      'payload': payload,
      'created_at': createdAt,
      'is_starred': isStarred,
    };

    if (updatedAt != null) {
      row['updated_at'] = updatedAt;
    }
    if (title != null) {
      row['title'] = title;
    }

    return row;
  }

  // ─── Public API ───────────────────────────────────────────────────────

  static Future<void> replaceAll(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final db = await _getDb();
    final batch = db.batch();
    batch.delete('chat_cache', where: 'user_id = ?', whereArgs: [userId]);
    for (final row in rows) {
      final s = _sanitizeRow(row);
      if (s == null) continue;
      batch.insert('chat_cache', _toDbRow(userId, s));
    }
    await batch.commit(noResult: true);
  }

  static Future<void> upsert(String userId, Map<String, dynamic> row) async {
    final s = _sanitizeRow(row);
    if (s == null) return;
    final db = await _getDb();
    await db.insert(
      'chat_cache',
      _toDbRow(userId, s),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

  /// Encode a payload for storage: gzip unless it is too small to gain.
  static Object _encodePayload(String payload) {
    final bytes = utf8.encode(payload);
    if (bytes.length < _compressMinBytes) return payload;
    return Uint8List.fromList(_payloadCodec.encode(bytes));
  }

  /// Decode a stored payload. Accepts gzipped BLOBs and legacy plain TEXT,
  /// so a row written before the v4 upgrade still reads correctly.
  static String _decodePayload(Object? stored) {
    if (stored is String) return stored;
    if (stored is List<int>) {
      return utf8.decode(_payloadCodec.decode(stored));
    }
    throw StateError(
      'Unsupported payload storage type: ${stored.runtimeType}',
    );
  }

  static Map<String, dynamic> _toDbRow(
    String userId,
    Map<String, dynamic> row,
  ) {
    final payload = row['payload'] as String;
    return {
      'id': row['id'],
      'user_id': userId,
      'payload': _encodePayload(payload),
      'title': row['title'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
      'is_starred': row['is_starred'] == true ? 1 : 0,
      'search_text': buildChatSearchText(payload),
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

  static Map<String, dynamic>? _sanitizeRow(Map<String, dynamic> row) {
    final id = row['id'];
    final payload = row['payload'];
    if (id is! String || payload is! String) return null;

    String? createdAt;
    final raw = row['created_at'];
    if (raw is String) {
      createdAt = raw;
    } else if (raw is DateTime) {
      createdAt = raw.toUtc().toIso8601String();
    }
    createdAt ??= DateTime.now().toUtc().toIso8601String();

    final starred = row['is_starred'];
    final isStarred = starred is bool
        ? starred
        : (starred is num ? starred != 0 : false);

    return <String, dynamic>{
      'id': id,
      'payload': payload,
      'created_at': createdAt,
      'is_starred': isStarred,
      if (row['updated_at'] is String) 'updated_at': row['updated_at'],
      if (row['title'] is String) 'title': row['title'],
    };
  }

  static String _escapeLikePattern(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }
}

// ─── Top-level isolate function ─────────────────────────────────────────────

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
