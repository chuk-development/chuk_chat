// lib/services/chat_dirty_store.dart
//
// The chats whose local copy is ahead of `encrypted_chats`.
//
// A turn saves its chat many times: once per tool round, once per stream
// checkpoint. Each cloud save re-encrypts and rewrites the whole payload, and
// those rewrites drained the Supabase Disk IO budget. So a save during a turn
// goes only to memory and the SQLite cache, and the chat is marked dirty
// here. The cloud gets the chat once, when the turn is over. A chat that is
// still dirty after that (a failed write, a killed app) is written by
// [flush]: at app start after sign-in, when the app goes to the background,
// and when the network comes back.
//
// The set is persisted in the SQLite `kv_cache` (ids only, no payload), per
// user, so it survives a crash or a kill. The payload itself is the SQLite
// chat row.

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:flutter/foundation.dart';

class ChatDirtyStore {
  ChatDirtyStore._();

  /// Dirty chat id -> true while `encrypted_chats` has no row for it yet
  /// (the chat was made on this device and never inserted).
  static final Map<String, bool> _dirty = <String, bool>{};

  /// Local revision per chat. Every local save increments it. A cloud write
  /// clears the dirty mark only when no newer local save came after the
  /// messages it wrote.
  static final Map<String, int> _revisions = <String, int>{};

  static String? _owner;
  static bool _loaded = false;
  static Future<void>? _loading;
  static Future<void>? _flushing;

  /// Persistence of the id set. Test seams: a test swaps them for a map.
  @visibleForTesting
  static Future<String?> Function(String key) readKv =
      LocalChatCacheService.kvGet;
  @visibleForTesting
  static Future<void> Function(String key, String value) writeKv =
      LocalChatCacheService.kvSet;

  static String _key(String userId) => 'chat_dirty_v1_$userId';

  /// Ids of every dirty chat.
  static Set<String> get ids => Set<String>.of(_dirty.keys);

  /// Whether the local copy of [chatId] is ahead of the cloud.
  static bool isDirty(String chatId) => _dirty.containsKey(chatId);

  /// Whether [chatId] was never inserted into `encrypted_chats`.
  static bool isPendingInsert(String chatId) => _dirty[chatId] == true;

  /// The local revision of [chatId]; 0 before its first local save.
  static int revision(String chatId) => _revisions[chatId] ?? 0;

  /// Read the persisted set of [userId] once. Marks of another account are
  /// dropped from memory; their own key keeps them on disk. A failed read is
  /// tried again by the next call, and until one succeeds the set is not
  /// written back, so a partial set never replaces the one on disk.
  static Future<void> load(String userId) {
    if (_owner != userId) {
      _owner = userId;
      _loaded = false;
      _loading = null;
      _dirty.clear();
    }
    if (_loaded) return Future<void>.value();
    return _loading ??= () async {
      try {
        final raw = await readKv(_key(userId));
        // A sign-out while this read ran: the set is not this user's any more.
        if (_owner != userId) return;
        final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((id, pendingInsert) {
            if (id is String) {
              _dirty[id] = (_dirty[id] ?? false) || pendingInsert == true;
            }
          });
        }
        _loaded = true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ [ChatDirty] Could not read the dirty set: $e');
        }
      } finally {
        if (_owner == userId) _loading = null;
      }
    }();
  }

  /// Record a local save of [chatId] and return its new revision.
  /// [pendingInsert] is kept once set, until a cloud insert succeeds.
  static Future<int> markDirty(
    String userId,
    String chatId, {
    required bool pendingInsert,
  }) async {
    // Counted before any await: a cloud write that starts right after this
    // call must already see the new revision.
    final rev = revision(chatId) + 1;
    _revisions[chatId] = rev;
    await load(userId);
    final before = _dirty[chatId];
    final after = (before ?? false) || pendingInsert;
    if (before != after) {
      _dirty[chatId] = after;
      await _persist(userId);
    }
    return rev;
  }

  /// A cloud write of [chatId] succeeded with the messages of local
  /// revision [rev]. The row exists now. When no newer local save came
  /// after [rev], the cloud is current and the dirty mark is cleared.
  static Future<void> markSynced(String userId, String chatId, int rev) async {
    await load(userId);
    if (!_dirty.containsKey(chatId)) return;
    if (revision(chatId) == rev) {
      _dirty.remove(chatId);
    } else if (_dirty[chatId] == true) {
      _dirty[chatId] = false;
    } else {
      return;
    }
    await _persist(userId);
  }

  /// Forget [chatId] entirely: it was deleted.
  static Future<void> forget(String userId, String chatId) async {
    await load(userId);
    _revisions.remove(chatId);
    if (_dirty.remove(chatId) != null) await _persist(userId);
  }

  /// Write every dirty chat through [push], once. [push] writes the local
  /// copy of one chat to the cloud and throws when it cannot. A chat whose
  /// push fails stays dirty for the next flush. After a network error the
  /// rest wait too: each of them would only run into the same timeout.
  /// Concurrent calls share one run.
  static Future<void> flush(
    String userId,
    Future<void> Function(String chatId) push,
  ) {
    return _flushing ??= () async {
      try {
        await load(userId);
        for (final chatId in ids) {
          if (!isDirty(chatId)) continue;
          final rev = revision(chatId);
          try {
            await push(chatId);
            await markSynced(userId, chatId, rev);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('⚠️ [ChatDirty] Flush of $chatId failed: $e');
            }
            if (NetworkStatusService.isNetworkError(e)) break;
          }
        }
      } finally {
        _flushing = null;
      }
    }();
  }

  static Future<void> _persist(String userId) async {
    if (!_loaded || _owner != userId) return;
    try {
      await writeKv(_key(userId), jsonEncode(_dirty));
    } catch (e) {
      // The mark stays in memory; the next change writes the whole set again.
      if (kDebugMode) {
        debugPrint('⚠️ [ChatDirty] Could not write the dirty set: $e');
      }
    }
  }

  /// Drop the in-memory state (sign-out). The persisted set stays, so the
  /// account's dirty chats are flushed when it signs in again.
  static void reset() {
    _dirty.clear();
    _revisions.clear();
    _owner = null;
    _loaded = false;
    _loading = null;
  }
}
