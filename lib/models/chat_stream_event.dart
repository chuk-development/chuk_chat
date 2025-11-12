/// Events that can be received from chat streaming services.
///
/// This sealed class represents all possible events that can occur during
/// a streaming chat session, whether over HTTP streaming or WebSocket.
///
/// Used by:
/// - `StreamingChatService` (HTTP streaming)
/// - `WebSocketChatService` (WebSocket streaming)
/// - `StreamingManager` (unified interface)
sealed class ChatStreamEvent {
  const ChatStreamEvent();

  const factory ChatStreamEvent.content(String text) = ContentEvent;
  const factory ChatStreamEvent.reasoning(String text) = ReasoningEvent;
  const factory ChatStreamEvent.usage(Map<String, dynamic> usage) = UsageEvent;
  const factory ChatStreamEvent.meta(Map<String, dynamic> meta) = MetaEvent;
  const factory ChatStreamEvent.error(String message) = ErrorEvent;
  const factory ChatStreamEvent.done() = DoneEvent;
}

/// Event containing message content text.
class ContentEvent extends ChatStreamEvent {
  final String text;
  const ContentEvent(this.text);
}

/// Event containing reasoning/thinking process text.
class ReasoningEvent extends ChatStreamEvent {
  final String text;
  const ReasoningEvent(this.text);
}

/// Event containing token usage information.
class UsageEvent extends ChatStreamEvent {
  final Map<String, dynamic> usage;
  const UsageEvent(this.usage);
}

/// Event containing metadata about the response.
class MetaEvent extends ChatStreamEvent {
  final Map<String, dynamic> meta;
  const MetaEvent(this.meta);
}

/// Event indicating an error occurred.
class ErrorEvent extends ChatStreamEvent {
  final String message;
  const ErrorEvent(this.message);
}

/// Event indicating the stream has completed.
class DoneEvent extends ChatStreamEvent {
  const DoneEvent();
}
