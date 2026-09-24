// lib/services/local_chat_cache_web.dart
// Web fallback: JSON in SharedPreferences (web is always online, small cache).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_cache_search_text.dart';
import 'package:chuk_chat/services/local_chat_cache_rows.dart';

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

  static Future<bool> kvSetIfAbsent(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('kv_$key')) return false;
    await prefs.setString('kv_$key', value);
    return true;
  }

  static Future<void> kvDelete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('kv_$key');
  }

  // ─── Skills store ──────────────────────────────────────────────────
  // Mirrors the native SQLite `skills` table over a per-user JSON blob. Rows
  // carry id, user_id, source, catalog_name, baseline_hash, updated_at.

  static const String _skillsKeyPrefix = 'skills_';

  static Future<List<Map<String, dynamic>>> skillRows(String userId) async {
    final rows = await _loadSkills(userId);
    rows.sort((a, b) {
      final au = a['updated_at'] as String? ?? '';
      final bu = b['updated_at'] as String? ?? '';
      return bu.compareTo(au);
    });
    return rows;
  }

  static Future<void> upsertSkill(Map<String, dynamic> row) async {
    final userId = row['user_id'] as String?;
    final id = row['id'] as String?;
    if (userId == null || id == null) return;
    final rows = await _loadSkills(userId);
    final idx = rows.indexWhere((e) => e['id'] == id);
    if (idx != -1) {
      rows[idx] = Map<String, dynamic>.from(row);
    } else {
      rows.add(Map<String, dynamic>.from(row));
    }
    await _persistSkills(userId, rows);
  }

  static Future<void> deleteSkill(String userId, String id) async {
    final rows = await _loadSkills(userId);
    final before = rows.length;
    rows.removeWhere((e) => e['id'] == id);
    if (rows.length == before) return;
    await _persistSkills(userId, rows);
  }

  static Future<void> replaceSkills(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    await _persistSkills(
      userId,
      rows.map((r) => Map<String, dynamic>.from(r)).toList(growable: false),
    );
  }

  static Future<List<Map<String, dynamic>>> _loadSkills(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_skillsKeyPrefix$userId');
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(Map<String, dynamic>.from)
          .toList(growable: true);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _persistSkills(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_skillsKeyPrefix$userId', jsonEncode(rows));
  }

  // ─── Public helpers ───────────────────────────────────────────────

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
    return chats
        .map((chat) {
          final meta = Map<String, dynamic>.from(chat);
          meta.remove('payload');
          return meta;
        })
        .toList(growable: false);
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

  /// Native only (the background upgrade of old rows to v3). The web cache
  /// keeps its rows as JSON text and is rebuilt from the cloud.
  static Future<({Map<String, dynamic> row, int storedLength, bool framed})?>
  loadRawById(String userId, String chatId) async => null;

  /// Native only (the maintenance screen's local part). The web cache is
  /// JSON text rebuilt from the cloud; there is nothing to upgrade.
  static Future<List<String>> idsNeedingPayloadUpgrade(String userId) async =>
      const <String>[];

  /// Native only; the web has no database file to back up.
  static Future<String> backupDatabase() async =>
      throw UnsupportedError('No cache database on the web');

  /// Native only, see [backupDatabase].
  static Future<void> restoreBackup() async =>
      throw UnsupportedError('No cache database on the web');

  /// Native only, see [backupDatabase].
  static Future<void> deleteBackup() async {}

  /// Native only, see [backupDatabase].
  static Future<bool> hasBackup() async => false;

  /// Native only, see [idsNeedingPayloadUpgrade].
  static Future<bool> updateUpdatedAtIfEqual(
    String userId,
    String chatId, {
    required String expected,
    required String value,
  }) async => false;

  /// Native only, see [loadRawById].
  static Future<bool> replacePayloadIfUnchanged(
    String userId,
    String chatId, {
    required String payload,
    required String? expectedUpdatedAt,
    required int expectedStoredLength,
  }) async => false;

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

  static Map<String, dynamic>? _sanitizeRow(Map<String, dynamic> row) =>
      sanitizeCacheRow(row);
}
