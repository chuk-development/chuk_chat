// lib/services/chat_titles_prefs_cleanup.dart
//
// One-time removal of the sidebar title lists (`chat_titles_v1_<userId>`) from
// SharedPreferences.
//
// The title list moved into the SQLite kv_cache (see [chatTitlesCacheKey]),
// but the prefs copy was only migrated inside `_loadTitlesFromCache`, and only
// when the kv_cache held nothing for the signed-in user. Once the kv_cache had
// a value — written by a sync before the first load, or by an older build — a
// prefs copy stayed behind forever, as did the copy of every other account
// that ever signed in on the device. Each one is a ~200 KB string that Linux
// SharedPreferences rewrites synchronously, with the whole file, on every setX
// anywhere in the app.
//
// This sweeps every such key, for every account, in every build:
//  * kv_cache has nothing under the key → the prefs copy is written there
//    first, and the prefs key is removed only after that write succeeded;
//  * kv_cache already has a value → it is the live one (saveTitlesToCache only
//    writes there), the prefs copy is stale and is removed.
// The kv write is insert-if-absent, so a newer list a sync stores at the same
// moment is never overwritten by the old copy. A failed kv write leaves the
// prefs key in place for the next launch. With nothing left to move, a run is
// one in-memory scan of the prefs keys.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';

class ChatTitlesPrefsCleanup {
  ChatTitlesPrefsCleanup._();

  /// Prefix of the per-user title-list key, see `chatTitlesCacheKey`.
  static const String keyPrefix = 'chat_titles_v1_';

  /// Insert-if-absent into the kv_cache. Swappable in tests.
  @visibleForTesting
  static Future<bool> Function(String key, String value) putIfAbsent =
      LocalChatCacheService.kvSetIfAbsent;

  static Future<int>? _running;

  /// Move or drop every `chat_titles_v1_*` prefs key. Returns how many prefs
  /// keys were removed. Single-flight; never throws.
  static Future<int> run({SharedPreferences? prefs}) {
    final running = _running;
    if (running != null) return running;
    final future = _runOnce(prefs);
    _running = future;
    return future.whenComplete(() {
      if (identical(_running, future)) _running = null;
    });
  }

  static Future<int> _runOnce(SharedPreferences? given) async {
    var removed = 0;
    try {
      final prefs = given ?? await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(keyPrefix));
      for (final key in keys.toList()) {
        final value = prefs.get(key);
        final old = value is String ? value : null;
        if (old != null && old.isNotEmpty) {
          try {
            // Moves the copy when the kv_cache has none; otherwise the kv
            // value is the live list and the prefs copy is stale.
            await putIfAbsent(key, old);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('⚠️ [ChatTitles] kv write failed, prefs kept: $e');
            }
            continue;
          }
        }
        if (await prefs.remove(key)) removed++;
      }
      if (kDebugMode && removed > 0) {
        debugPrint('🧹 [ChatTitles] Dropped $removed title list(s) from prefs');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [ChatTitles] Prefs cleanup failed: $e');
    }
    return removed;
  }
}
