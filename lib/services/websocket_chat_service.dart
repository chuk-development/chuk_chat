import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/utils/secure_token_handler.dart';

/// Service for handling streaming chat responses via WebSocket.
/// WebSocket provides better reliability than HTTP streaming,
/// especially on mobile devices when the app is backgrounded.
class WebSocketChatService {
  static Uri get _wsBaseUrl {
    final httpUrl = ApiConfigService.apiBaseUrl;
    final uri = Uri.parse(httpUrl);

    // Convert HTTP(S) scheme to WS(S) scheme
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';

    return Uri(
      scheme: wsScheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path.isEmpty ? '/' : uri.path,
    );
  }

  /// Sends a streaming chat request via WebSocket and yields chunks as they arrive.
  ///
  /// WebSocket advantages over HTTP streaming:
  /// - Persistent connection survives app backgrounding
  /// - Bidirectional communication
  /// - Lower latency
  /// - Better mobile battery efficiency
  static Stream<ChatStreamEvent> sendStreamingChat({
    required String accessToken,
    required String message,
    required String modelId,
    required String providerSlug,
    List<Map<String, String>>? history,
    String? systemPrompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async* {
    WebSocketChannel? channel;

    try {
      // Validate token before use
      final tokenError = SecureTokenHandler.validateTokenForRequest(accessToken, context: 'WebSocket chat');
      if (tokenError != null) {
        yield ChatStreamEvent.error(tokenError);
        return;
      }

      final wsUrl = _wsBaseUrl.replace(path: '/ai/chat/ws');

      // Log WebSocket connection with masked token
      SecureTokenHandler.logWebSocketConnection(
        url: wsUrl.toString(),
        accessToken: accessToken,
      );

      if (kDebugMode) {
        debugPrint('Request Details:');
        debugPrint('  - Provider: $providerSlug');
        debugPrint('  - Model: $modelId');
        debugPrint('  - Message Length: ${message.length} chars');
        debugPrint('  - Max Tokens: $maxTokens');
        debugPrint('  - Temperature: $temperature');
        debugPrint('  - History: ${history?.length ?? 0} messages');
        debugPrint('  - System Prompt: ${systemPrompt != null ? '${systemPrompt.length} chars' : 'none'}');
      }

      // Connect to WebSocket
      channel = WebSocketChannel.connect(wsUrl);
      await channel.ready;

      if (kDebugMode) {
        debugPrint('✅ WebSocket connected');
      }

      // Prepare the request payload
      final requestPayload = {
        'token': accessToken,
        'message': message,
        'model_id': modelId,
        'provider_slug': providerSlug,
        'max_tokens': maxTokens,
        'temperature': temperature,
      };

      if (history != null && history.isNotEmpty) {
        requestPayload['history'] = history;
      }

      if (systemPrompt != null && systemPrompt.isNotEmpty) {
        requestPayload['system_prompt'] = systemPrompt;
      }

      // Send the request
      channel.sink.add(jsonEncode(requestPayload));

      if (kDebugMode) {
        debugPrint('📤 Request sent via WebSocket');
      }

      // Listen for responses
      await for (final message in channel.stream) {
        if (message is String) {
          try {
            final Map<String, dynamic> data = jsonDecode(message);

            if (data.containsKey('error')) {
              final errorMsg = SecureTokenHandler.createSafeErrorMessage(
                data['error'] as String,
                token: accessToken,
              );

              if (kDebugMode) {
                debugPrint('❌ WebSocket error: $errorMsg');
              }

              yield ChatStreamEvent.error(errorMsg);
              break;
            }

            if (data.containsKey('done') && data['done'] == true) {
              if (kDebugMode) {
                debugPrint('═══════════════════════════════════════════════════════════');
                debugPrint('✅ WEBSOCKET STREAM COMPLETED');
                debugPrint('Provider: $providerSlug');
                debugPrint('Model: $modelId');
                debugPrint('═══════════════════════════════════════════════════════════');
              }
              yield const ChatStreamEvent.done();
              break;
            }

            if (data.containsKey('content')) {
              yield ChatStreamEvent.content(data['content'] as String);
            } else if (data.containsKey('reasoning')) {
              yield ChatStreamEvent.reasoning(data['reasoning'] as String);
            } else if (data.containsKey('usage')) {
              yield ChatStreamEvent.usage(
                data['usage'] as Map<String, dynamic>,
              );
            } else if (data.containsKey('meta')) {
              yield ChatStreamEvent.meta(
                data['meta'] as Map<String, dynamic>,
              );
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to parse WebSocket message: $message');
              debugPrint('Error: $e');
            }
          }
        }
      }
    } on WebSocketChannelException catch (e) {
      if (kDebugMode) {
        debugPrint('═══════════════════════════════════════════════════════════');
        debugPrint('❌ WEBSOCKET ERROR');
        debugPrint('Provider: $providerSlug');
        debugPrint('Model: $modelId');
        debugPrint('Error: $e');
        debugPrint('═══════════════════════════════════════════════════════════');
      }
      throw WebSocketChatException('WebSocket connection failed: $e');
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('═══════════════════════════════════════════════════════════');
        debugPrint('❌ WEBSOCKET ERROR');
        debugPrint('Provider: $providerSlug');
        debugPrint('Model: $modelId');
        debugPrint('Error: $e');
        debugPrint('Stack Trace: $stackTrace');
        debugPrint('═══════════════════════════════════════════════════════════');
      }
      throw WebSocketChatException('WebSocket streaming failed: $e');
    } finally {
      await channel?.sink.close();
      if (kDebugMode) {
        debugPrint('🧹 WebSocket closed and resources cleaned up');
      }
    }
  }
}

/// Events that can be received from the WebSocket chat stream.
sealed class ChatStreamEvent {
  const ChatStreamEvent();

  const factory ChatStreamEvent.content(String text) = ContentEvent;
  const factory ChatStreamEvent.reasoning(String text) = ReasoningEvent;
  const factory ChatStreamEvent.usage(Map<String, dynamic> usage) = UsageEvent;
  const factory ChatStreamEvent.meta(Map<String, dynamic> meta) = MetaEvent;
  const factory ChatStreamEvent.error(String message) = ErrorEvent;
  const factory ChatStreamEvent.done() = DoneEvent;
}

class ContentEvent extends ChatStreamEvent {
  final String text;
  const ContentEvent(this.text);
}

class ReasoningEvent extends ChatStreamEvent {
  final String text;
  const ReasoningEvent(this.text);
}

class UsageEvent extends ChatStreamEvent {
  final Map<String, dynamic> usage;
  const UsageEvent(this.usage);
}

class MetaEvent extends ChatStreamEvent {
  final Map<String, dynamic> meta;
  const MetaEvent(this.meta);
}

class ErrorEvent extends ChatStreamEvent {
  final String message;
  const ErrorEvent(this.message);
}

class DoneEvent extends ChatStreamEvent {
  const DoneEvent();
}

/// Exception thrown when WebSocket chat fails.
class WebSocketChatException implements Exception {
  final String message;

  const WebSocketChatException(this.message);

  @override
  String toString() => message;
}
