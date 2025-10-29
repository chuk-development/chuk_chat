import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';

/// Service for handling streaming chat responses with Server-Sent Events (SSE).
class StreamingChatService {
  static String get _apiBaseUrl => ApiConfigService.apiBaseUrl;

  /// Sends a streaming chat request and yields chunks as they arrive.
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
    http.Client? client;
    http.StreamedResponse? response;

    try {
      client = http.Client();

      final Map<String, dynamic> requestPayload = {
        'model_id': modelId,
        'message': message,
        'max_tokens': maxTokens.toString(),
        'temperature': temperature.toString(),
        'provider': providerSlug,
        'provider_slug': providerSlug,
        'metadata': jsonEncode({
          'source': 'flutter-chat-ui',
          'provider_slug': providerSlug,
        }),
      };

      if (history != null && history.isNotEmpty) {
        requestPayload['history'] = jsonEncode(history);
      }

      if (systemPrompt != null && systemPrompt.isNotEmpty) {
        requestPayload['system_prompt'] = systemPrompt;
      }

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_apiBaseUrl/ai/chat'),
      );

      request.headers['Authorization'] = 'Bearer $accessToken';
      request.headers['Accept'] = 'text/event-stream';

      requestPayload.forEach((key, value) {
        request.fields[key] = value.toString();
      });

      // Detailed request logging
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('📤 STREAMING CHAT REQUEST');
      debugPrint('Provider: $providerSlug');
      debugPrint('Model: $modelId');
      debugPrint('Endpoint: ${request.url}');
      debugPrint('───────────────────────────────────────────────────────────');
      debugPrint('Request Details:');
      debugPrint('  - Message Length: ${message.length} chars');
      debugPrint('  - Max Tokens: $maxTokens');
      debugPrint('  - Temperature: $temperature');
      debugPrint('  - History: ${history?.length ?? 0} messages');
      debugPrint('  - System Prompt: ${systemPrompt != null ? '${systemPrompt.length} chars' : 'none'}');
      debugPrint('  - Accept: text/event-stream');
      debugPrint('═══════════════════════════════════════════════════════════');

      response = await client.send(request);
      debugPrint('📥 Response Status: ${response.statusCode}');

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        debugPrint('❌ Request failed with status ${response.statusCode}');
        debugPrint('Error: $errorBody');
        throw StreamingChatException(
          'Server returned ${response.statusCode}: $errorBody',
          statusCode: response.statusCode,
        );
      }

      debugPrint('✅ Stream connected successfully');

      await for (final chunk
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (chunk.trim().isEmpty) continue;

        if (chunk.startsWith('data: ')) {
          final data = chunk.substring(6).trim();

          if (data == '[DONE]') {
            debugPrint('═══════════════════════════════════════════════════════════');
            debugPrint('✅ STREAM COMPLETED SUCCESSFULLY');
            debugPrint('Provider: $providerSlug');
            debugPrint('Model: $modelId');
            debugPrint('═══════════════════════════════════════════════════════════');
            yield const ChatStreamEvent.done();
            break;
          }

          try {
            final Map<String, dynamic> parsed = jsonDecode(data);

            if (parsed.containsKey('content')) {
              yield ChatStreamEvent.content(parsed['content'] as String);
            } else if (parsed.containsKey('reasoning')) {
              yield ChatStreamEvent.reasoning(parsed['reasoning'] as String);
            } else if (parsed.containsKey('usage')) {
              yield ChatStreamEvent.usage(
                parsed['usage'] as Map<String, dynamic>,
              );
            } else if (parsed.containsKey('meta')) {
              yield ChatStreamEvent.meta(
                parsed['meta'] as Map<String, dynamic>,
              );
            } else if (parsed.containsKey('error')) {
              yield ChatStreamEvent.error(parsed['error'].toString());
            }
          } catch (e) {
            debugPrint('Failed to parse SSE data: $data');
          }
        }
      }
    } on StreamingChatException {
      rethrow;
    } catch (e, stackTrace) {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('❌ STREAMING ERROR');
      debugPrint('Provider: $providerSlug');
      debugPrint('Model: $modelId');
      debugPrint('Error: $e');
      debugPrint('Stack Trace: $stackTrace');
      debugPrint('═══════════════════════════════════════════════════════════');
      throw StreamingChatException('Streaming failed: $e');
    } finally {
      client?.close();
      debugPrint('🧹 Stream resources cleaned up');
    }
  }
}

/// Events that can be received from the streaming chat.
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

/// Exception thrown when streaming chat fails.
class StreamingChatException implements Exception {
  final String message;
  final int? statusCode;

  const StreamingChatException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
