import 'package:flutter/foundation.dart';
import 'package:chuk_chat/services/chat_runtime.dart';

/// Singleton registry of per-chat [ChatRuntime]s.
///
/// The registry is the new source of truth for in-flight chat state.
/// Widget state (`_messages`, `_isSending`, `_isStreaming`) becomes a
/// view over the runtime for the visible chat; runtimes for non-visible
/// chats keep streaming in the background.
///
/// Eviction policy: idle (no send, no stream) runtimes beyond
/// [maxIdleRuntimes] are dropped in LRU order on every [get] call.
/// Streaming runtimes are never evicted — Android keeps them alive via
/// the foreground service and the in-app cache flush handles persistence.
class ChatRuntimeRegistry {
  ChatRuntimeRegistry._internal();

  static final ChatRuntimeRegistry instance = ChatRuntimeRegistry._internal();

  /// Test-only seam — construct a fresh registry. Production code should
  /// always go through [instance].
  @visibleForTesting
  factory ChatRuntimeRegistry.test() = ChatRuntimeRegistry._internal;

  /// Maximum number of idle (non-streaming, non-sending) runtimes to
  /// retain. Older idle runtimes are evicted on demand.
  static const int maxIdleRuntimes = 8;

  final Map<String, ChatRuntime> _runtimes = <String, ChatRuntime>{};

  /// Return the runtime for [chatId], creating it lazily with [initial]
  /// messages if it does not yet exist.
  ChatRuntime get(String chatId, {List<Map<String, String>>? initial}) {
    final existing = _runtimes[chatId];
    if (existing != null) {
      existing.touch();
      return existing;
    }
    final runtime = ChatRuntime(chatId: chatId, initial: initial);
    _runtimes[chatId] = runtime;
    _evictIdleIfNeeded();
    return runtime;
  }

  /// Return the runtime for [chatId] if it exists, without creating one.
  ChatRuntime? lookup(String chatId) {
    final runtime = _runtimes[chatId];
    runtime?.touch();
    return runtime;
  }

  /// Whether any runtime currently has an active or sending stream.
  bool get isAnyStreaming =>
      _runtimes.values.any((r) => r.isStreaming.value || r.isSending.value);

  /// IDs of chats that currently have an in-flight stream.
  Iterable<String> get streamingChatIds => _runtimes.entries
      .where((e) => e.value.isStreaming.value || e.value.isSending.value)
      .map((e) => e.key);

  /// Force-release a runtime. No-op if a stream is still in flight.
  /// Returns true if the runtime was released.
  bool release(String chatId) {
    final runtime = _runtimes[chatId];
    if (runtime == null) return false;
    if (!runtime.isIdle) return false;
    _runtimes.remove(chatId);
    runtime.dispose();
    return true;
  }

  /// Drop every runtime. Intended for sign-out flows.
  void clear() {
    for (final runtime in _runtimes.values) {
      runtime.dispose();
    }
    _runtimes.clear();
  }

  /// Evict idle runtimes in LRU order while we are above the cap.
  void _evictIdleIfNeeded() {
    final idle = _runtimes.values.where((r) => r.isIdle).toList()
      ..sort((a, b) => a.lastTouchedAt.compareTo(b.lastTouchedAt));
    int toEvict = idle.length - maxIdleRuntimes;
    if (toEvict <= 0) return;
    for (final runtime in idle) {
      if (toEvict <= 0) break;
      _runtimes.remove(runtime.chatId);
      runtime.dispose();
      toEvict--;
    }
  }

}
