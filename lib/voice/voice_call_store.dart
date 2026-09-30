// lib/voice/voice_call_store.dart
//
// Local persistence of call records, per chat. Lives in the SQLite
// `kv_cache` table of chat_cache.db (docs: CLAUDE.md "Local Cache
// Architecture"), one key per chat holding a JSON list, so a record
// survives a restart. Never SharedPreferences: a transcript is not a small
// setting.
//
// Web: no-op. The feature is native-only (VoiceCallService.isAvailable).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

abstract final class VoiceCallStore {
  static const String _keyPrefix = 'voice_calls:';

  /// The newest records kept per chat; older ones fall off.
  static const int maxRecordsPerChat = 200;

  /// Serialises read-modify-write so two saves never drop each other.
  static Future<void> _tail = Future<void>.value();

  static String _key(String chatId) => '$_keyPrefix$chatId';

  /// Appends [r] to its chat. A record with the same start time replaces the
  /// older copy, so saving twice is harmless.
  static Future<void> save(VoiceCallRecord r) {
    if (kIsWeb || r.chatId.isEmpty) return Future<void>.value();
    return _serial(() async {
      final List<VoiceCallRecord> records = await _read(r.chatId);
      records.removeWhere(
        (VoiceCallRecord e) => e.startedAt.isAtSameMomentAs(r.startedAt),
      );
      records.add(r);
      records.sort(
        (VoiceCallRecord a, VoiceCallRecord b) =>
            a.startedAt.compareTo(b.startedAt),
      );
      final List<VoiceCallRecord> kept = records.length > maxRecordsPerChat
          ? records.sublist(records.length - maxRecordsPerChat)
          : records;
      await LocalChatCacheService.kvSet(
        _key(r.chatId),
        jsonEncode(<Map<String, dynamic>>[
          for (final VoiceCallRecord e in kept) e.toJson(),
        ]),
      );
    });
  }

  /// Every stored record of [chatId], oldest first.
  static Future<List<VoiceCallRecord>> forChat(String chatId) async {
    if (kIsWeb || chatId.isEmpty) return <VoiceCallRecord>[];
    await _tail;
    return _read(chatId);
  }

  /// Drops every record of [chatId] (call it when the chat is deleted).
  static Future<void> deleteForChat(String chatId) {
    if (kIsWeb || chatId.isEmpty) return Future<void>.value();
    return _serial(() => LocalChatCacheService.kvDelete(_key(chatId)));
  }

  static Future<List<VoiceCallRecord>> _read(String chatId) async {
    final String? raw = await LocalChatCacheService.kvGet(_key(chatId));
    if (raw == null || raw.isEmpty) return <VoiceCallRecord>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <VoiceCallRecord>[];
      return <VoiceCallRecord>[
        for (final Object? item in decoded)
          if (item is Map)
            VoiceCallRecord.fromJson(item.cast<String, dynamic>()),
      ]..sort(
        (VoiceCallRecord a, VoiceCallRecord b) =>
            a.startedAt.compareTo(b.startedAt),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[VoiceCallStore] unreadable record list: ${e.runtimeType}');
      }
      return <VoiceCallRecord>[];
    }
  }

  static Future<T> _serial<T>(Future<T> Function() op) {
    final Future<T> result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
