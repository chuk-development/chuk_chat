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
}
