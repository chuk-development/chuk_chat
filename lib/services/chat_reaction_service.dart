import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cowork/services/supabase_service.dart';

/// Personal, device-local reactions. They are never sent as model feedback.
class ChatReactionService extends ChangeNotifier {
  static final instance = ChatReactionService();
  final Map<String, Map<String, String>> _cache = {};
  final Map<String, Future<void>> _writes = {};

  @visibleForTesting
  void clearMemoryForTesting() => _cache.clear();

  static String messageKey(Map<String, String> message) {
    final id = message['messageId'];
    if (id != null && id.isNotEmpty) return 'id:$id';
    // Legacy messages have no persisted UUID. Do not use _uiKey, which changes
    // on every history replay. Hash instead of storing message text in prefs.
    return 'legacy:${sha256.convert(utf8.encode(jsonEncode([message['sender'] ?? message['role'], message['sentAt'], message['startedAt'], message['text'], message['images'], message['attachments']])))}';
  }

  String _key(String chatId, String? userId) {
    String account = userId ?? 'local';
    if (userId == null) {
      try {
        account = SupabaseService.auth.currentUser?.id ?? 'local';
      } catch (_) {}
    }
    return 'cowork.reactions.v1.${Uri.encodeComponent(account)}.${Uri.encodeComponent(chatId)}';
  }

  String? peek(String chatId, String messageId, {String? userId}) =>
      _cache[_key(chatId, userId)]?[messageId];

  Future<void> load(String chatId, {String? userId}) =>
      _loadKey(_key(chatId, userId));

  Future<void> _loadKey(String key) async {
    if (_cache.containsKey(key)) return;
    final prefs = await SharedPreferences.getInstance();
    if (_cache.containsKey(key)) return;
    final result = <String, String>{};
    try {
      final decoded = jsonDecode(prefs.getString(key) ?? '{}');
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String && entry.value is String) {
            result[entry.key as String] = entry.value as String;
          }
        }
      }
    } on FormatException {
      /* Optional corrupt reactions must not break chat. */
    }
    _cache[key] = result;
    notifyListeners();
  }

  Future<void> toggle(
    String chatId,
    String messageId,
    String emoji, {
    String? userId,
  }) async {
    if (chatId.isEmpty || messageId.isEmpty || emoji.isEmpty) return;
    final key = _key(chatId, userId);
    final operation = (_writes[key] ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
          await _loadKey(key);
          final next = Map<String, String>.of(_cache[key]!);
          if (next[messageId] == emoji) {
            next.remove(messageId);
          } else {
            next[messageId] = emoji;
          }
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString(key, jsonEncode(next))) {
            throw StateError('Could not save reaction');
          }
          _cache[key] = next;
          notifyListeners();
        });
    _writes[key] = operation;
    await operation;
  }
}
