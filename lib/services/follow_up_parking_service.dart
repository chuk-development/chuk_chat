// lib/services/follow_up_parking_service.dart
//
// Follow-up messages the user typed while a reply was still streaming. The
// chat screen keeps them in memory and sends them when the turn ends. If the
// app is killed in between (or the user switches to another thread), they
// used to be lost. They are parked here, per chat, sealed with the chat key
// ([OutboxCipher]), in the SQLite `kv_cache` table, and restored the next
// time the chat is open (docs/OFFLINE_SEND.md).
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';

abstract final class FollowUpParkingService {
  static const String prefix = 'outbox.followups.';

  // Test seams for the key-value store.
  @visibleForTesting
  static Future<String?> Function(String key) read = LocalChatCacheService.kvGet;
  @visibleForTesting
  static Future<void> Function(String key, String value) write =
      LocalChatCacheService.kvSet;
  @visibleForTesting
  static Future<void> Function(String key) delete =
      LocalChatCacheService.kvDelete;
  @visibleForTesting
  static Future<List<String>> Function(String prefix) keys =
      LocalChatCacheService.kvKeys;

  @visibleForTesting
  static void resetSeams() {
    read = LocalChatCacheService.kvGet;
    write = LocalChatCacheService.kvSet;
    delete = LocalChatCacheService.kvDelete;
    keys = LocalChatCacheService.kvKeys;
  }

  static String _key(String chatId) {
    final user = OutboxCipher.currentUserId() ?? 'anon';
    return '$prefix$user.$chatId';
  }

  /// Replaces the parked list of [chatId]. An empty list deletes it.
  static Future<void> save(String chatId, List<String> texts) async {
    try {
      final key = _key(chatId);
      if (texts.isEmpty) {
        await delete(key);
        return;
      }
      final plain = jsonEncode(texts);
      final sealed = await OutboxCipher.seal(plain);
      await write(
        key,
        jsonEncode(
          sealed == null
              ? <String, Object>{'plain': texts}
              : <String, Object>{'sealed': sealed},
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[FollowUpParking] save failed: $e');
    }
  }

  /// The parked list of [chatId], oldest first. Empty when nothing is parked
  /// or the value cannot be opened (it is kept for a later try).
  static Future<List<String>> load(String chatId) async {
    try {
      final raw = await read(_key(chatId));
      if (raw == null || raw.isEmpty) return const <String>[];
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String>[];
      Object? list = decoded['plain'];
      final sealed = decoded['sealed'];
      if (sealed is String) {
        list = jsonDecode(await OutboxCipher.open(sealed));
      }
      if (list is List) return list.whereType<String>().toList();
    } catch (e) {
      if (kDebugMode) debugPrint('[FollowUpParking] load failed: $e');
    }
    return const <String>[];
  }

  /// The chats of the signed-in user that have parked follow-ups.
  static Future<List<String>> parkedChats() async {
    final user = OutboxCipher.currentUserId();
    if (user == null) return const <String>[];
    final head = '$prefix$user.';
    try {
      return <String>[
        for (final k in await keys(head))
          if (k.length > head.length) k.substring(head.length),
      ];
    } catch (_) {
      return const <String>[];
    }
  }

  /// Sign-out: deletes every parked list of [userId].
  static Future<void> wipeUser(String userId) async {
    try {
      for (final k in await keys('$prefix$userId.')) {
        await delete(k);
      }
    } catch (_) {}
  }
}
