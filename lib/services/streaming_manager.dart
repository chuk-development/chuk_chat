// lib/services/streaming_manager.dart
import 'dart:async';
import 'package:chuk_chat/services/streaming_chat_service.dart';
import 'package:flutter/foundation.dart';

/// Manages multiple concurrent chat streams across different chats
class StreamingManager {
  static final StreamingManager _instance = StreamingManager._internal();
  factory StreamingManager() => _instance;
  StreamingManager._internal();

  // Map of chatId -> ActiveStream
  final Map<String, _ActiveStream> _activeStreams = {};

  /// Check if a chat is currently streaming
  bool isStreaming(String chatId) {
    return _activeStreams.containsKey(chatId) &&
           _activeStreams[chatId]!.isActive;
  }

  /// Start a new stream for a chat
  Future<void> startStream({
    required String chatId,
    required int messageIndex,
    required Stream<ChatStreamEvent> stream,
    required Function(String content, String reasoning) onUpdate,
    required Function(String content, String reasoning) onComplete,
    required Function(String error) onError,
  }) async {
    // Cancel existing stream for this chat if any
    await cancelStream(chatId);

    final streamSub = stream.listen(
      (event) {
        final activeStream = _activeStreams[chatId];
        if (activeStream == null || !activeStream.isActive) return;

        if (event is ContentEvent) {
          activeStream.contentBuffer.write(event.text);
          onUpdate(
            activeStream.contentBuffer.toString(),
            activeStream.reasoningBuffer.toString(),
          );
        } else if (event is ReasoningEvent) {
          activeStream.reasoningBuffer.write(event.text);
          onUpdate(
            activeStream.contentBuffer.toString(),
            activeStream.reasoningBuffer.toString(),
          );
        }
      },
      onError: (error) {
        debugPrint('Stream error for chat $chatId: $error');
        onError('Error: $error');
        _cleanupStream(chatId);
      },
      onDone: () {
        debugPrint('Stream completed for chat $chatId');
        final activeStream = _activeStreams[chatId];
        if (activeStream == null) return;

        final finalContent = activeStream.contentBuffer.toString();
        final finalReasoning = activeStream.reasoningBuffer.toString();

        if (finalContent.isNotEmpty) {
          onComplete(finalContent, finalReasoning);
        }

        _cleanupStream(chatId);
      },
      cancelOnError: true,
    );

    _activeStreams[chatId] = _ActiveStream(
      subscription: streamSub,
      messageIndex: messageIndex,
      chatId: chatId,
    );
  }

  /// Cancel stream for a specific chat
  Future<void> cancelStream(String chatId) async {
    final activeStream = _activeStreams[chatId];
    if (activeStream != null) {
      await activeStream.subscription.cancel();
      _activeStreams.remove(chatId);
      debugPrint('Cancelled stream for chat $chatId');
    }
  }

  /// Cancel all active streams
  Future<void> cancelAllStreams() async {
    final chatIds = _activeStreams.keys.toList();
    for (final chatId in chatIds) {
      await cancelStream(chatId);
    }
  }

  void _cleanupStream(String chatId) {
    _activeStreams.remove(chatId);
  }

  /// Get info about active streams (for debugging)
  Map<String, bool> getActiveStreamsInfo() {
    return Map.fromEntries(
      _activeStreams.entries.map(
        (e) => MapEntry(e.key, e.value.isActive),
      ),
    );
  }
}

class _ActiveStream {
  final StreamSubscription<ChatStreamEvent> subscription;
  final int messageIndex;
  final String chatId;
  final StringBuffer contentBuffer = StringBuffer();
  final StringBuffer reasoningBuffer = StringBuffer();
  bool isActive = true;

  _ActiveStream({
    required this.subscription,
    required this.messageIndex,
    required this.chatId,
  });
}
