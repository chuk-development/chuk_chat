// lib/services/local_chat_cache_web.dart
// Web fallback: JSON in SharedPreferences (web is always online, small cache).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_cache_search_text.dart';

class LocalChatCacheService {
  static const String _storageKeyPrefix = 'cached_chats_v2-';

  const LocalChatCacheService._();

  /// No-op on web: the cache lives in SharedPreferences and holds no
  /// handle. Exists so both implementations expose the same API.
  static Future<void> debugReset() async {}

  // ─── Generic KV cache ──────────────────────────────────────────────

  static Future<String?> kvGet(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('kv_$key');
  }

  static Future<void> kvSet(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kv_$key', value);
  }

  static Future<void> kvDelete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('kv_$key');
  }

  // ─── Public helpers ───────────────────────────────────────────────

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

  static Future<void> replaceAll(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final sanitized = rows
        .map(_sanitizeRow)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    await _persist(userId, sanitized);
  }

  static Future<void> upsert(String userId, Map<String, dynamic> row) async {
    final sanitized = _sanitizeRow(row);
    if (sanitized == null) return;

    final chats = await _loadChats(userId);
    final idx = chats.indexWhere((e) => e['id'] == sanitized['id']);
    if (idx != -1) {
      chats[idx] = sanitized;
    } else {
      chats.add(sanitized);
    }
    await _persist(userId, chats);
  }

  static Future<void> delete(String userId, String chatId) async {
    final chats = await _loadChats(userId);
    final before = chats.length;
    chats.removeWhere((e) => e['id'] == chatId);
    if (chats.length == before) return;
    await _persist(userId, chats);
  }

  static Future<void> updateStarred(
    String userId,
    String chatId,
    bool isStarred,
  ) async {
    final chats = await _loadChats(userId);
    final idx = chats.indexWhere((e) => e['id'] == chatId);
    if (idx == -1) return;
    chats[idx] = Map<String, dynamic>.from(chats[idx])
      ..['is_starred'] = isStarred;
    await _persist(userId, chats);
  }

  /// Load cached chats without their payloads.
  ///
  /// Web keeps the cache in SharedPreferences and must decode the whole
  /// blob anyway, so this only strips the payload from the result. It
  /// exists to match the native API, where dropping the column is what
  /// keeps startup off the platform-channel size limit.
  static Future<List<Map<String, dynamic>>> loadMeta(String userId) async {
    final chats = await _loadChats(userId);
    return chats.map((chat) {
      final meta = Map<String, dynamic>.from(chat);
      meta.remove('payload');
      return meta;
    }).toList(growable: false);
  }

  /// Count cached chats for one user.
  static Future<int> count(String userId) async {
    final chats = await _loadChats(userId);
    return chats.length;
  }

  /// Load one cached chat row by chat ID.
  static Future<Map<String, dynamic>?> loadById(
    String userId,
    String chatId,
  ) async {
    final chats = await _loadChats(userId);
    for (final chat in chats) {
      if (chat['id'] == chatId) {
        return chat;
      }
    }
    return null;
  }

  /// Case-insensitive search over chat title and message text.
  ///
  /// Matches the same field set as the native cache — see
  /// [buildChatSearchText]. Both back one public API, so a query has to
  /// return the same chats on web as it does on the desktop and mobile
  /// builds.
  static Future<List<Map<String, dynamic>>> search(
    String userId,
    String query, {
    int limit = 100,
  }) async {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return const <Map<String, dynamic>>[];

    final chats = await _loadChats(userId);
    final filtered = chats
        .where((chat) {
          final title = (chat['title'] as String? ?? '').toLowerCase();
          if (title.contains(trimmed)) return true;
          final payload = chat['payload'] as String?;
          if (payload == null) return false;
          final searchText = buildChatSearchText(payload);
          return searchText != null && searchText.contains(trimmed);
        })
        .toList(growable: false);

    filtered.sort((a, b) {
      final aUpdated =
          (a['updated_at'] as String?) ?? (a['created_at'] as String? ?? '');
      final bUpdated =
          (b['updated_at'] as String?) ?? (b['created_at'] as String? ?? '');
      return bUpdated.compareTo(aUpdated);
    });

    final cappedLimit = limit.clamp(1, 500).toInt();
    return filtered.take(cappedLimit).toList(growable: false);
  }

  /// No-op on web (no migration needed).
  static Future<void> ensureMigrated(String userId) async {}

  static Future<void> clear(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_storageKeyPrefix$userId');
  }

  /// No encrypted cache on web.
  static Future<bool> hasOldEncryptedCache(String userId) async => false;

  /// No-op on web.
  static Future<bool> migrateFromEncrypted(String userId) async => false;

  // ─── Private ──────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _loadChats(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_storageKeyPrefix$userId');
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <Map<String, dynamic>>[];
      final chats = decoded['chats'];
      if (chats is! List) return <Map<String, dynamic>>[];
      return chats
          .whereType<Map<String, dynamic>>()
          .map(_sanitizeRow)
          .whereType<Map<String, dynamic>>()
          .toList(growable: true);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _persist(
    String userId,
    List<Map<String, dynamic>> chats,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_storageKeyPrefix$userId',
      jsonEncode(<String, dynamic>{'version': 2, 'chats': chats}),
    );
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
}
