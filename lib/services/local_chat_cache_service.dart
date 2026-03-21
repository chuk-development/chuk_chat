import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

// ─── Top-level isolate functions ────────────────────────────────────────────

/// Parse + sanitize cache JSON in a background isolate (for reads).
List<Map<String, dynamic>> _parseAndSanitizeCacheInIsolate(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    return const <Map<String, dynamic>>[];
  }
  final version = decoded['version'];
  if (version is! int || (version != 2 && version != 3)) {
    return const <Map<String, dynamic>>[];
  }
  final chatsRaw = decoded['chats'];
  if (chatsRaw is! List) {
    return const <Map<String, dynamic>>[];
  }
  final List<Map<String, dynamic>> chats = [];
  for (final entry in chatsRaw) {
    if (entry is Map<String, dynamic>) {
      final id = entry['id'];
      final payload = entry['payload'];
      final createdAtRaw = entry['created_at'];
      if (id is! String || payload is! String) {
        continue;
      }
      String? createdAt;
      if (createdAtRaw is String) {
        createdAt = createdAtRaw;
      } else if (createdAtRaw == null) {
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
  }
  chats.sort((a, b) {
    final aDate = a['created_at'] as String;
    final bDate = b['created_at'] as String;
    return bDate.compareTo(aDate);
  });
  return chats;
}

/// Serialize cache data to JSON in a background isolate (for writes).
String _serializeCacheInIsolate(List<Map<String, dynamic>> chats) {
  return jsonEncode(<String, dynamic>{
    'version': 3,
    'chats': chats,
  });
}

// ─── Service ────────────────────────────────────────────────────────────────

class LocalChatCacheService {
  /// Old v2 SharedPreferences key prefix (for migration).
  static const String _oldV2StorageKeyPrefix = 'cached_chats_v2-';

  /// Old v1 encrypted cache key prefix (for migration).
  static const String _oldV1StorageKeyPrefix =
      'cached_encrypted_chats_v1-';

  const LocalChatCacheService._();

  /// Resolved cache file paths per userId.
  static final Map<String, File> _fileCache = {};

  /// Write lock to serialize file writes and prevent corruption.
  static Completer<void>? _writeLock;

  /// Get (or create) the cache file for a user.
  static Future<File> _getCacheFile(String userId) async {
    final cached = _fileCache[userId];
    if (cached != null) return cached;

    final baseDir = await getApplicationSupportDirectory();
    // Ensure directory exists (no-op if already present).
    await Directory(baseDir.path).create(recursive: true);
    final file = File('${baseDir.path}/chat_cache_v3_$userId.json');
    _fileCache[userId] = file;
    return file;
  }

  /// Build a plaintext cache row from pre-encryption data.
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

  // ─── Public API ─────────────────────────────────────────────────────────

  static Future<void> replaceAll(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final sanitized = rows
        .map(_sanitizeRow)
        .where((row) => row != null)
        .cast<Map<String, dynamic>>()
        .toList(growable: false);
    _sortByCreatedAtDescending(sanitized);
    await _persist(userId, sanitized);
  }

  static Future<void> upsert(String userId, Map<String, dynamic> row) async {
    final sanitized = _sanitizeRow(row);
    if (sanitized == null) return;

    final chats = await _loadChats(userId);

    final existingIndex = chats.indexWhere(
      (entry) => entry['id'] == sanitized['id'],
    );
    if (existingIndex != -1) {
      chats[existingIndex] = sanitized;
    } else {
      chats.add(sanitized);
    }
    _sortByCreatedAtDescending(chats);
    await _persist(userId, chats);
  }

  static Future<void> delete(String userId, String chatId) async {
    final chats = await _loadChats(userId);
    final originalLength = chats.length;
    chats.removeWhere((entry) => entry['id'] == chatId);
    if (chats.length == originalLength) return;
    await _persist(userId, chats);
  }

  static Future<void> updateStarred(
    String userId,
    String chatId,
    bool isStarred,
  ) async {
    final chats = await _loadChats(userId);
    final index = chats.indexWhere((entry) => entry['id'] == chatId);
    if (index == -1) return;
    chats[index] = Map<String, dynamic>.from(chats[index])
      ..['is_starred'] = isStarred;
    await _persist(userId, chats);
  }

  /// Load all cached chat rows for a user.
  static Future<List<Map<String, dynamic>>> load(String userId) async {
    // Ensure migration has run first.
    await _migrateV2ToFile(userId);

    final file = await _getCacheFile(userId);
    if (!await file.exists()) return const <Map<String, dynamic>>[];

    try {
      final raw = await file.readAsString();
      if (raw.isEmpty) return const <Map<String, dynamic>>[];
      return await compute(_parseAndSanitizeCacheInIsolate, raw);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CacheService] Failed to read cache file: $e');
      }
      return const <Map<String, dynamic>>[];
    }
  }

  static Future<void> clear(String userId) async {
    final file = await _getCacheFile(userId);
    if (await file.exists()) {
      await file.delete();
    }
    _fileCache.remove(userId);
  }

  // ─── Migration: v1 encrypted SharedPreferences → v3 file ───────────────

  /// Check if old encrypted v1 cache exists for this user.
  static Future<bool> hasOldEncryptedCache(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final oldKey = '$_oldV1StorageKeyPrefix$userId';
    return prefs.containsKey(oldKey);
  }

  /// Migrate from old encrypted v1 cache to plaintext v3 file.
  static Future<bool> migrateFromEncrypted(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final oldKey = '$_oldV1StorageKeyPrefix$userId';
    final raw = prefs.getString(oldKey);
    if (raw == null) return false;

    if (kDebugMode) {
      debugPrint('🔄 [CacheService] Migrating from encrypted v1 cache...');
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await prefs.remove(oldKey);
        return false;
      }
      final version = decoded['version'];
      final chatsRaw = decoded['chats'];
      if (version != 1 || chatsRaw is! List) {
        await prefs.remove(oldKey);
        return false;
      }

      final encryptedPayloads = <String>[];
      final encryptedTitles = <String?>[];
      final validEntries = <Map<String, dynamic>>[];

      for (final entry in chatsRaw) {
        if (entry is! Map<String, dynamic>) continue;
        final id = entry['id'];
        final encPayload = entry['encrypted_payload'];
        if (id is! String || encPayload is! String) continue;

        encryptedPayloads.add(encPayload);
        encryptedTitles.add(entry['encrypted_title'] as String?);
        validEntries.add(entry);
      }

      if (encryptedPayloads.isEmpty) {
        await prefs.remove(oldKey);
        return false;
      }

      final decryptedPayloads =
          await EncryptionService.decryptBatchInBackground(encryptedPayloads);

      final titlePayloads = <String>[];
      final titleIndices = <int>[];
      for (int i = 0; i < encryptedTitles.length; i++) {
        final t = encryptedTitles[i];
        if (t != null && t.isNotEmpty) {
          titlePayloads.add(t);
          titleIndices.add(i);
        }
      }
      final decryptedTitles = titlePayloads.isNotEmpty
          ? await EncryptionService.decryptBatchInBackground(titlePayloads)
          : <String?>[];

      final plaintextRows = <Map<String, dynamic>>[];
      final titleMap = <int, String?>{};
      for (int j = 0; j < titleIndices.length; j++) {
        titleMap[titleIndices[j]] = decryptedTitles[j];
      }

      for (int i = 0; i < validEntries.length; i++) {
        final decrypted = decryptedPayloads[i];
        if (decrypted == null) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [CacheService] Migration: failed to decrypt entry '
              '${validEntries[i]['id']} (index $i)',
            );
          }
          continue;
        }

        final entry = validEntries[i];
        plaintextRows.add(buildPlaintextRow(
          id: entry['id'] as String,
          payload: decrypted,
          createdAt: entry['created_at'] as String? ??
              DateTime.now().toUtc().toIso8601String(),
          isStarred: (entry['is_starred'] as bool?) ?? false,
          updatedAt: entry['updated_at'] as String?,
          title: titleMap[i],
        ));
      }

      // Write directly to v3 file (skip SharedPreferences entirely).
      await replaceAll(userId, plaintextRows);

      // Delete old v1 cache from SharedPreferences.
      await prefs.remove(oldKey);

      if (kDebugMode) {
        debugPrint(
          '✅ [CacheService] Migrated ${plaintextRows.length} chats '
          'from encrypted to file cache',
        );
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [CacheService] Migration failed '
          '(Supabase sync will repopulate): $e',
        );
      }
      await prefs.remove(oldKey);
      return false;
    }
  }

  // ─── Migration: v2 plaintext SharedPreferences → v3 file ───────────────

  /// Track per-user whether migration has already been checked this session.
  static final Set<String> _v2MigrationChecked = {};

  /// Move v2 plaintext cache from SharedPreferences to a standalone file.
  /// Called automatically on first `load()` per session.
  static Future<void> _migrateV2ToFile(String userId) async {
    if (_v2MigrationChecked.contains(userId)) return;
    _v2MigrationChecked.add(userId);

    final file = await _getCacheFile(userId);
    // If the v3 file already exists, nothing to migrate.
    if (await file.exists()) return;

    final prefs = await SharedPreferences.getInstance();
    final oldKey = '$_oldV2StorageKeyPrefix$userId';
    final raw = prefs.getString(oldKey);
    if (raw == null || raw.isEmpty) return;

    if (kDebugMode) {
      debugPrint(
        '🔄 [CacheService] Migrating v2 cache from SharedPreferences '
        'to file (${(raw.length / 1024 / 1024).toStringAsFixed(1)} MB)...',
      );
    }

    try {
      // Write directly to file. The parser accepts both version 2 and 3.
      await file.writeAsString(raw, flush: true);

      // Remove from SharedPreferences to shrink the prefs file.
      await prefs.remove(oldKey);

      if (kDebugMode) {
        debugPrint('✅ [CacheService] Migrated v2 cache to file');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CacheService] v2 migration failed: $e');
      }
    }
  }

  // ─── Private helpers ──────────────────────────────────────────────────

  /// Load parsed chats from file (for read-modify-write operations).
  static Future<List<Map<String, dynamic>>> _loadChats(String userId) async {
    await _migrateV2ToFile(userId);

    final file = await _getCacheFile(userId);
    if (!await file.exists()) {
      return <Map<String, dynamic>>[];
    }

    try {
      final raw = await file.readAsString();
      if (raw.isEmpty) return <Map<String, dynamic>>[];

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return <Map<String, dynamic>>[];
      }
      final version = decoded['version'];
      final chats = decoded['chats'];
      if ((version == 2 || version == 3) && chats is List) {
        return chats
            .whereType<Map<String, dynamic>>()
            .map((entry) => _sanitizeRow(entry))
            .whereType<Map<String, dynamic>>()
            .toList(growable: true);
      }
    } catch (_) {
      // Ignore malformed cache.
    }
    return <Map<String, dynamic>>[];
  }

  /// Serialize and write chats to the cache file.
  /// Uses a background isolate for JSON serialization and a write lock
  /// to prevent concurrent file writes.
  static Future<void> _persist(
    String userId,
    List<Map<String, dynamic>> sanitized,
  ) async {
    // Wait for any in-flight write to finish.
    while (_writeLock != null) {
      await _writeLock!.future;
    }
    _writeLock = Completer<void>();

    try {
      final json = await compute(_serializeCacheInIsolate, sanitized);
      final file = await _getCacheFile(userId);
      await file.writeAsString(json, flush: true);
    } finally {
      final lock = _writeLock;
      _writeLock = null;
      lock?.complete();
    }
  }

  static Map<String, dynamic>? _sanitizeRow(Map<String, dynamic> row) {
    final id = row['id'];
    final payload = row['payload'];
    final createdAtRaw = row['created_at'];
    if (id is! String || payload is! String) {
      return null;
    }
    String? createdAt;
    if (createdAtRaw is String) {
      createdAt = createdAtRaw;
    } else if (createdAtRaw is DateTime) {
      createdAt = createdAtRaw.toUtc().toIso8601String();
    }
    createdAt ??= DateTime.now().toUtc().toIso8601String();

    final isStarredRaw = row['is_starred'];
    bool isStarred;
    if (isStarredRaw is bool) {
      isStarred = isStarredRaw;
    } else if (isStarredRaw is num) {
      isStarred = isStarredRaw != 0;
    } else {
      isStarred = false;
    }

    return <String, dynamic>{
      'id': id,
      'payload': payload,
      'created_at': createdAt,
      'is_starred': isStarred,
      if (row['updated_at'] is String) 'updated_at': row['updated_at'],
      if (row['title'] is String) 'title': row['title'],
    };
  }

  static void _sortByCreatedAtDescending(List<Map<String, dynamic>> chats) {
    int compare(Map<String, dynamic> a, Map<String, dynamic> b) {
      DateTime? parse(dynamic value) {
        if (value is String) return DateTime.tryParse(value);
        if (value is DateTime) return value;
        return null;
      }

      final aDate =
          parse(a['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate =
          parse(b['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    }

    chats.sort(compare);
  }
}
