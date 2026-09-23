// lib/services/streaming_manager_stub.dart
// Web stub - the shared core from streaming_manager_base.dart with none of the
// platform hooks overridden: no notification/foreground service, no idle
// timeout, no UI-update throttle (the base defaults are the web behaviour).
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/streaming_manager_base.dart';

/// Manages multiple concurrent chat streams across different chats
/// Web stub - no notification/foreground service integration
class StreamingManager extends StreamingManagerBase {
  static final StreamingManager _instance = StreamingManager._internal();
  factory StreamingManager() => _instance;
  StreamingManager._internal();

  /// Native tool calls from the just-completed pass. The web transport does not
  /// use native tool calling, so this is always empty (text parsing applies).
  @override
  List<NativeToolCall> getNativeToolCalls(String chatId) =>
      const <NativeToolCall>[];

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
