// lib/services/streaming_manager_io.dart
// Native implementation: the shared core from streaming_manager_base.dart plus
// notification, foreground-service, idle-timeout and UI-throttle handling.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/streaming_manager_base.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

/// Manages multiple concurrent chat streams across different chats
class StreamingManager extends StreamingManagerBase {
  static final StreamingManager _instance = StreamingManager._internal();
  factory StreamingManager() => _instance;
  StreamingManager._internal();

  // Throttle notification updates to avoid excessive updates
  DateTime? _lastNotificationUpdate;
  static const _notificationUpdateInterval = Duration(milliseconds: 500);

  /// Coalesce UI updates to roughly one per frame. Each onUpdate triggers a
  /// full-message markdown re-parse + tool-call regex strip + setState in the
  /// UI layer — all O(n) in the message-so-far, so running them per token is
  /// O(n²) and makes long responses feel sluggish. Flushing the latest buffer
  /// at most every ~33ms (≈30fps) cuts that work by 2–4× on fast streams with
  /// no visible difference; the final buffer is always flushed on completion.
  static const _uiUpdateInterval = Duration(milliseconds: 33);

  /// Idle timeout: if no event arrives for this duration, the stream
  /// is considered dead. This prevents the "Thinking..." state from
  /// hanging forever when the server silently drops the connection.
  static const _idleTimeout = Duration(seconds: 60);

  /// Start the idle timer — if no events arrive within [_idleTimeout],
  /// treat the stream as dead and clean up.
  @override
  void armIdleTimer({
    required String chatId,
    required ActiveStream stream,
    required void Function(String content, String reasoning, double? tps)
    onComplete,
    required StreamErrorCallback onError,
  }) {
    stream.idleTimer = _startIdleTimer(
      chatId: chatId,
      stream: stream,
      emptyMessage:
          'No response received — the server may be overloaded. '
          'Please try again.',
      onComplete: onComplete,
      onError: onError,
    );
  }


  /// The idle watchdog: nothing arrived for [_idleTimeout], so the connection
  /// is treated as dead.
  ///
  /// Armed once when the stream starts and re-armed on every event, which is
  /// why both paths need the same body — including the
  /// [StreamErrorCodes.idleTimeout] code. The re-armed timer is the one that
  /// fires for almost every real timeout, and it used to report no code at
  /// all, so callers that branch on the code never saw an idle timeout.
  ///
  /// Partial content is kept: a stream that stopped halfway is completed with
  /// what already arrived rather than thrown away.
  Timer _startIdleTimer({
    required String chatId,
    required ActiveStream stream,
    required String emptyMessage,
    required void Function(String content, String reasoning, double? tps)
    onComplete,
    required StreamErrorCallback onError,
  }) {
    return Timer(_idleTimeout, () {
      // Guard against firing after the stream already completed.
      if (!stream.isActive) return;
      stream.isActive = false;
      if (kDebugMode) {
        debugPrint(
          '[StreamingManager] Idle timeout for chat $chatId — '
          'no data for ${_idleTimeout.inSeconds}s',
        );
      }
      final content = stream.contentBuffer.toString();
      if (content.isEmpty) {
        onError(emptyMessage, code: StreamErrorCodes.idleTimeout);
      } else {
        onComplete(content, stream.reasoningBuffer.toString(), stream.tps);
      }
      cleanupStream(chatId);
    });
  }

  @override
  void onEventBookkeeping({
    required String chatId,
    required ActiveStream stream,
    required ChatStreamEvent event,
    required void Function(String content, String reasoning, double? tps)
    onComplete,
    required StreamErrorCallback onError,
  }) {
    // The first event of any kind — usually the meta frame — is the proof
    // that the server is there. Everything before it was still connecting.
    stream.firstEventAt ??= DateTime.now();

    // Reset idle timer on every event — connection is still alive
    stream.cancelIdleTimer();
    stream.idleTimer = _startIdleTimer(
      chatId: chatId,
      stream: stream,
      emptyMessage:
          'Response timed out — the server stopped responding. '
          'Please try again.',
      onComplete: onComplete,
      onError: onError,
    );

    // Record time-to-first-token on the first real delta (content or reasoning).
    if ((event is ContentEvent || event is ReasoningEvent) &&
        stream.firstTokenAt == null) {
      stream.firstTokenAt = DateTime.now();
      if (kDebugMode) {
        final ttftMs = stream.firstTokenAt!
            .difference(stream.startedAt)
            .inMilliseconds;
        debugPrint('⏱️ [TTFT] chat $chatId: first token in ${ttftMs}ms');
      }
    }
  }

  /// Schedule a coalesced UI flush: at most one onUpdate per
  /// [_uiUpdateInterval], always carrying the latest buffered content. The
  /// expensive per-update work (markdown parse, tool-call strip, setState)
  /// thus runs at frame rate instead of token rate. The final buffer is
  /// delivered separately via onComplete, so dropping the last pending flush
  /// is harmless. The notification update happens inside the flush so we
  /// don't stringify the buffer per token.
  @override
  void deliverUpdate(
    ActiveStream stream,
    Function(String content, String reasoning) onUpdate,
  ) {
    stream.uiUpdatePending = true;
    if (stream.uiThrottleTimer != null) return;
    stream.uiThrottleTimer = Timer(_uiUpdateInterval, () {
      stream.uiThrottleTimer = null;
      if (!stream.uiUpdatePending || !stream.isActive) return;
      stream.uiUpdatePending = false;
      final content = stream.contentBuffer.toString();
      onUpdate(content, stream.reasoningBuffer.toString());
      _updateNotificationThrottled(content);
    });
  }

  @override
  void beforeCompletion(ActiveStream stream) {
    stream.isActive = false;
    stream.cancelIdleTimer();
  }

  @override
  Future<void>? completionNotification({
    required String chatId,
    required ActiveStream stream,
    required String contentPreview,
  }) {
    if (!_shouldShowCompletionNotification()) return null;
    return NotificationService.showCompletionNotification(
      chatId: chatId,
      chatTitle: stream.chatTitle ?? 'AI Chat',
      contentPreview: contentPreview,
    );
  }

  @override
  Future<void>? onAllStreamsCancelled() {
    if (!Platform.isAndroid) return null;
    return StreamingForegroundService.stopService();
  }

  @override
  void stopBackgroundServiceIfIdle() {
    // Stop foreground service if no more active streams
    if (Platform.isAndroid && !hasActiveStreams) {
      unawaited(StreamingForegroundService.stopService());
    }
  }

  @override
  String contentForSnapshot(String rawContent) =>
      stripToolCallBlocksForDisplay(rawContent);

  /// Update notification with content (throttled to avoid excessive updates)
  /// Only updates if app is in background and service is running
  void _updateNotificationThrottled(String content) {
    if (!Platform.isAndroid) return;
    if (!isAppInBackground) return; // Don't update if user is in app
    if (!StreamingForegroundService.isRunning) return;

    final now = DateTime.now();
    if (_lastNotificationUpdate != null &&
        now.difference(_lastNotificationUpdate!) <
            _notificationUpdateInterval) {
      return; // Skip update, too soon
    }

    _lastNotificationUpdate = now;
    unawaited(StreamingForegroundService.updateNotification(content: content));
  }

  /// Called when app lifecycle changes - manages foreground service
  /// Start service when app goes to background with active streams
  /// Stop service when app comes to foreground
  @override
  void onAppBackgroundChanged(bool isInBackground) {
    if (!Platform.isAndroid) return;

    if (isInBackground &&
        (hasActiveStreams || StreamingForegroundService.hasKeepAliveLock)) {
      // App went to background while a stream/tool-loop is active.
      // Keep foreground service alive so follow-up passes can reconnect.
      if (kDebugMode) {
        debugPrint(
          '[StreamingManager] App backgrounded with active stream/lock - starting foreground service',
        );
      }
      unawaited(
        StreamingForegroundService.startService().then((_) {
          // Update notification with current content
          for (final stream in activeStreams.values) {
            if (stream.isActive) {
              final content = stream.contentBuffer.toString();
              if (content.isNotEmpty) {
                unawaited(
                  StreamingForegroundService.updateNotification(
                    content: content,
                  ),
                );
              }
              break; // Just use the first active stream's content
            }
          }
        }),
      );
    } else if (!isInBackground && StreamingForegroundService.isRunning) {
      // App came to foreground - stop foreground service (notification no longer needed)
      if (kDebugMode) {
        debugPrint(
          '[StreamingManager] App resumed - stopping foreground service',
        );
      }
      unawaited(StreamingForegroundService.stopService(preserveLocks: true));
    }
  }

  bool _shouldShowCompletionNotification() {
    if (!isAppInBackground) return false;
    if (Platform.isAndroid) {
      // On Android we already have a single foreground-service notification.
      // Avoid showing a second "completion" notification for the same turn.
      if (StreamingForegroundService.hasKeepAliveLock ||
          StreamingForegroundService.isRunning) {
        return false;
      }
    }
    return Platform.isAndroid || Platform.isIOS;
  }
}
