// COWORK STUB. Upstream: chuk_chat/lib/services/streaming_chat_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay — the SSE path to the hosted API does not exist in
// CoWork. Only the exception type survives: streaming_manager_io.dart,
// streaming_manager_stub.dart and utils/stream_error_sanitizer.dart test for it.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:cowork/models/chat_stream_event.dart';

/// Service for handling streaming chat responses with Server-Sent Events (SSE).
class StreamingChatService {
  /// Not reachable in CoWork: every send goes through the relay adapter in
  /// [WebSocketChatService].
  static Stream<ChatStreamEvent> sendStreamingChat({
    required String accessToken,
    required String message,
    required String modelId,
    required String providerSlug,
    List<Map<String, String>>? history,
    String? systemPrompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) {
    return Stream<ChatStreamEvent>.error(
      const StreamingChatException('SSE streaming is not used in CoWork.'),
    );
  }
}

/// Exception thrown when streaming chat fails.
class StreamingChatException implements Exception {
  final String message;
  final int? statusCode;

  const StreamingChatException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
