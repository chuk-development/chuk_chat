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

import 'package:chuk_chat/services/encryption_service.dart';

class LocalChatCacheService {
  static const String _dbName = 'chat_cache.db';
  static const int _dbVersion = 1;

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

    _db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE chat_cache (
            id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            title TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT,
            is_starred INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (user_id, id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_chat_cache_user ON chat_cache (user_id)',
        );
      },
    );

    return _db!;
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
    return <String, dynamic>{
      'id': id,
      'payload': payload,
      'created_at': createdAt,
      'is_starred': isStarred,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (title != null) 'title': title,
    };
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

  static Future<List<Map<String, dynamic>>> load(String userId) async {
    await _runMigrations(userId);

    final db = await _getDb();
    final rows = await db.query(
      'chat_cache',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );

    return rows.map(_fromDbRow).toList();
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

      // Remove v1 encrypted cache (can be 10+ MB).
      // Data is available from Supabase — no need to decrypt.
      final v1Key = '$_oldV1PrefsKey$userId';
      if (prefs.containsKey(v1Key)) {
        await prefs.remove(v1Key);
        if (kDebugMode) {
          debugPrint(
            '🧹 [CacheService] Removed old v1 encrypted cache from '
            'SharedPreferences',
          );
        }
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

      final decPayloads =
          await EncryptionService.decryptBatchInBackground(encPayloads);

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
        rows.add(buildPlaintextRow(
          id: e['id'] as String,
          payload: dec,
          createdAt: e['created_at'] as String? ??
              DateTime.now().toUtc().toIso8601String(),
          isStarred: (e['is_starred'] as bool?) ?? false,
          updatedAt: e['updated_at'] as String?,
          title: titleMap[i],
        ));
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

  static Map<String, dynamic> _toDbRow(
    String userId,
    Map<String, dynamic> row,
  ) {
    return {
      'id': row['id'],
      'user_id': userId,
      'payload': row['payload'],
      'title': row['title'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
      'is_starred': row['is_starred'] == true ? 1 : 0,
    };
  }

  static Map<String, dynamic> _fromDbRow(Map<String, dynamic> row) {
    return <String, dynamic>{
      'id': row['id'] as String,
      'payload': row['payload'] as String,
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
    final isStarred =
        starred is bool ? starred : (starred is num ? starred != 0 : false);

    return <String, dynamic>{
      'id': id,
      'payload': payload,
      'created_at': createdAt,
      'is_starred': isStarred,
      if (row['updated_at'] is String) 'updated_at': row['updated_at'],
      if (row['title'] is String) 'title': row['title'],
    };
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
