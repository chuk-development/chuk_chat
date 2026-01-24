// lib/services/streaming_manager.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';

/// Manages multiple concurrent chat streams across different chats
class StreamingManager {
  static final StreamingManager _instance = StreamingManager._internal();
  factory StreamingManager() => _instance;
  StreamingManager._internal();

  // Map of chatId -> ActiveStream
  final Map<String, _ActiveStream> _activeStreams = {};

  // Throttle notification updates to avoid excessive updates
  DateTime? _lastNotificationUpdate;
  static const _notificationUpdateInterval = Duration(milliseconds: 500);

  // Track if app is in background - only show notification when backgrounded
  bool _isAppInBackground = false;

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
  }) async {
    // Cancel existing stream for this chat if any
    await cancelStream(chatId);

    // Note: Foreground service is started only when app goes to background
    // See onAppLifecycleChanged() - this avoids showing notification while user is in app

    final streamSub = stream.listen(
      (event) {
        final activeStream = _activeStreams[chatId];
        if (activeStream == null || !activeStream.isActive) return;

        if (event is ContentEvent) {
          activeStream.contentBuffer.write(event.text);
          final content = activeStream.contentBuffer.toString();
          onUpdate(
            content,
            activeStream.reasoningBuffer.toString(),
          );
          // Update notification with streaming content (throttled)
          _updateNotificationThrottled(content);
        } else if (event is ReasoningEvent) {
          activeStream.reasoningBuffer.write(event.text);
          onUpdate(
            activeStream.contentBuffer.toString(),
            activeStream.reasoningBuffer.toString(),
          );
        } else if (event is TpsEvent) {
          // Store TPS metric for later use in onComplete
          activeStream.tps = event.tokensPerSecond;
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
          onComplete(finalContent, finalReasoning, activeStream.tps);
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
          onComplete(finalContent, finalReasoning, activeStream.tps);
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
    // Ensure foreground service is stopped
    if (Platform.isAndroid) {
      await StreamingForegroundService.stopService();
    }
  }

  void _cleanupStream(String chatId) {
    _activeStreams.remove(chatId);
    // Stop foreground service if no more active streams
    if (Platform.isAndroid && !hasActiveStreams) {
      unawaited(StreamingForegroundService.stopService());
    }
  }

  /// Update notification with content (throttled to avoid excessive updates)
  /// Only updates if app is in background and service is running
  void _updateNotificationThrottled(String content) {
    if (!Platform.isAndroid) return;
    if (!_isAppInBackground) return; // Don't update if user is in app
    if (!StreamingForegroundService.isRunning) return;

    final now = DateTime.now();
    if (_lastNotificationUpdate != null &&
        now.difference(_lastNotificationUpdate!) < _notificationUpdateInterval) {
      return; // Skip update, too soon
    }

    _lastNotificationUpdate = now;
    unawaited(StreamingForegroundService.updateNotification(content: content));
  }

  /// Called when app lifecycle changes - manages foreground service
  /// Start service when app goes to background with active streams
  /// Stop service when app comes to foreground
  void onAppLifecycleChanged({required bool isInBackground}) {
    _isAppInBackground = isInBackground;

    if (!Platform.isAndroid) return;

    if (isInBackground && hasActiveStreams) {
      // App went to background with active streams - start foreground service
      debugPrint('[StreamingManager] App backgrounded with active streams - starting foreground service');
      unawaited(StreamingForegroundService.startService().then((_) {
        // Update notification with current content
        for (final stream in _activeStreams.values) {
          if (stream.isActive) {
            final content = stream.contentBuffer.toString();
            if (content.isNotEmpty) {
              unawaited(StreamingForegroundService.updateNotification(content: content));
            }
            break; // Just use the first active stream's content
          }
        }
      }));
    } else if (!isInBackground && StreamingForegroundService.isRunning) {
      // App came to foreground - stop foreground service (notification no longer needed)
      debugPrint('[StreamingManager] App resumed - stopping foreground service');
      unawaited(StreamingForegroundService.stopService());
    }
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

  /// Get the TPS (tokens per second) for a streaming chat
  /// Returns null if chat is not streaming or TPS not yet received
  double? getTps(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.tps;
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

  // Tokens per second metric (set when TpsEvent is received)
  double? tps;

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
