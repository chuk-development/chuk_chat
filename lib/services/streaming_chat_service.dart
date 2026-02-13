import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';

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
        Uri.parse('$_apiBaseUrl/v1/ai/chat'),
      );

      request.headers['Authorization'] = 'Bearer $accessToken';
      request.headers['Accept'] = 'text/event-stream';

      requestPayload.forEach((key, value) {
        request.fields[key] = value.toString();
      });

      // Privacy: Only log in debug mode
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        debugPrint('📤 STREAMING CHAT REQUEST');
        debugPrint('Provider: $providerSlug | Model: $modelId');
        debugPrint(
          'Message: ${message.length} chars | History: ${history?.length ?? 0}',
        );
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }

      response = await client.send(request);
      if (kDebugMode) {
        debugPrint('📥 Response Status: ${response.statusCode}');
      }

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        if (kDebugMode) {
          debugPrint('❌ Request failed with status ${response.statusCode}');
        }
        throw StreamingChatException(
          'Server returned ${response.statusCode}: $errorBody',
          statusCode: response.statusCode,
        );
      }

      if (kDebugMode) debugPrint('✅ Stream connected');

      await for (final chunk
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (chunk.trim().isEmpty) continue;

        if (chunk.startsWith('data: ')) {
          final data = chunk.substring(6).trim();

          if (data == '[DONE]') {
            if (kDebugMode) debugPrint('✅ Stream completed');
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
            } else if (parsed.containsKey('tps')) {
              yield ChatStreamEvent.tps((parsed['tps'] as num).toDouble());
            } else if (parsed.containsKey('error')) {
              yield ChatStreamEvent.error(parsed['error'].toString());
            }
          } catch (e) {
            // Privacy: Don't log raw SSE data in release
            if (kDebugMode) debugPrint('Failed to parse SSE data');
          }
        }
      }
    } on StreamingChatException {
      rethrow;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('❌ STREAMING ERROR: $e');
        debugPrint('Stack: $stackTrace');
      }
      throw StreamingChatException('Streaming failed: $e');
    } finally {
      client?.close();
    }
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
