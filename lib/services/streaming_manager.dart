// lib/services/streaming_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';

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
        } else if (event is ErrorEvent) {
          // Handle error events from the stream (e.g., API errors)
          debugPrint('Stream ErrorEvent for chat $chatId: ${event.message}');
          onError(event.message);
          _cleanupStream(chatId);
        } else if (event is DoneEvent) {
          // Handle done events from the stream (successful completion)
          debugPrint('Stream DoneEvent for chat $chatId');
          final finalContent = activeStream.contentBuffer.toString();
          final finalReasoning = activeStream.reasoningBuffer.toString();
          onComplete(finalContent, finalReasoning);
          _cleanupStream(chatId);
        }
        // UsageEvent and MetaEvent are ignored (just logging)
      },
      onError: (error) {
        debugPrint('Stream subscription error for chat $chatId: $error');
        onError('Error: $error');
        _cleanupStream(chatId);
      },
      onDone: () {
        // Stream closed - if we haven't completed via DoneEvent, complete now
        final activeStream = _activeStreams[chatId];
        if (activeStream == null || !activeStream.isActive) return;

        debugPrint('Stream subscription closed for chat $chatId');
        final finalContent = activeStream.contentBuffer.toString();
        final finalReasoning = activeStream.reasoningBuffer.toString();

        // Only call onComplete if there's content (avoid duplicate calls if DoneEvent already fired)
        if (finalContent.isNotEmpty) {
          onComplete(finalContent, finalReasoning);
        }

        _cleanupStream(chatId);
      },
      cancelOnError: false, // Don't cancel on error, let ErrorEvent handle it
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

  /// Get the current buffered content for a streaming chat
  /// Returns null if chat is not streaming
  String? getBufferedContent(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;

    final content = stream.contentBuffer.toString();
    return content.isEmpty ? null : content;
  }

  /// Get the current buffered reasoning for a streaming chat
  /// Returns null if chat is not streaming
  String? getBufferedReasoning(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;

    final reasoning = stream.reasoningBuffer.toString();
    return reasoning.isEmpty ? null : reasoning;
  }

  /// Get the message index being streamed for a chat
  /// Returns null if chat is not streaming
  int? getStreamingMessageIndex(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.messageIndex;
  }

  /// Store background messages for a streaming chat
  /// Called when user switches away from an actively streaming chat
  void setBackgroundMessages(String chatId, List<Map<String, dynamic>> messages, {
    String? modelId,
    String? provider,
  }) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return;

    stream.backgroundMessages = messages;
    stream.modelId = modelId;
    stream.provider = provider;
    debugPrint('[StreamingManager] Stored ${messages.length} background messages for chat $chatId');
  }

  /// Get background messages with current buffer content applied
  /// Returns null if chat is not streaming in background
  List<Map<String, dynamic>>? getBackgroundMessages(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive || stream.backgroundMessages == null) {
      return null;
    }

    // Return copy with current buffer content applied to the AI placeholder
    final messages = stream.backgroundMessages!
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (stream.messageIndex < messages.length) {
      messages[stream.messageIndex]['text'] = stream.contentBuffer.toString();
      messages[stream.messageIndex]['reasoning'] = stream.reasoningBuffer.toString();
    }
    return messages;
  }

  /// Check if a chat has background messages stored
  bool hasBackgroundMessages(String chatId) {
    final stream = _activeStreams[chatId];
    return stream != null && stream.isActive && stream.backgroundMessages != null;
  }
}

class _ActiveStream {
  final StreamSubscription<ChatStreamEvent> subscription;
  final int messageIndex;
  final String chatId;
  final StringBuffer contentBuffer = StringBuffer();
  final StringBuffer reasoningBuffer = StringBuffer();
  bool isActive = true;

  // Background message storage for when user switches away during streaming
  List<Map<String, dynamic>>? backgroundMessages;
  String? modelId;
  String? provider;

  _ActiveStream({
    required this.subscription,
    required this.messageIndex,
    required this.chatId,
  });
}
