// lib/services/streaming_manager_stub.dart
// Web stub - uses same logic but without Platform checks for notification services
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/streaming_chat_service.dart';

/// Manages multiple concurrent chat streams across different chats
/// Web stub - no notification/foreground service integration
class StreamingManager {
  static final StreamingManager _instance = StreamingManager._internal();
  factory StreamingManager() => _instance;
  StreamingManager._internal();

  // Map of chatId -> ActiveStream
  final Map<String, _ActiveStream> _activeStreams = {};

  // Track if app is in background
  bool _isAppInBackground = false;

  /// Whether the app is currently in the background
  bool get isAppInBackground => _isAppInBackground;

  /// Check if a chat is currently streaming
  bool isStreaming(String chatId) {
    return _activeStreams.containsKey(chatId) &&
        _activeStreams[chatId]!.isActive;
  }

  /// Check if ANY chat is currently streaming
  bool get hasActiveStreams {
    return _activeStreams.values.any((stream) => stream.isActive);
  }

  /// Start a new stream for a chat
  Future<void> startStream({
    required String chatId,
    required int messageIndex,
    required Stream<ChatStreamEvent> stream,
    required Function(String content, String reasoning) onUpdate,
    required Function(String content, String reasoning, double? tps) onComplete,
    required Function(String error) onError,
    String? chatTitle,
  }) async {
    // Cancel existing stream for this chat if any
    await cancelStream(chatId);

    final streamSub = stream.listen(
      (event) {
        unawaited(
          _handleStreamEvent(
            chatId: chatId,
            event: event,
            onUpdate: onUpdate,
            onComplete: onComplete,
            onError: onError,
          ),
        );
      },
      onError: (error) {
        if (kDebugMode) {
          debugPrint('Stream subscription error for chat $chatId: $error');
        }
        // Preserve HTTP status code for 402 (Payment Required) so UI can show upgrade dialog
        if (error is StreamingChatException && error.statusCode == 402) {
          onError('__PAYMENT_REQUIRED__');
        } else {
          onError('Error: $error');
        }
        _cleanupStream(chatId);
      },
      onDone: () {
        unawaited(_handleStreamClose(chatId: chatId, onComplete: onComplete));
      },
      cancelOnError: false,
    );

    _activeStreams[chatId] = _ActiveStream(
      subscription: streamSub,
      messageIndex: messageIndex,
      chatId: chatId,
      chatTitle: chatTitle,
    );
  }

  /// Cancel stream for a specific chat
  Future<void> cancelStream(String chatId) async {
    final activeStream = _activeStreams[chatId];
    if (activeStream != null) {
      await activeStream.subscription.cancel();
      _activeStreams.remove(chatId);
      if (kDebugMode) {
        debugPrint('Cancelled stream for chat $chatId');
      }
    }
  }

  /// Cancel all active streams
  Future<void> cancelAllStreams() async {
    final chatIds = _activeStreams.keys.toList();
    for (final chatId in chatIds) {
      await cancelStream(chatId);
    }
    // No foreground service on web
  }

  void _cleanupStream(String chatId) {
    _activeStreams.remove(chatId);
    // No foreground service on web
  }

  /// Mark a stream as completed but keep its buffered content available.
  void _completeStream(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream != null) {
      stream.isActive = false;
      stream.completedAt = DateTime.now();
      unawaited(stream.subscription.cancel());
    }
    _evictStaleCompletedStreams();
  }

  /// Remove completed streams older than the TTL to prevent memory leaks.
  static const _completedStreamTtl = Duration(minutes: 5);
  static const _maxCompletedStreams = 5;

  void _evictStaleCompletedStreams() {
    final now = DateTime.now();
    final staleIds = <String>[];
    int completedCount = 0;

    for (final entry in _activeStreams.entries) {
      final stream = entry.value;
      if (!stream.isActive && stream.completedAt != null) {
        completedCount++;
        if (now.difference(stream.completedAt!) > _completedStreamTtl) {
          staleIds.add(entry.key);
        }
      }
    }

    for (final id in staleIds) {
      _activeStreams.remove(id);
      if (kDebugMode) {
        debugPrint('[StreamingManager] Evicted stale completed stream: $id');
      }
    }

    if (completedCount - staleIds.length > _maxCompletedStreams) {
      final completedEntries =
          _activeStreams.entries
              .where((e) => !e.value.isActive && e.value.completedAt != null)
              .toList()
            ..sort(
              (a, b) => a.value.completedAt!.compareTo(b.value.completedAt!),
            );

      final toRemove = completedEntries.length - _maxCompletedStreams;
      for (int i = 0; i < toRemove; i++) {
        _activeStreams.remove(completedEntries[i].key);
      }
    }
  }

  /// Handle stream events asynchronously
  Future<void> _handleStreamEvent({
    required String chatId,
    required ChatStreamEvent event,
    required Function(String content, String reasoning) onUpdate,
    required Function(String content, String reasoning, double? tps) onComplete,
    required Function(String error) onError,
  }) async {
    final activeStream = _activeStreams[chatId];
    if (activeStream == null || !activeStream.isActive) return;

    if (event is ContentEvent) {
      activeStream.contentBuffer.write(event.text);
      final content = activeStream.contentBuffer.toString();
      onUpdate(content, activeStream.reasoningBuffer.toString());
    } else if (event is ReasoningEvent) {
      activeStream.reasoningBuffer.write(event.text);
      onUpdate(
        activeStream.contentBuffer.toString(),
        activeStream.reasoningBuffer.toString(),
      );
    } else if (event is TpsEvent) {
      activeStream.tps = event.tokensPerSecond;
    } else if (event is ErrorEvent) {
      if (kDebugMode) {
        debugPrint('Stream ErrorEvent for chat $chatId: ${event.message}');
      }
      onError(event.message);
      _cleanupStream(chatId);
    } else if (event is DoneEvent) {
      if (kDebugMode) {
        debugPrint('Stream DoneEvent for chat $chatId');
      }
      final finalContent = activeStream.contentBuffer.toString();
      final finalReasoning = activeStream.reasoningBuffer.toString();
      final tps = activeStream.tps;

      // No notification on web
      onComplete(finalContent, finalReasoning, tps);
      _completeStream(chatId);
    }
  }

  /// Handle stream close asynchronously
  Future<void> _handleStreamClose({
    required String chatId,
    required Function(String content, String reasoning, double? tps) onComplete,
  }) async {
    final activeStream = _activeStreams[chatId];
    if (activeStream == null || !activeStream.isActive) return;

    if (kDebugMode) {
      debugPrint('Stream subscription closed for chat $chatId');
    }
    final finalContent = activeStream.contentBuffer.toString();
    final finalReasoning = activeStream.reasoningBuffer.toString();
    final tps = activeStream.tps;

    // No notification on web
    onComplete(finalContent, finalReasoning, tps);
    _completeStream(chatId);
  }

  /// Called when app lifecycle changes - no-op on web
  void onAppLifecycleChanged({required bool isInBackground}) {
    _isAppInBackground = isInBackground;
    // No foreground service on web
  }

  /// Get info about active streams (for debugging)
  Map<String, bool> getActiveStreamsInfo() {
    return Map.fromEntries(
      _activeStreams.entries.map((e) => MapEntry(e.key, e.value.isActive)),
    );
  }

  /// Get the current buffered content for a chat (active or completed).
  String? getBufferedContent(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null) return null;

    final content = stream.contentBuffer.toString();
    return content.isEmpty ? null : content;
  }

  /// Get the current buffered reasoning for a chat (active or completed).
  String? getBufferedReasoning(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null) return null;

    final reasoning = stream.reasoningBuffer.toString();
    return reasoning.isEmpty ? null : reasoning;
  }

  /// Get the message index being streamed for a chat (active or completed).
  int? getStreamingMessageIndex(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null) return null;
    return stream.messageIndex;
  }

  /// Get the TPS (tokens per second) for a streaming chat
  double? getTps(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.tps;
  }

  /// Check if a chat has a completed stream with buffered content.
  bool hasCompletedStream(String chatId) {
    final stream = _activeStreams[chatId];
    return stream != null && !stream.isActive;
  }

  /// Remove a completed stream entry after its content has been consumed.
  void consumeCompletedStream(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream != null && !stream.isActive) {
      _activeStreams.remove(chatId);
      if (kDebugMode) {
        debugPrint(
          '[StreamingManager] Consumed completed stream for chat $chatId',
        );
      }
    }
  }

  /// Store background messages for a streaming chat
  void setBackgroundMessages(
    String chatId,
    List<Map<String, dynamic>> messages, {
    String? modelId,
    String? provider,
  }) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return;

    stream.backgroundMessages = messages;
    stream.modelId = modelId;
    stream.provider = provider;
    if (kDebugMode) {
      debugPrint(
        '[StreamingManager] Stored ${messages.length} background messages for chat $chatId',
      );
    }
  }

  /// Get background messages with current buffer content applied
  List<Map<String, dynamic>>? getBackgroundMessages(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null ||
        !stream.isActive ||
        stream.backgroundMessages == null) {
      return null;
    }

    final messages = stream.backgroundMessages!
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (stream.messageIndex < messages.length) {
      messages[stream.messageIndex]['text'] = stream.contentBuffer.toString();
      messages[stream.messageIndex]['reasoning'] = stream.reasoningBuffer
          .toString();
    }
    return messages;
  }

  /// Check if a chat has background messages stored
  bool hasBackgroundMessages(String chatId) {
    final stream = _activeStreams[chatId];
    return stream != null &&
        stream.isActive &&
        stream.backgroundMessages != null;
  }
}

class _ActiveStream {
  final StreamSubscription<ChatStreamEvent> subscription;
  final int messageIndex;
  final String chatId;
  final String? chatTitle;
  final StringBuffer contentBuffer = StringBuffer();
  final StringBuffer reasoningBuffer = StringBuffer();
  bool isActive = true;

  double? tps;
  DateTime? completedAt;
  List<Map<String, dynamic>>? backgroundMessages;
  String? modelId;
  String? provider;

  _ActiveStream({
    required this.subscription,
    required this.messageIndex,
    required this.chatId,
    this.chatTitle,
  });
}
