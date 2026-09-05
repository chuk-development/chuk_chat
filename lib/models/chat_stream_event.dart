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
  const factory ChatStreamEvent.tps(double tokensPerSecond) = TpsEvent;
  const factory ChatStreamEvent.toolCalls(List<NativeToolCall> calls) =
      ToolCallsEvent;
  const factory ChatStreamEvent.error(String message, {String? code}) =
      ErrorEvent;
  const factory ChatStreamEvent.done() = DoneEvent;
}

/// A native OpenAI-format tool call assembled from the provider stream.
///
/// The backend accumulates the streamed `delta.tool_calls` fragments (id/name
/// arrive once, `arguments` in pieces) and relays complete calls in one frame.
/// [arguments] is the raw JSON string exactly as assembled — parse it
/// defensively, providers occasionally emit malformed or truncated JSON.
class NativeToolCall {
  final String id;
  final String name;
  final String arguments;

  const NativeToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory NativeToolCall.fromJson(Map<String, dynamic> json) {
    final fn = json['function'];
    final fnMap = fn is Map ? fn : const <dynamic, dynamic>{};
    return NativeToolCall(
      id: (json['id'] ?? '').toString(),
      name: (fnMap['name'] ?? '').toString(),
      arguments: (fnMap['arguments'] ?? '').toString(),
    );
  }
}

/// Event carrying one or more native tool calls the model requested this turn.
class ToolCallsEvent extends ChatStreamEvent {
  final List<NativeToolCall> calls;
  const ToolCallsEvent(this.calls);
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

/// Event containing tokens per second (TPS) metric.
class TpsEvent extends ChatStreamEvent {
  final double tokensPerSecond;
  const TpsEvent(this.tokensPerSecond);
}

/// Event indicating an error occurred.
class ErrorEvent extends ChatStreamEvent {
  /// Human-readable text. Safe to show, useless to branch on — the server
  /// sends the same sentence for several unrelated failure classes.
  final String message;

  /// Machine-readable failure class from the server (`upstream_network`,
  /// `upstream_status`, `upstream_no_stream`, `cache_miss`, …).
  ///
  /// This is what retry decisions must key off. Classifying by [message]
  /// substrings breaks the moment the wording or the language changes, and
  /// it cannot tell a transient stall from a flat rejection. Null for errors
  /// raised locally rather than by the server.
  final String? code;

  const ErrorEvent(this.message, {this.code});
}

/// Event indicating the stream has completed.
class DoneEvent extends ChatStreamEvent {
  const DoneEvent();
}

/// Signature for stream error callbacks.
///
/// [code] is [ErrorEvent.code] where the failure came from the server, and
/// null for locally raised errors. Retry logic must branch on it rather than
/// on the text of [error].
typedef StreamErrorCallback = void Function(String error, {String? code});

/// Failure classes carried on [ErrorEvent.code].
///
/// The server emits the first group; the client raises the second. Both exist
/// so a retry decision is a set lookup instead of a guess at what English
/// sentence the backend happened to send.
abstract final class StreamErrorCodes {
  /// Server ⇄ provider network failure. The server already retried with
  /// backoff and provider fallback before giving up.
  static const String upstreamNetwork = 'upstream_network';

  /// The provider *rejected* the request (e.g. 400/413 on an oversized
  /// payload). Deterministic — the identical request fails the same way.
  static const String upstreamStatus = 'upstream_status';

  /// Provider returned 200 headers and then never sent a body token.
  static const String upstreamNoStream = 'upstream_no_stream';
  static const String upstreamFirstByteTimeout = 'upstream_first_byte_timeout';

  /// The WebSocket died with the request in flight.
  static const String connectionLost = 'connection_lost';

  /// No event arrived within the client's idle window.
  static const String idleTimeout = 'idle_timeout';

  /// The event stream itself raised.
  static const String streamFailure = 'stream_failure';

  /// Failures worth re-issuing the pass for.
  ///
  /// [upstreamStatus] is deliberately absent: a rejection is not transient,
  /// so retrying burns tokens and the user's time for a guaranteed repeat.
  /// The stall and network classes are in — the server exhausted *its*
  /// options against one provider pin, and a fresh request is routed anew.
  static const Set<String> retryable = <String>{
    upstreamNetwork,
    upstreamNoStream,
    upstreamFirstByteTimeout,
    connectionLost,
    idleTimeout,
    streamFailure,
  };
}
