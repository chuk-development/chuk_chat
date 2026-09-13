// lib/services/streaming_manager_io.dart
// Native implementation: the shared core from streaming_manager_base.dart plus
// notification, foreground-service, silence-log and UI-throttle handling.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/streaming_manager_base.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
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

  /// Silence is not a failure, and this class no longer treats it as one.
  ///
  /// There used to be a flat 60-second idle timeout here: no event of any kind
  /// for a minute and the stream was torn down with "No response received —
  /// the server may be overloaded". That sentence was a guess the app had no
  /// evidence for, and on this user's own host it was simply wrong. Turns
  /// carrying 170k–290k prompt tokens run 405 s, 490 s, 631 s, 818 s and
  /// 1851 s end to end (`~/.cowork/executor-state.db`, table `runs`), and a
  /// provider sends nothing at all until the prefill is done — so the very
  /// first gap can pass a minute on its own, and so can any single shell
  /// command or browser step. The app was killing working runs.
  ///
  /// A slow answer is not an error. An error is an error: the socket drops,
  /// the host sends an `error` frame, the run comes back failed, or the user
  /// stops it. Every one of those paths still ends the stream at once — they
  /// are events, not silence. What is gone is the timer that invented a
  /// failure out of nothing having happened yet.
  ///
  /// What remains is a [Timer.periodic] that only ever writes a line to the
  /// log, so a genuinely stuck run can still be diagnosed afterwards. It ends
  /// nothing, shows nothing and throws no buffered content away.
  ///
  /// Not `const`: a test drives the clock through it instead of waiting.
  @visibleForTesting
  static Duration silenceReportInterval = const Duration(seconds: 60);

  /// Arms the log-only silence watch for [stream].
  ///
  /// Fires every [silenceReportInterval] for as long as the stream is active
  /// and writes one line when nothing has arrived for at least that long. It
  /// never touches the stream: no teardown, no error, no completion, and the
  /// buffered content is not read for anything but its length.
  ///
  /// This is the whole of what used to be the idle timeout. The user asked for
  /// the logging explicitly — a run that really is stuck has to stay
  /// diagnosable after the fact — and for nothing to be killed on a guess.
  @override
  void armSilenceWatch(ActiveStream stream) {
    stream.cancelSilenceWatch();
    stream.silenceTimer = Timer.periodic(silenceReportInterval, (timer) {
      if (!stream.isActive) {
        timer.cancel();
        return;
      }
      final since = stream.lastEventAt ?? stream.startedAt;
      final gap = DateTime.now().difference(since);
      if (gap < silenceReportInterval) return;
      _reportSilence(stream, gap);
    });
  }

  /// One log line about an observed gap: which phase it happened in, how long
  /// it actually was, how many events had arrived (and how many of those were
  /// heartbeats), and whether any content was already buffered.
  ///
  /// "waiting for the first event" and "mid-stream" are different failures —
  /// the first is a request that never got picked up, the second a run that
  /// went quiet after it started — so the line names which one it is.
  void _reportSilence(ActiveStream stream, Duration gap) {
    final waiting = stream.eventCount == 0;
    final phase = waiting ? 'waiting for the first event' : 'mid-stream';
    final buffered = stream.contentBuffer.length;
    final beats = stream.heartbeatCount;
    if (kDebugMode) {
      debugPrint(
        '[StreamingManager] chat ${stream.chatId} quiet for ${gap.inSeconds}s '
        '($phase, phase=${stream.phase.name}, events=${stream.eventCount}, '
        'heartbeats=$beats${beats > 0 ? ' (last seq ${stream.lastHeartbeatSeq})' : ''}, '
        'buffered=$buffered chars). Not an error: the run may still be working '
        'on the host.',
      );
    }
    // Also to the app's own opt-in logger, because that one survives a release
    // build — a debug-only line cannot diagnose a stuck run on the phone. Only
    // metadata goes in: how long, how many, how big. Never the text itself.
    unawaited(
      DiagnosticsLogService.info(
        'streaming',
        'stream quiet',
        data: <String, Object?>{
          'chat_id': stream.chatId,
          'gap_seconds': gap.inSeconds,
          'waiting_for_first_event': waiting,
          'phase': stream.phase.name,
          'events': stream.eventCount,
          'heartbeats': beats,
          'last_heartbeat_seq': stream.lastHeartbeatSeq,
          'buffered_chars': buffered,
          'reasoning_chars': stream.reasoningBuffer.length,
        },
      ).catchError((Object _) {}),
    );
  }

  @override
  void onEventBookkeeping({
    required String chatId,
    required ActiveStream stream,
    required ChatStreamEvent event,
  }) {
    // The first event of any kind — usually the meta frame — is the proof
    // that the server is there. Everything before it was still connecting.
    stream.firstEventAt ??= DateTime.now();

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
    stream.cancelSilenceWatch();
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

  /// Agents: the host's canonical final answer (`FinalContentEvent`, emitted by
  /// `websocket_chat_service.dart`). It REPLACES the streamed deltas instead of
  /// appending to them, and it is published at once — the coalesced delta flush
  /// may not have fired yet and completion clears the live notifier right after,
  /// so a throttled update would lose the answer. Upstream's base has no branch
  /// for this event; keep this override with it.
  @override
  Future<void> handleStreamEvent({
    required String chatId,
    required ChatStreamEvent event,
    required Function(String content, String reasoning) onUpdate,
    required Function(String content, String reasoning, double? tps) onComplete,
    required StreamErrorCallback onError,
  }) async {
    if (event is FinalContentEvent) {
      final stream = activeStreams[chatId];
      if (stream != null && stream.isActive) {
        stream.contentBuffer
          ..clear()
          ..write(event.text);
        stream.cancelUiThrottle();
        onUpdate(event.text, stream.reasoningBuffer.toString());
      }
    }
    return super.handleStreamEvent(
      chatId: chatId,
      event: event,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }
}
