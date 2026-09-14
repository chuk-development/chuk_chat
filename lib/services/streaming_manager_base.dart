// lib/services/streaming_manager_base.dart
//
// Platform-neutral core of StreamingManager: the stream registry, the content
// and reasoning buffers, completed-stream eviction and every public getter.
//
// The two platform builds (streaming_manager_io.dart, streaming_manager_stub.dart)
// extend this class. Everything that needs `dart:io` — notifications, the
// Android foreground service, the idle timer and the UI-update throttle — sits
// behind the overridable hooks below, whose defaults are no-ops. The defaults
// therefore *are* the web behaviour; the io subclass overrides them.
//
// IMPORTANT: this file is compiled for web, so it must never import `dart:io`.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/utils/stream_error_sanitizer.dart';
import 'package:chuk_chat/services/streaming_chat_service.dart';

/// Manages multiple concurrent chat streams across different chats.
abstract class StreamingManagerBase {
  /// Map of chatId -> [ActiveStream].
  @protected
  final Map<String, ActiveStream> activeStreams = {};

  /// Remove completed streams older than the TTL to prevent memory leaks.
  static const _completedStreamTtl = Duration(minutes: 5);
  static const _maxCompletedStreams = 5;

  // Track if app is in background - only show notification when backgrounded
  bool _isAppInBackground = false;

  /// Whether the app is currently in the background
  bool get isAppInBackground => _isAppInBackground;

  // ---------------------------------------------------------------------------
  // Platform hooks. The default implementations are the web behaviour (no
  // notifications, no foreground service, no idle timer, no UI throttle).
  // ---------------------------------------------------------------------------

  /// Arm the idle timer for a stream that has just been created, before it is
  /// registered in [activeStreams]. No-op where there is no idle handling.
  @protected
  void armIdleTimer({
    required String chatId,
    required ActiveStream stream,
    required void Function(String content, String reasoning, double? tps)
    onComplete,
    required StreamErrorCallback onError,
  }) {}

  /// Per-event bookkeeping that only some platforms do: first-event stamp,
  /// idle-timer reset, time-to-first-token measurement.
  @protected
  void onEventBookkeeping({
    required String chatId,
    required ActiveStream stream,
    required ChatStreamEvent event,
    required void Function(String content, String reasoning, double? tps)
    onComplete,
    required StreamErrorCallback onError,
  }) {}

  /// Deliver the current buffers to the UI. The default delivers immediately;
  /// the io build coalesces the calls to roughly one per frame.
  @protected
  void deliverUpdate(
    ActiveStream stream,
    Function(String content, String reasoning) onUpdate,
  ) {
    onUpdate(
      stream.contentBuffer.toString(),
      stream.reasoningBuffer.toString(),
    );
  }

  /// Runs immediately before `onComplete` is invoked, after the final content
  /// has been read out of the buffers.
  @protected
  void beforeCompletion(ActiveStream stream) {}

  /// The completion notification to await before `onComplete`, or null when
  /// no notification is shown. Returning null (instead of a completed future)
  /// matters: it keeps the completion path synchronous, so a DoneEvent and the
  /// subscription's onDone cannot interleave into a double `onComplete`.
  @protected
  Future<void>? completionNotification({
    required String chatId,
    required ActiveStream stream,
    required String contentPreview,
  }) => null;

  /// Extra teardown after [cancelAllStreams] has cancelled every stream, or
  /// null when there is nothing to await.
  @protected
  Future<void>? onAllStreamsCancelled() => null;

  /// Stop any background/foreground service once no stream is active.
  @protected
  void stopBackgroundServiceIfIdle() {}

  /// React to a foreground/background transition.
  @protected
  void onAppBackgroundChanged(bool isInBackground) {}

  /// Transform the raw content buffer before it is written into the background
  /// message snapshot.
  @protected
  String contentForSnapshot(String rawContent) => rawContent;

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Check if a chat is currently streaming
  bool isStreaming(String chatId) {
    return activeStreams.containsKey(chatId) && activeStreams[chatId]!.isActive;
  }

  /// Check if ANY chat is currently streaming
  bool get hasActiveStreams {
    return activeStreams.values.any((stream) => stream.isActive);
  }

  /// What the running turn in [chatId] is doing, or null when nothing runs.
  /// Read once a second by the header above the answer, so it is a plain
  /// lookup rather than a stream of its own.
  StreamPhase? phaseOf(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.phase;
  }

  /// When the running turn in [chatId] began — the moment the request went
  /// out, not the moment the first token arrived.
  DateTime? startedAtOf(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.startedAt;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

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

    // Note: the foreground service is started only when the app goes to
    // background — see onAppLifecycleChanged(). This avoids showing a
    // notification while the user is in the app.

    final streamSub = stream.listen(
      (event) {
        // Handle events in async function to allow awaiting notifications
        unawaited(
          handleStreamEvent(
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
        cleanupStream(chatId);
      },
      onDone: () {
        // Handle stream close in async function
        unawaited(handleStreamClose(chatId: chatId, onComplete: onComplete));
      },
      cancelOnError: true, // Auto-cancel subscription on error to prevent leaks
    );

    final activeStream = ActiveStream(
      subscription: streamSub,
      messageIndex: messageIndex,
      chatId: chatId,
      chatTitle: chatTitle,
    );

    armIdleTimer(
      chatId: chatId,
      stream: activeStream,
      onComplete: onComplete,
      onError: onError,
    );

    activeStreams[chatId] = activeStream;
  }

  /// Cancel stream for a specific chat
  Future<void> cancelStream(String chatId) async {
    final activeStream = activeStreams[chatId];
    if (activeStream != null) {
      activeStream.cancelIdleTimer();
      await activeStream.subscription.cancel();
      activeStreams.remove(chatId);
      if (kDebugMode) {
        debugPrint('Cancelled stream for chat $chatId');
      }
    }
  }

  /// Cancel all active streams
  Future<void> cancelAllStreams() async {
    final chatIds = activeStreams.keys.toList();
    for (final chatId in chatIds) {
      await cancelStream(chatId);
    }
    // Ensure any background service is stopped
    final pending = onAllStreamsCancelled();
    if (pending != null) await pending;
  }

  @protected
  void cleanupStream(String chatId) {
    final stream = activeStreams.remove(chatId);
    stream?.cancelIdleTimer();
    stream?.cancelUiThrottle();
    stopBackgroundServiceIfIdle();
  }

  /// Mark a stream as completed but keep its buffered content available.
  /// Used when a stream finishes naturally (DoneEvent / onDone) so that
  /// the UI can still retrieve the final content when the user switches
  /// back to this chat.
  @protected
  void completeStream(String chatId) {
    final stream = activeStreams[chatId];
    if (stream != null) {
      final contentLen = stream.contentBuffer.length;
      final reasoningLen = stream.reasoningBuffer.length;
      stream.isActive = false;
      stream.completedAt = DateTime.now();
      stream.cancelIdleTimer();
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
    evictStaleCompletedStreams();
    stopBackgroundServiceIfIdle();
  }

  @protected
  void evictStaleCompletedStreams() {
    final now = DateTime.now();
    final staleIds = <String>[];
    int completedCount = 0;

    for (final entry in activeStreams.entries) {
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
      activeStreams.remove(id);
      if (kDebugMode) {
        debugPrint('[StreamingManager] Evicted stale completed stream: $id');
      }
    }

    // If still over max, remove oldest completed streams
    if (completedCount - staleIds.length > _maxCompletedStreams) {
      final completedEntries =
          activeStreams.entries
              .where((e) => !e.value.isActive && e.value.completedAt != null)
              .toList()
            ..sort(
              (a, b) => a.value.completedAt!.compareTo(b.value.completedAt!),
            );

      final toRemove = completedEntries.length - _maxCompletedStreams;
      for (int i = 0; i < toRemove; i++) {
        activeStreams.remove(completedEntries[i].key);
      }
    }
  }

  /// Handle stream events asynchronously to allow awaiting notifications
  @protected
  Future<void> handleStreamEvent({
    required String chatId,
    required ChatStreamEvent event,
    required Function(String content, String reasoning) onUpdate,
    required Function(String content, String reasoning, double? tps) onComplete,
    required StreamErrorCallback onError,
  }) async {
    final activeStream = activeStreams[chatId];
    if (activeStream == null || !activeStream.isActive) return;

    activeStream.phase = switch (event) {
      // An empty delta is not a token: some servers send one to keep the
      // connection open, and calling that "thinking" or "writing" would name
      // a phase the model has not reached.
      ReasoningEvent(:final text) when text.isNotEmpty => StreamPhase.thinking,
      ContentEvent(:final text) when text.isNotEmpty => StreamPhase.writing,
      // A frame that carries no token says only that the connection stands.
      _ =>
        activeStream.phase == StreamPhase.connecting
            ? StreamPhase.processing
            : activeStream.phase,
    };

    // First-event stamp, idle-timer reset and TTFT measurement (io only).
    onEventBookkeeping(
      chatId: chatId,
      stream: activeStream,
      event: event,
      onComplete: onComplete,
      onError: onError,
    );

    if (event is ContentEvent) {
      activeStream.contentBuffer.write(event.text);
      deliverUpdate(activeStream, onUpdate);
    } else if (event is ReasoningEvent) {
      activeStream.reasoningBuffer.write(event.text);
      deliverUpdate(activeStream, onUpdate);
    } else if (event is TpsEvent) {
      // Store TPS metric for later use in onComplete
      activeStream.tps = event.tokensPerSecond;
    } else if (event is ToolCallsEvent) {
      // Native tool calls, assembled server-side. Collected here and read by
      // the tool loop after completion via getNativeToolCalls.
      activeStream.nativeToolCalls.addAll(event.calls);
    } else if (event is MetaEvent) {
      activeStream.latestMeta = Map<String, dynamic>.from(event.meta);
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
      cleanupStream(chatId);
      onError(event.message, code: event.code);
    } else if (event is DoneEvent) {
      // Handle done events from the stream (successful completion)
      if (kDebugMode) {
        debugPrint('Stream DoneEvent for chat $chatId');
      }
      final finalContent = activeStream.contentBuffer.toString();
      final finalReasoning = activeStream.reasoningBuffer.toString();
      final tps = activeStream.tps;

      // On io: mark inactive BEFORE awaiting so a concurrently-scheduled
      // `handleStreamClose` (fired by the listener's onDone right
      // after this event in the multiplex path) early-returns and
      // does not double-fire onComplete. Two onCompletes would each
      // recursively launch the next tool-loop pass, and both passes
      // would write into the same UI message buffer — that is the
      // root cause of the v1.0.96 character-by-character interleave
      // exposed by the /v2/ws multiplex landing (DoneEvent + onDone
      // arrive synchronously in the multiplex demuxer).
      beforeCompletion(activeStream);

      // Show completion notification if app is in background
      // IMPORTANT: Await this before cleanup so foreground service stops AFTER
      final notification = completionNotification(
        chatId: chatId,
        stream: activeStream,
        contentPreview: finalContent,
      );
      if (notification != null) await notification;

      onComplete(finalContent, finalReasoning, tps);
      // Keep completed stream data available for chat reload —
      // don't remove from map, just record the completion timestamp.
      completeStream(chatId);
    }
    // UsageEvent is ignored (just logging)
  }

  /// Handle stream close asynchronously
  @protected
  Future<void> handleStreamClose({
    required String chatId,
    required Function(String content, String reasoning, double? tps) onComplete,
  }) async {
    // Stream closed - if we haven't completed via DoneEvent, complete now
    final activeStream = activeStreams[chatId];
    if (activeStream == null || !activeStream.isActive) return;

    if (kDebugMode) {
      debugPrint('Stream subscription closed for chat $chatId');
    }
    final finalContent = activeStream.contentBuffer.toString();
    final finalReasoning = activeStream.reasoningBuffer.toString();
    final tps = activeStream.tps;

    // On io: mark inactive BEFORE awaiting so we cannot race a concurrent
    // DoneEvent handler into firing onComplete twice (see the
    // matching note in handleStreamEvent above).
    beforeCompletion(activeStream);

    // Show completion notification if app is in background
    // IMPORTANT: Await this before cleanup so foreground service stops AFTER
    final notification = completionNotification(
      chatId: chatId,
      stream: activeStream,
      contentPreview: finalContent,
    );
    if (notification != null) await notification;

    // Always call onComplete - handler will show "empty response" message if needed
    // This ensures UI state is properly reset even for reasoning-only streams
    onComplete(finalContent, finalReasoning, tps);

    // Keep completed stream data available for chat reload
    completeStream(chatId);
  }

  /// Called when app lifecycle changes - manages the foreground service on
  /// platforms that have one.
  void onAppLifecycleChanged({required bool isInBackground}) {
    _isAppInBackground = isInBackground;
    onAppBackgroundChanged(isInBackground);
  }

  // ---------------------------------------------------------------------------
  // Buffered-content accessors
  // ---------------------------------------------------------------------------

  /// Get info about active streams (for debugging)
  Map<String, bool> getActiveStreamsInfo() {
    return Map.fromEntries(
      activeStreams.entries.map((e) => MapEntry(e.key, e.value.isActive)),
    );
  }

  /// Get the current buffered content for a chat (active or completed).
  /// Returns null if chat has no stream entry.
  String? getBufferedContent(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null) return null;

    final content = stream.contentBuffer.toString();
    return content.isEmpty ? null : content;
  }

  /// Get the current buffered reasoning for a chat (active or completed).
  /// Returns null if chat has no stream entry.
  String? getBufferedReasoning(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null) return null;

    final reasoning = stream.reasoningBuffer.toString();
    return reasoning.isEmpty ? null : reasoning;
  }

  /// Get the message index being streamed for a chat (active or completed).
  /// Returns null if chat has no stream entry.
  int? getStreamingMessageIndex(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null) return null;
    return stream.messageIndex;
  }

  /// Get the TPS (tokens per second) for a streaming chat
  /// Returns null if chat is not streaming or TPS not yet received
  double? getTps(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null || !stream.isActive) return null;
    return stream.tps;
  }

  /// Get the latest stream metadata for a chat (active or completed).
  /// Returns null if no metadata was received.
  Map<String, dynamic>? getLatestMeta(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null || stream.latestMeta == null) return null;
    return Map<String, dynamic>.from(stream.latestMeta!);
  }

  /// Native tool calls the model requested on the just-completed pass, read by
  /// the tool loop in onComplete. Empty when the turn produced no tool calls.
  List<NativeToolCall> getNativeToolCalls(String chatId) {
    final stream = activeStreams[chatId];
    if (stream == null) return const <NativeToolCall>[];
    return List<NativeToolCall>.from(stream.nativeToolCalls);
  }

  /// Check if a chat has a completed stream with buffered content
  /// that hasn't been consumed yet.
  bool hasCompletedStream(String chatId) {
    final stream = activeStreams[chatId];
    return stream != null && !stream.isActive;
  }

  /// Remove a completed stream entry after its content has been consumed.
  /// Call this after applying the buffered content to the UI.
  void consumeCompletedStream(String chatId) {
    final stream = activeStreams[chatId];
    if (stream != null && !stream.isActive) {
      activeStreams.remove(chatId);
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
  /// in `handleStreamEvent` before `onComplete` runs.
  void setBackgroundMessages(
    String chatId,
    List<Map<String, dynamic>> messages, {
    String? modelId,
    String? provider,
  }) {
    final stream = activeStreams[chatId];
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
    final stream = activeStreams[chatId];
    if (stream == null || stream.backgroundMessages == null) {
      return null;
    }

    // Return copy with current buffer content applied to the AI placeholder
    final messages = stream.backgroundMessages!
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (stream.messageIndex < messages.length) {
      final rawContent = stream.contentBuffer.toString();
      messages[stream.messageIndex]['text'] = contentForSnapshot(rawContent);
      messages[stream.messageIndex]['reasoning'] = stream.reasoningBuffer
          .toString();
    }
    return messages;
  }

  /// Check if a chat has background messages stored.
  /// True for both active and completed-but-not-yet-consumed streams.
  bool hasBackgroundMessages(String chatId) {
    final stream = activeStreams[chatId];
    return stream != null && stream.backgroundMessages != null;
  }
}

/// One tracked stream: its subscription, buffers and bookkeeping.
class ActiveStream {
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
  /// [StreamingManagerBase.getNativeToolCalls]; empty for a plain text turn.
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

  // Idle timer: fires when no events arrive for too long.
  // Reset on every incoming event. If it fires, the stream is
  // considered dead and will be cleaned up with an error.
  Timer? idleTimer;

  // UI-update coalescing: holds the timer that flushes the latest buffer to
  // the UI at most once per the platform's UI-update interval, plus whether a
  // token has arrived since the last flush.
  Timer? uiThrottleTimer;
  bool uiUpdatePending = false;

  // Background message storage for when user switches away during streaming
  List<Map<String, dynamic>>? backgroundMessages;
  String? modelId;
  String? provider;

  ActiveStream({
    required this.subscription,
    required this.messageIndex,
    required this.chatId,
    this.chatTitle,
  });

  void cancelIdleTimer() {
    idleTimer?.cancel();
    idleTimer = null;
  }

  void cancelUiThrottle() {
    uiThrottleTimer?.cancel();
    uiThrottleTimer = null;
    uiUpdatePending = false;
  }
}
