import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/encryption_service.dart';

/// Top-level function for background JSON parsing of cache data
/// Must be top-level to work with compute()
List<Map<String, dynamic>> _parseAndSanitizeCacheInIsolate(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    return const <Map<String, dynamic>>[];
  }
  // Version check - hardcoded since we can't access class constants in isolate
  final version = decoded['version'];
  if (version is! int || version != 2) {
    return const <Map<String, dynamic>>[];
  }
  final chatsRaw = decoded['chats'];
  if (chatsRaw is! List) {
    return const <Map<String, dynamic>>[];
  }
  final List<Map<String, dynamic>> chats = [];
  for (final entry in chatsRaw) {
    if (entry is Map<String, dynamic>) {
      // Inline sanitization
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
  // Sort by created_at descending
  chats.sort((a, b) {
    final aDate = a['created_at'] as String;
    final bDate = b['created_at'] as String;
    return bDate.compareTo(aDate);
  });
  return chats;
}

class LocalChatCacheService {
  static const int _cacheVersion = 2;
  static const String _storageKeyPrefix =
      'cached_chats_v$_cacheVersion-';

  /// Old v1 encrypted cache key prefix (for migration)
  static const String _oldStorageKeyPrefix =
      'cached_encrypted_chats_v1-';

  const LocalChatCacheService._();

  /// Build a plaintext cache row from pre-encryption data.
  /// Use this instead of passing Supabase rows (which contain encrypted fields).
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

  static Future<void> replaceAll(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final sanitized = rows
        .map(_sanitizeRow)
        .where((row) => row != null)
        .cast<Map<String, dynamic>>()
        .toList(growable: false);
    _sortByCreatedAtDescending(sanitized);
    await _persist(prefs, _storageKey(userId), sanitized);
  }

  static Future<void> upsert(String userId, Map<String, dynamic> row) async {
    final sanitized = _sanitizeRow(row);
    if (sanitized == null) return;

    final prefs = await SharedPreferences.getInstance();
    final key = _storageKey(userId);
    final payload = await _loadPayload(prefs, key);
    final List<Map<String, dynamic>> chats = payload['chats'];

    final existingIndex = chats.indexWhere(
      (entry) => entry['id'] == sanitized['id'],
    );
    if (existingIndex != -1) {
      chats[existingIndex] = sanitized;
    } else {
      chats.add(sanitized);
    }
    _sortByCreatedAtDescending(chats);
    await _persist(prefs, key, chats);
  }

  static Future<void> delete(String userId, String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _storageKey(userId);
    final payload = await _loadPayload(prefs, key);
    final chats = payload['chats'];
    final originalLength = chats.length;
    chats.removeWhere((entry) => entry['id'] == chatId);
    if (chats.length == originalLength) return;
    await _persist(prefs, key, chats);
  }

  static Future<void> updateStarred(
    String userId,
    String chatId,
    bool isStarred,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _storageKey(userId);
    final payload = await _loadPayload(prefs, key);
    final chats = payload['chats'];
    final index = chats.indexWhere((entry) => entry['id'] == chatId);
    if (index == -1) return;
    chats[index] = Map<String, dynamic>.from(chats[index])
      ..['is_starred'] = isStarred;
    await _persist(prefs, key, chats);
  }

  static Future<List<Map<String, dynamic>>> load(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _storageKey(userId);
    final raw = prefs.getString(key);
    if (raw == null) return const <Map<String, dynamic>>[];
    try {
      // Parse and sanitize in background isolate to avoid UI blocking
      return await compute(_parseAndSanitizeCacheInIsolate, raw);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  static Future<void> clear(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey(userId));
  }

  /// Migrate from old encrypted v1 cache to plaintext v2 cache.
  /// Returns true if migration was performed, false if no old cache found.
  /// On decrypt failure, logs warning and returns false (Supabase sync will repopulate).
  static Future<bool> migrateFromEncrypted(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final oldKey = '$_oldStorageKeyPrefix$userId';
    final raw = prefs.getString(oldKey);
    if (raw == null) return false;

    if (kDebugMode) {
      debugPrint(
        '🔄 [CacheService] Migrating from encrypted v1 cache...',
      );
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

      // Collect encrypted payloads and titles for batch decryption
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

      // Batch decrypt payloads
      final decryptedPayloads =
          await EncryptionService.decryptBatchInBackground(encryptedPayloads);

      // Batch decrypt titles (filter non-null)
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

      // Build plaintext rows
      final plaintextRows = <Map<String, dynamic>>[];
      // Map title indices back
      final titleMap = <int, String?>{};
      for (int j = 0; j < titleIndices.length; j++) {
        titleMap[titleIndices[j]] = decryptedTitles[j];
      }

      for (int i = 0; i < validEntries.length; i++) {
        final decrypted = decryptedPayloads[i];
        if (decrypted == null) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [CacheService] Migration: failed to decrypt entry ${validEntries[i]['id']} (index $i)',
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

      // Write new v2 cache
      await replaceAll(userId, plaintextRows);

      // Delete old v1 cache
      await prefs.remove(oldKey);

      if (kDebugMode) {
        debugPrint(
          '✅ [CacheService] Migrated ${plaintextRows.length} chats from encrypted to plaintext cache',
        );
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [CacheService] Migration failed (Supabase sync will repopulate): $e',
        );
      }
      // Clean up old cache to avoid repeated failed attempts
      await prefs.remove(oldKey);
      return false;
    }
  }

  /// Check if old encrypted v1 cache exists for this user
  static Future<bool> hasOldEncryptedCache(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final oldKey = '$_oldStorageKeyPrefix$userId';
    return prefs.containsKey(oldKey);
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

  static Future<void> _persist(
    SharedPreferences prefs,
    String key,
    List<Map<String, dynamic>> sanitized,
  ) async {
    await prefs.setString(
      key,
      jsonEncode(<String, dynamic>{
        'version': _cacheVersion,
        'chats': sanitized,
      }),
    );
  }

  static Future<Map<String, dynamic>> _loadPayload(
    SharedPreferences prefs,
    String key,
  ) async {
    final raw = prefs.getString(key);
    if (raw == null) {
      return <String, dynamic>{
        'version': _cacheVersion,
        'chats': <Map<String, dynamic>>[],
      };
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final version = decoded['version'];
        final chats = decoded['chats'];
        if (version == _cacheVersion && chats is List) {
          return <String, dynamic>{
            'version': _cacheVersion,
            'chats': chats
                .whereType<Map<String, dynamic>>()
                .map((entry) => _sanitizeRow(entry))
                .whereType<Map<String, dynamic>>()
                .toList(growable: true),
          };
        }
      }
    } catch (_) {
      // Ignore malformed cache and fall back to empty.
    }
    return <String, dynamic>{
      'version': _cacheVersion,
      'chats': <Map<String, dynamic>>[],
    };
  }

  static void _sortByCreatedAtDescending(List<Map<String, dynamic>> chats) {
    int compare(Map<String, dynamic> a, Map<String, dynamic> b) {
      DateTime? parse(dynamic value) {
        if (value is String) {
          return DateTime.tryParse(value);
        }
        if (value is DateTime) {
          return value;
        }
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

  static String _storageKey(String userId) => '$_storageKeyPrefix$userId';
}
