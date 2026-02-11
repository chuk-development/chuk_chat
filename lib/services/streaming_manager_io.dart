// lib/services/streaming_manager.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/notification_service.dart';

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
    String? chatTitle,
  }) async {
    // Cancel existing stream for this chat if any
    await cancelStream(chatId);

    // Note: Foreground service is started only when app goes to background
    // See onAppLifecycleChanged() - this avoids showing notification while user is in app

    final streamSub = stream.listen(
      (event) {
        // Handle events in async function to allow awaiting notifications
        unawaited(_handleStreamEvent(
          chatId: chatId,
          event: event,
          onUpdate: onUpdate,
          onComplete: onComplete,
          onError: onError,
        ));
      },
      onError: (error) {
        if (kDebugMode) {
          debugPrint('Stream subscription error for chat $chatId: $error');
        }
        onError('Error: $error');
        _cleanupStream(chatId);
      },
      onDone: () {
        // Handle stream close in async function
        unawaited(_handleStreamClose(
          chatId: chatId,
          onComplete: onComplete,
        ));
      },
      cancelOnError: false, // Don't cancel on error, let ErrorEvent handle it
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

  /// Mark a stream as completed but keep its buffered content available.
  /// Used when a stream finishes naturally (DoneEvent / onDone) so that
  /// the UI can still retrieve the final content when the user switches
  /// back to this chat.
  void _completeStream(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream != null) {
      final contentLen = stream.contentBuffer.length;
      final reasoningLen = stream.reasoningBuffer.length;
      stream.isActive = false;
      stream.completedAt = DateTime.now();
      // Cancel the subscription but keep the entry in the map
      unawaited(stream.subscription.cancel());
      if (kDebugMode) {
        debugPrint('[StreamingManager] Completed stream $chatId: content=$contentLen chars, reasoning=$reasoningLen chars');
      }
    }
    // Evict stale completed streams to prevent memory accumulation
    _evictStaleCompletedStreams();
    // Stop foreground service if no more active streams
    if (Platform.isAndroid && !hasActiveStreams) {
      unawaited(StreamingForegroundService.stopService());
    }
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

    // Remove TTL-expired entries
    for (final id in staleIds) {
      _activeStreams.remove(id);
      if (kDebugMode) {
        debugPrint('[StreamingManager] Evicted stale completed stream: $id');
      }
    }

    // If still over max, remove oldest completed streams
    if (completedCount - staleIds.length > _maxCompletedStreams) {
      final completedEntries = _activeStreams.entries
          .where((e) => !e.value.isActive && e.value.completedAt != null)
          .toList()
        ..sort((a, b) => a.value.completedAt!.compareTo(b.value.completedAt!));

      final toRemove = completedEntries.length - _maxCompletedStreams;
      for (int i = 0; i < toRemove; i++) {
        _activeStreams.remove(completedEntries[i].key);
      }
    }
  }

  /// Handle stream events asynchronously to allow awaiting notifications
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
      if (kDebugMode) {
        debugPrint('Stream ErrorEvent for chat $chatId: ${event.message}');
      }
      onError(event.message);
      _cleanupStream(chatId);
    } else if (event is DoneEvent) {
      // Handle done events from the stream (successful completion)
      if (kDebugMode) {
        debugPrint('Stream DoneEvent for chat $chatId');
      }
      final finalContent = activeStream.contentBuffer.toString();
      final finalReasoning = activeStream.reasoningBuffer.toString();
      final tps = activeStream.tps;

      // Show completion notification if app is in background
      // IMPORTANT: Await this before cleanup so foreground service stops AFTER
      if (_isAppInBackground && (Platform.isAndroid || Platform.isIOS)) {
        await NotificationService.showCompletionNotification(
          chatId: chatId,
          chatTitle: activeStream.chatTitle ?? 'AI Chat',
          contentPreview: finalContent,
        );
      }

      onComplete(finalContent, finalReasoning, tps);
      // Keep completed stream data available for chat reload —
      // don't remove from map, just mark inactive.
      _completeStream(chatId);
    }
    // UsageEvent and MetaEvent are ignored (just logging)
  }

  /// Handle stream close asynchronously
  Future<void> _handleStreamClose({
    required String chatId,
    required Function(String content, String reasoning, double? tps) onComplete,
  }) async {
    // Stream closed - if we haven't completed via DoneEvent, complete now
    final activeStream = _activeStreams[chatId];
    if (activeStream == null || !activeStream.isActive) return;

    if (kDebugMode) {
      debugPrint('Stream subscription closed for chat $chatId');
    }
    final finalContent = activeStream.contentBuffer.toString();
    final finalReasoning = activeStream.reasoningBuffer.toString();
    final tps = activeStream.tps;

    // Show completion notification if app is in background
    // IMPORTANT: Await this before cleanup so foreground service stops AFTER
    if (_isAppInBackground && (Platform.isAndroid || Platform.isIOS)) {
      await NotificationService.showCompletionNotification(
        chatId: chatId,
        chatTitle: activeStream.chatTitle ?? 'AI Chat',
        contentPreview: finalContent,
      );
    }

    // Always call onComplete - handler will show "empty response" message if needed
    // This ensures UI state is properly reset even for reasoning-only streams
    onComplete(finalContent, finalReasoning, tps);

    // Keep completed stream data available for chat reload
    _completeStream(chatId);
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
      if (kDebugMode) {
        debugPrint('[StreamingManager] App backgrounded with active streams - starting foreground service');
      }
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
      if (kDebugMode) {
        debugPrint('[StreamingManager] App resumed - stopping foreground service');
      }
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

  /// Get the current buffered content for a chat (active or completed).
  /// Returns null if chat has no stream entry.
  String? getBufferedContent(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null) return null;

    final content = stream.contentBuffer.toString();
    return content.isEmpty ? null : content;
  }

  /// Get the current buffered reasoning for a chat (active or completed).
  /// Returns null if chat has no stream entry.
  String? getBufferedReasoning(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null) return null;

    final reasoning = stream.reasoningBuffer.toString();
    return reasoning.isEmpty ? null : reasoning;
  }

  /// Get the message index being streamed for a chat (active or completed).
  /// Returns null if chat has no stream entry.
  int? getStreamingMessageIndex(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null) return null;
    return stream.messageIndex;
  }

  /// Get the TPS (tokens per second) for a streaming chat
  /// Returns null if chat is not streaming or TPS not yet received
  double? getTps(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.tps;
  }

  /// Check if a chat has a completed stream with buffered content
  /// that hasn't been consumed yet.
  bool hasCompletedStream(String chatId) {
    final stream = _activeStreams[chatId];
    return stream != null && !stream.isActive;
  }

  /// Remove a completed stream entry after its content has been consumed.
  /// Call this after applying the buffered content to the UI.
  void consumeCompletedStream(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream != null && !stream.isActive) {
      _activeStreams.remove(chatId);
      if (kDebugMode) {
        debugPrint('[StreamingManager] Consumed completed stream for chat $chatId');
      }
    }
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
    if (kDebugMode) {
      debugPrint('[StreamingManager] Stored ${messages.length} background messages for chat $chatId');
    }
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
  final String? chatTitle;
  final StringBuffer contentBuffer = StringBuffer();
  final StringBuffer reasoningBuffer = StringBuffer();
  bool isActive = true;

  // Tokens per second metric (set when TpsEvent is received)
  double? tps;

  // Timestamp when stream completed (for TTL eviction)
  DateTime? completedAt;

  // Background message storage for when user switches away during streaming
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
