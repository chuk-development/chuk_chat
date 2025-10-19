import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocalChatCacheService {
  static const int _cacheVersion = 1;
  static const String _storageKeyPrefix =
      'cached_encrypted_chats_v$_cacheVersion-';

  const LocalChatCacheService._();

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
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const <Map<String, dynamic>>[];
      }
      final version = decoded['version'];
      if (version is! int || version != _cacheVersion) {
        return const <Map<String, dynamic>>[];
      }
      final chatsRaw = decoded['chats'];
      if (chatsRaw is! List) {
        return const <Map<String, dynamic>>[];
      }
      final List<Map<String, dynamic>> chats = [];
      for (final entry in chatsRaw) {
        if (entry is Map<String, dynamic>) {
          final sanitized = _sanitizeRow(entry);
          if (sanitized != null) {
            chats.add(sanitized);
          }
        }
      }
      _sortByCreatedAtDescending(chats);
      return chats;
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  static Future<void> clear(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey(userId));
  }

  static Map<String, dynamic>? _sanitizeRow(Map<String, dynamic> row) {
    final id = row['id'];
    final encryptedPayload = row['encrypted_payload'];
    final createdAtRaw = row['created_at'];
    if (id is! String || encryptedPayload is! String) {
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
      'encrypted_payload': encryptedPayload,
      'created_at': createdAt,
      'is_starred': isStarred,
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
