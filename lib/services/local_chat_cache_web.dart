// lib/services/local_chat_cache_web.dart
// Web fallback: JSON in SharedPreferences (web is always online, small cache).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocalChatCacheService {
  static const String _storageKeyPrefix = 'cached_chats_v2-';

  const LocalChatCacheService._();

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

  static Future<List<Map<String, dynamic>>> load(String userId) async {
    return _loadChats(userId);
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
