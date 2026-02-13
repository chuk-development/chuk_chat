import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/secure_token_handler.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';

/// Service for handling streaming chat responses via WebSocket.
/// WebSocket provides better reliability than HTTP streaming,
/// especially on mobile devices when the app is backgrounded.
class WebSocketChatService {
  /// Timeout for establishing the WebSocket connection.
  static const _connectionTimeout = Duration(seconds: 15);

  /// Timeout for receiving the first response chunk after sending a message.
  /// This covers the "thinking" phase where the model is processing.
  static const _firstChunkTimeout = Duration(seconds: 120);

  // Inter-chunk timeout (60s) is handled by StreamingManager's idle timer.

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
  ///
  /// Timeouts:
  /// - Connection: [_connectionTimeout] (15s)
  /// - First chunk: [_firstChunkTimeout] (120s) — covers model "thinking" time
  /// - Between chunks: 60s via StreamingManager idle timer — detects dead connections
  static Stream<ChatStreamEvent> sendStreamingChat({
    required String accessToken,
    required String message,
    required String modelId,
    required String providerSlug,
    List<Map<String, dynamic>>? history,
    String? systemPrompt,
    int maxTokens = 512,
    double temperature = 0.7,
    List<String>? images,
  }) async* {
    WebSocketChannel? channel;

    try {
      // Validate token before use
      final tokenError = SecureTokenHandler.validateTokenForRequest(
        accessToken,
        context: 'WebSocket chat',
      );
      if (tokenError != null) {
        yield ChatStreamEvent.error(tokenError);
        return;
      }

      final wsUrl = _wsBaseUrl.replace(path: '/v1/ai/chat/ws');

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
        debugPrint(
          '  - System Prompt: ${systemPrompt != null ? '${systemPrompt.length} chars' : 'none'}',
        );
      }

      // Connect to WebSocket with connection timeout
      channel = WebSocketChannel.connect(wsUrl);
      try {
        await channel.ready.timeout(_connectionTimeout);
      } on TimeoutException {
        yield ChatStreamEvent.error(
          'Connection timed out after ${_connectionTimeout.inSeconds}s. '
          'Please check your internet connection and try again.',
        );
        return;
      }

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

      // Convert image storage paths to Base64 data URLs on-the-fly
      if (images != null && images.isNotEmpty) {
        final base64Images = await _convertImagesToBase64(images);
        if (base64Images.isNotEmpty) {
          requestPayload['images'] = base64Images;
          if (kDebugMode) {
            debugPrint('🖼️ Converted ${base64Images.length} images to Base64');
          }
        }
      }

      // Send the request
      channel.sink.add(jsonEncode(requestPayload));

      if (kDebugMode) {
        debugPrint('📤 Request sent via WebSocket');
      }

      // Listen for responses with a generous timeout to cover the initial
      // model thinking time. The StreamingManager's idle timer
      // (see streaming_manager_io.dart) provides a separate, shorter
      // inter-chunk timeout once the first chunk has arrived.
      bool receivedFirstChunk = false;

      await for (final message in channel.stream.timeout(
        _firstChunkTimeout,
        onTimeout: (sink) {
          // No data received within the timeout window — close the sink
          // to break out of the await-for loop.
          sink.close();
        },
      )) {
        receivedFirstChunk = true;

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
                debugPrint(
                  '═══════════════════════════════════════════════════════════',
                );
                debugPrint('✅ WEBSOCKET STREAM COMPLETED');
                debugPrint('Provider: $providerSlug');
                debugPrint('Model: $modelId');
                debugPrint(
                  '═══════════════════════════════════════════════════════════',
                );
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
              yield ChatStreamEvent.meta(data['meta'] as Map<String, dynamic>);
            } else if (data.containsKey('tps')) {
              yield ChatStreamEvent.tps((data['tps'] as num).toDouble());
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to parse WebSocket message: $message');
              debugPrint('Error: $e');
            }
          }
        }
      }

      // If we never received any chunk, the timeout triggered
      if (!receivedFirstChunk) {
        yield ChatStreamEvent.error(
          'No response received after ${_firstChunkTimeout.inSeconds}s. '
          'The server may be overloaded — please try again.',
        );
      }
    } on WebSocketChannelException catch (e) {
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        debugPrint('❌ WEBSOCKET ERROR');
        debugPrint('Provider: $providerSlug');
        debugPrint('Model: $modelId');
        debugPrint('Error: $e');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }
      throw WebSocketChatException('WebSocket connection failed: $e');
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        debugPrint('❌ WEBSOCKET ERROR');
        debugPrint('Provider: $providerSlug');
        debugPrint('Model: $modelId');
        debugPrint('Error: $e');
        debugPrint('Stack Trace: $stackTrace');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }
      throw WebSocketChatException('WebSocket streaming failed: $e');
    } finally {
      await channel?.sink.close();
      if (kDebugMode) {
        debugPrint('🧹 WebSocket closed and resources cleaned up');
      }
    }
  }

  /// Convert image storage paths or existing Base64 URLs to Base64 data URLs.
  /// This is called on-the-fly when sending to AI - images are NOT stored as Base64.
  static Future<List<String>> _convertImagesToBase64(
    List<String> imagePaths,
  ) async {
    final base64Images = <String>[];

    for (final path in imagePaths) {
      try {
        // Check if already a Base64 data URL (legacy support)
        if (path.startsWith('data:image/')) {
          base64Images.add(path);
          continue;
        }

        // Storage path - download, decrypt, and convert to Base64
        final bytes = await ImageStorageService.downloadAndDecryptImage(path);
        final base64 = base64Encode(bytes);
        base64Images.add('data:image/jpeg;base64,$base64');
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ Failed to convert image to Base64: $path - $e');
        }
        // Skip failed images
      }
    }

    return base64Images;
  }
}

/// Exception thrown when WebSocket chat fails.
class WebSocketChatException implements Exception {
  final String message;

  const WebSocketChatException(this.message);

  @override
  String toString() => message;
}
