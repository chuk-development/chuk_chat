// lib/services/streaming_manager.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/utils/stream_error_sanitizer.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/streaming_chat_service.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

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

  // Track if app is in background - only show notification when backgrounded
  bool _isAppInBackground = false;
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

  /// What the running turn in [chatId] is doing, or null when nothing runs.
  /// Read once a second by the header above the answer, so it is a plain
  /// lookup rather than a stream of its own.
  StreamPhase? phaseOf(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.phase;
  }

  /// When the running turn in [chatId] began — the moment the request went
  /// out, not the moment the first token arrived.
  DateTime? startedAtOf(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.startedAt;
  }

  /// Start a new stream for a chat
  Future<void> startStream({
    required String chatId,
    required int messageIndex,
    required Stream<ChatStreamEvent> stream,
    required Function(String content, String reasoning) onUpdate,
    required Function(String content, String reasoning, double? tps) onComplete,
    required StreamErrorCallback onError,
    String? chatTitle,
  }) async {
    // Cancel existing stream for this chat if any
    await cancelStream(chatId);

    // Note: Foreground service is started only when app goes to background
    // See onAppLifecycleChanged() - this avoids showing notification while user is in app

    final streamSub = stream.listen(
      (event) {
        // Handle events in async function to allow awaiting notifications
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
          onError(
            'Error: ${sanitizeStreamError(error)}',
            code: StreamErrorCodes.streamFailure,
          );
        }
        _cleanupStream(chatId);
      },
      onDone: () {
        // Handle stream close in async function
        unawaited(_handleStreamClose(chatId: chatId, onComplete: onComplete));
      },
      cancelOnError: true, // Auto-cancel subscription on error to prevent leaks
    );

    final activeStream = _ActiveStream(
      subscription: streamSub,
      messageIndex: messageIndex,
      chatId: chatId,
      chatTitle: chatTitle,
    );

    // The silence watch. It reports; it never acts. See
    // [silenceReportInterval] for why there is no timeout here any more.
    _armSilenceWatch(activeStream);

    _activeStreams[chatId] = activeStream;
  }

  /// Cancel stream for a specific chat
  Future<void> cancelStream(String chatId) async {
    final activeStream = _activeStreams[chatId];
    if (activeStream != null) {
      activeStream.cancelSilenceWatch();
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
    final stream = _activeStreams.remove(chatId);
    stream?.cancelSilenceWatch();
    stream?.cancelUiThrottle();
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
      stream.cancelSilenceWatch();
      stream.cancelUiThrottle();
      // Cancel the subscription but keep the entry in the map
      unawaited(stream.subscription.cancel());
      if (kDebugMode) {
        debugPrint(
          '[StreamingManager] Completed stream $chatId: content=$contentLen chars, reasoning=$reasoningLen chars',
        );
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

  /// Handle stream events asynchronously to allow awaiting notifications
  Future<void> _handleStreamEvent({
    required String chatId,
    required ChatStreamEvent event,
    required Function(String content, String reasoning) onUpdate,
    required Function(String content, String reasoning, double? tps) onComplete,
    required StreamErrorCallback onError,
  }) async {
    final activeStream = _activeStreams[chatId];
    if (activeStream == null || !activeStream.isActive) return;

    // The first event of any kind — usually the meta frame — is the proof
    // that the server is there. Everything before it was still connecting.
    activeStream.firstEventAt ??= DateTime.now();
    activeStream.phase = switch (event) {
      ReasoningEvent() => StreamPhase.thinking,
      ContentEvent() => StreamPhase.writing,
      // A frame that carries no token says only that the connection stands.
      _ =>
        activeStream.phase == StreamPhase.connecting
            ? StreamPhase.processing
            : activeStream.phase,
    };

    // Every event restarts the measured gap. Nothing is armed to fire on it:
    // this is what the log reports, not what decides the stream's fate.
    activeStream.lastEventAt = DateTime.now();
    activeStream.eventCount++;

    // Record time-to-first-token on the first real delta (content or reasoning).
    if ((event is ContentEvent || event is ReasoningEvent) &&
        activeStream.firstTokenAt == null) {
      activeStream.firstTokenAt = DateTime.now();
      if (kDebugMode) {
        final ttftMs = activeStream.firstTokenAt!
            .difference(activeStream.startedAt)
            .inMilliseconds;
        debugPrint('⏱️ [TTFT] chat $chatId: first token in ${ttftMs}ms');
      }
    }

    if (event is FinalContentEvent) {
      activeStream.contentBuffer
        ..clear()
        ..write(event.text);
      // Publish the canonical snapshot before completion clears the live
      // notifier, including when the33ms delta timer has not fired yet.
      activeStream.uiThrottleTimer?.cancel();
      activeStream.uiThrottleTimer = null;
      activeStream.uiUpdatePending = false;
      onUpdate(event.text, activeStream.reasoningBuffer.toString());
    } else if (event is ContentEvent) {
      activeStream.contentBuffer.write(event.text);
      // Coalesced flush (see _uiUpdateInterval) — avoids re-parsing the whole
      // message on every token. Notification update happens inside the flush
      // so we don't stringify the buffer per token.
      _scheduleUiFlush(activeStream, onUpdate);
    } else if (event is ReasoningEvent) {
      activeStream.reasoningBuffer.write(event.text);
      _scheduleUiFlush(activeStream, onUpdate);
    } else if (event is TpsEvent) {
      // Store TPS metric for later use in onComplete
      activeStream.tps = event.tokensPerSecond;
    } else if (event is ToolCallsEvent) {
      // Native tool calls, assembled server-side. Collected here and read by
      // the tool loop after completion via getNativeToolCalls.
      activeStream.nativeToolCalls.addAll(event.calls);
    } else if (event is MetaEvent) {
      activeStream.latestMeta = Map<String, dynamic>.from(event.meta);
    } else if (event is HeartbeatEvent) {
      // Proof of life and nothing else. It has already restarted the measured
      // gap above, and the phase switch has already moved `connecting` to
      // `processing` — the host answered, it is reading the prompt. There is
      // no content to buffer and nothing to finish.
      activeStream.heartbeatCount++;
      activeStream.lastHeartbeatSeq = event.seq;
    } else if (event is ErrorEvent) {
      // Handle error events from the stream (e.g., API errors)
      if (kDebugMode) {
        debugPrint('Stream ErrorEvent for chat $chatId: ${event.message}');
      }
      // Mark the stream cleaned up BEFORE invoking onError. Otherwise the
      // setState() inside onError rebuilds while isStreaming() still
      // returns true, which leaves the UI stuck on the streaming spinner
      // even after the error message is shown.
      activeStream.isActive = false;
      _cleanupStream(chatId);
      onError(event.message, code: event.code);
    } else if (event is DoneEvent) {
      // Handle done events from the stream (successful completion)
      if (kDebugMode) {
        debugPrint('Stream DoneEvent for chat $chatId');
      }
      final finalContent = activeStream.contentBuffer.toString();
      final finalReasoning = activeStream.reasoningBuffer.toString();
      final tps = activeStream.tps;

      // Mark inactive BEFORE awaiting so a concurrently-scheduled
      // `_handleStreamClose` (fired by the listener's onDone right
      // after this event in the multiplex path) early-returns and
      // does not double-fire onComplete. Two onCompletes would each
      // recursively launch the next tool-loop pass, and both passes
      // would write into the same UI message buffer — that is the
      // root cause of the v1.0.96 character-by-character interleave
      // exposed by the /v2/ws multiplex landing (DoneEvent + onDone
      // arrive synchronously in the multiplex demuxer).
      activeStream.isActive = false;
      activeStream.cancelSilenceWatch();

      // Show completion notification if app is in background
      // IMPORTANT: Await this before cleanup so foreground service stops AFTER
      if (_shouldShowCompletionNotification()) {
        await NotificationService.showCompletionNotification(
          chatId: chatId,
          chatTitle: activeStream.chatTitle ?? 'AI Chat',
          contentPreview: finalContent,
        );
      }

      onComplete(finalContent, finalReasoning, tps);
      // Keep completed stream data available for chat reload —
      // don't remove from map, just record the completion timestamp.
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

    // Mark inactive BEFORE awaiting so we cannot race a concurrent
    // DoneEvent handler into firing onComplete twice (see the
    // matching note in _handleStreamEvent above).
    activeStream.isActive = false;
    activeStream.cancelSilenceWatch();

    // Show completion notification if app is in background
    // IMPORTANT: Await this before cleanup so foreground service stops AFTER
    if (_shouldShowCompletionNotification()) {
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
  void _armSilenceWatch(_ActiveStream stream) {
    stream.cancelSilenceWatch();
    stream.silenceTimer = Timer.periodic(silenceReportInterval, (timer) {
      if (!stream.isActive) {
        timer.cancel();
        return;
      }
      final now = DateTime.now();
      final since = stream.lastEventAt ?? stream.startedAt;
      final gap = now.difference(since);
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
  void _reportSilence(_ActiveStream stream, Duration gap) {
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

  /// Schedule a coalesced UI flush: at most one [onUpdate] per
  /// [_uiUpdateInterval], always carrying the latest buffered content. The
  /// expensive per-update work (markdown parse, tool-call strip, setState)
  /// thus runs at frame rate instead of token rate. The final buffer is
  /// delivered separately via onComplete, so dropping the last pending flush
  /// is harmless.
  void _scheduleUiFlush(
    _ActiveStream stream,
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

  /// Update notification with content (throttled to avoid excessive updates)
  /// Only updates if app is in background and service is running
  void _updateNotificationThrottled(String content) {
    if (!Platform.isAndroid) return;
    if (!_isAppInBackground) return; // Don't update if user is in app
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
  void onAppLifecycleChanged({required bool isInBackground}) {
    _isAppInBackground = isInBackground;

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
          for (final stream in _activeStreams.values) {
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
    if (!_isAppInBackground) return false;
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

  /// Get info about active streams (for debugging)
  Map<String, bool> getActiveStreamsInfo() {
    return Map.fromEntries(
      _activeStreams.entries.map((e) => MapEntry(e.key, e.value.isActive)),
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

  /// Get the latest stream metadata for a chat (active or completed).
  /// Returns null if no metadata was received.
  Map<String, dynamic>? getLatestMeta(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || stream.latestMeta == null) return null;
    return Map<String, dynamic>.from(stream.latestMeta!);
  }

  /// Native tool calls the model requested on the just-completed pass, read by
  /// the tool loop in onComplete. Empty when the turn produced no tool calls.
  List<NativeToolCall> getNativeToolCalls(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null) return const <NativeToolCall>[];
    return List<NativeToolCall>.from(stream.nativeToolCalls);
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
        debugPrint(
          '[StreamingManager] Consumed completed stream for chat $chatId',
        );
      }
    }
  }

  /// Store background messages for a streaming chat.
  /// Called when user switches away from an actively streaming chat AND
  /// when a stream first starts — so [getBackgroundMessages] always has
  /// a valid snapshot to layer the buffer on top of.
  ///
  /// Accepted while the stream is active OR completed-but-not-yet-consumed:
  /// the completion path still needs to persist final content + tool calls
  /// to the per-chat snapshot even though `isActive` flipped to false
  /// in `_handleStreamEvent` before `onComplete` runs.
  void setBackgroundMessages(
    String chatId,
    List<Map<String, dynamic>> messages, {
    String? modelId,
    String? provider,
  }) {
    final stream = _activeStreams[chatId];
    if (stream == null) return;

    stream.backgroundMessages = messages;
    stream.modelId = modelId;
    stream.provider = provider;
    if (kDebugMode) {
      debugPrint(
        '[StreamingManager] Stored ${messages.length} background messages for chat $chatId',
      );
    }
  }

  /// Get background messages with current buffer content applied.
  /// Works for both active and completed-but-not-yet-consumed streams so
  /// the completion-while-away write path can persist final content.
  /// Returns null only if no snapshot was ever taken for this chat.
  List<Map<String, dynamic>>? getBackgroundMessages(String chatId) {
    final stream = _activeStreams[chatId];
    if (stream == null || stream.backgroundMessages == null) {
      return null;
    }

    // Return copy with current buffer content applied to the AI placeholder
    final messages = stream.backgroundMessages!
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (stream.messageIndex < messages.length) {
      final rawContent = stream.contentBuffer.toString();
      messages[stream.messageIndex]['text'] = stripToolCallBlocksForDisplay(
        rawContent,
      );
      messages[stream.messageIndex]['reasoning'] = stream.reasoningBuffer
          .toString();
    }
    return messages;
  }

  /// Check if a chat has background messages stored.
  /// True for both active and completed-but-not-yet-consumed streams.
  bool hasBackgroundMessages(String chatId) {
    final stream = _activeStreams[chatId];
    return stream != null && stream.backgroundMessages != null;
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
  Map<String, dynamic>? latestMeta;

  /// Native OpenAI-format tool calls the model requested this pass (assembled
  /// server-side from `delta.tool_calls`). Read after completion via
  /// [StreamingManager.getNativeToolCalls]; empty for a plain text turn.
  final List<NativeToolCall> nativeToolCalls = <NativeToolCall>[];

  // Time-to-first-token measurement.
  // startedAt = when the stream subscription is created (≈ message sent).
  // firstTokenAt = when the first content/reasoning delta arrives.
  final DateTime startedAt = DateTime.now();
  DateTime? firstTokenAt;

  /// The first event of any kind, token or not — when the server proved it
  /// was there. Separates "connecting" from "reading the prompt".
  DateTime? firstEventAt;

  /// What this turn is doing, for the header above the answer.
  StreamPhase phase = StreamPhase.connecting;

  // Timestamp when stream completed (for TTL eviction)
  DateTime? completedAt;

  /// The log-only silence watch (see [StreamingManager.silenceReportInterval]).
  /// It reports gaps; it has no power to end the stream.
  Timer? silenceTimer;

  /// When the last event of any kind arrived, null while none has. The gap the
  /// log reports is measured from here, falling back to [startedAt].
  DateTime? lastEventAt;

  /// How many events of any kind this stream has seen, and how many of those
  /// were heartbeats. Diagnostics only — nothing branches on them.
  int eventCount = 0;
  int heartbeatCount = 0;

  /// The `seq` of the last heartbeat, so a gap in the host's sequence shows up
  /// in the log.
  int lastHeartbeatSeq = 0;

  // UI-update coalescing: holds the timer that flushes the latest buffer to
  // the UI at most once per [_uiUpdateInterval], plus whether a token has
  // arrived since the last flush.
  Timer? uiThrottleTimer;
  bool uiUpdatePending = false;

  void cancelUiThrottle() {
    uiThrottleTimer?.cancel();
    uiThrottleTimer = null;
    uiUpdatePending = false;
  }

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

  void cancelSilenceWatch() {
    silenceTimer?.cancel();
    silenceTimer = null;
  }
}
