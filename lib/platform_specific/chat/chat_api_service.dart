// lib/platform_specific/chat/chat_api_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/file_conversion_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// A service for handling chat-related API interactions,
/// such as file uploads.
class ChatApiService {
  /// Gets the API base URL from the configuration service.
  /// This URL is environment-aware and works across different platforms.
  static String get _apiBaseUrl => ApiConfigService.apiBaseUrl;

  // Callback for UI updates: (fileId, markdownContent, isUploading, snackBarMessage)
  final void Function(
    String fileId,
    String? markdownContent,
    bool isUploading,
    String? snackBarMessage,
  )?
  onUploadStatusUpdate;

  ChatApiService({this.onUploadStatusUpdate}) {
    // Log the current API configuration for debugging
    debugPrint('ChatApiService initialized with API URL: $_apiBaseUrl');
    debugPrint(
      'API Configuration: ${ApiConfigService.configurationDescription}',
    );
  }

  /// Uploads a file to the API and processes its content using the new
  /// /ai/convert-file endpoint. Reports status updates via the
  /// `onUploadStatusUpdate` callback.
  Future<void> performFileUpload(
    File file,
    String fileName,
    String fileId,
  ) async {
    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null || session.accessToken.isEmpty) {
      onUploadStatusUpdate?.call(
        fileId,
        null,
        false,
        'Session expired. Please sign in again before uploading.',
      );
      await SupabaseService.signOut();
      return;
    }
    final String accessToken = session.accessToken;

    // Report initial uploading state
    onUploadStatusUpdate?.call(fileId, null, true, null);

    try {
      // Use the new FileConversionService which supports more file types
      // and uses the /ai/convert-file endpoint with proper timeout handling
      final result = await FileConversionService.convertFile(
        filePath: file.path,
        accessToken: accessToken,
      );

      if (result['success'] == true) {
        onUploadStatusUpdate?.call(
          fileId,
          result['markdown'],
          false,
          null,
        );
        debugPrint(
          'File "$fileName" conversion successful. Markdown content received.',
        );
      } else {
        final errorMessage = result['error'] ?? 'Unknown conversion error';
        onUploadStatusUpdate?.call(
          fileId,
          null,
          false,
          'Failed to convert "$fileName": $errorMessage',
        );
        debugPrint('File conversion failed for "$fileName": $errorMessage');
      }
    } catch (e) {
      debugPrint('Unexpected error converting "$fileName": $e');
      onUploadStatusUpdate?.call(
        fileId,
        null,
        false,
        'Error converting "$fileName": ${e.toString()}',
      );
    }
  }

  Future<TranscriptionResult> transcribeAudioFile({
    required File file,
    required String accessToken,
    String? prompt,
    String? language,
    double? temperature,
  }) async {
    if (!await file.exists()) {
      throw const TranscriptionException(
        'Audio file not found. Please try recording again.',
      );
    }

    final Uri endpoint = Uri.parse('$_apiBaseUrl/protected/transcribe-audio');
    final http.MultipartRequest request =
        http.MultipartRequest('POST', endpoint)
          ..headers['Authorization'] = 'Bearer $accessToken'
          ..files.add(
            await http.MultipartFile.fromPath('audio_file', file.path),
          );

    if (prompt != null && prompt.isNotEmpty) {
      request.fields['prompt'] = prompt;
    }
    if (language != null && language.isNotEmpty) {
      request.fields['language'] = language;
    }
    if (temperature != null) {
      request.fields['temperature'] = temperature.toString();
    }

    try {
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );
      final http.Response response = await http.Response.fromStream(
        streamedResponse,
      );

      Map<String, dynamic>? decoded;
      if (response.body.isNotEmpty) {
        try {
          final dynamic parsed = jsonDecode(response.body);
          if (parsed is Map<String, dynamic>) {
            decoded = parsed.cast<String, dynamic>();
          }
        } catch (error) {
          debugPrint('Failed to decode transcription response: $error');
        }
      }

      if (response.statusCode == 200) {
        final String text = (decoded?['text'] as String?) ?? '';
        final dynamic metadataRaw = decoded?['x_groq'];
        final Map<String, dynamic>? metadata = metadataRaw is Map
            ? Map<String, dynamic>.from(metadataRaw)
            : null;
        return TranscriptionResult(text: text, metadata: metadata);
      }

      final String fallback =
          'Transcription failed with status ${response.statusCode}.';
      final String message = _messageFromErrorPayload(decoded) ?? fallback;
      throw TranscriptionException(message, statusCode: response.statusCode);
    } on TimeoutException {
      throw const TranscriptionException(
        'Transcription request timed out. Please try again.',
      );
    } on SocketException catch (error) {
      throw TranscriptionException('Network error: $error');
    } on http.ClientException catch (error) {
      throw TranscriptionException('Network error: $error');
    } catch (error) {
      if (error is TranscriptionException) rethrow;
      throw TranscriptionException('Unexpected error: $error');
    }
  }

  String? _messageFromErrorPayload(Map<String, dynamic>? payload) {
    if (payload == null || payload.isEmpty) return null;
    final dynamic detail = payload['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    if (detail is List && detail.isNotEmpty) {
      final dynamic first = detail.first;
      if (first is Map<String, dynamic>) {
        final dynamic msg = first['msg'];
        if (msg is String && msg.isNotEmpty) return msg;
      } else if (first is String && first.isNotEmpty) {
        return first;
      }
    }
    final dynamic message = payload['message'];
    if (message is String && message.isNotEmpty) return message;
    return null;
  }

  Future<ChatCompletionResult> requestChatCompletion({
    required Map<String, dynamic> payload,
    required String accessToken,
  }) async {
    final Uri endpoint = Uri.parse('$_apiBaseUrl/ai/chat');
    final client = http.Client();
    try {
      final request = http.MultipartRequest('POST', endpoint)
        ..headers.addAll({
          'Accept': 'text/event-stream',
          'Authorization': 'Bearer $accessToken',
        });

      payload.forEach((key, value) {
        if (value == null) return;
        if (value is List || value is Map) {
          request.fields[key] = jsonEncode(value);
        } else {
          request.fields[key] = value.toString();
        }
      });

      // Detailed request logging
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('📤 CHAT API REQUEST');
      debugPrint('Provider: ${payload['provider'] ?? 'N/A'}');
      debugPrint('Model ID: ${payload['model_id'] ?? payload['model'] ?? 'N/A'}');
      debugPrint('Endpoint: $_apiBaseUrl/ai/chat');
      debugPrint('───────────────────────────────────────────────────────────');
      debugPrint('Request Details:');
      debugPrint('  - Messages: ${payload['messages'] != null ? (payload['messages'] is List ? (payload['messages'] as List).length : 'N/A') : (payload['message'] != null ? '1' : '0')}');
      debugPrint('  - Max Tokens: ${payload['max_tokens'] ?? 'default'}');
      debugPrint('  - Temperature: ${payload['temperature'] ?? 'default'}');
      debugPrint('  - Stream: ${payload['stream'] ?? 'true'}');
      if (payload.containsKey('metadata')) {
        debugPrint('  - Metadata: ${payload['metadata']}');
      }
      debugPrint('═══════════════════════════════════════════════════════════');

      final http.StreamedResponse streamedResponse;
      try {
        streamedResponse = await client
            .send(request)
            .timeout(const Duration(seconds: 90));
      } on TimeoutException {
        throw ChatCompletionException(
          'Chat request timed out. Please try again.',
        );
      }

      debugPrint('📥 Response Status: ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode == 401) {
        final body = await streamedResponse.stream.bytesToString();
        final message =
            _messageFromErrorPayload(_tryDecodeJson(body)) ??
            'Session expired. Please sign in again.';
        debugPrint('❌ Authentication Error: $message');
        throw ChatCompletionAuthException(
          message,
          statusCode: streamedResponse.statusCode,
        );
      }

      if (streamedResponse.statusCode != 200) {
        final body = await streamedResponse.stream.bytesToString();
        final message =
            _messageFromErrorPayload(_tryDecodeJson(body)) ??
            'Chat request failed with status ${streamedResponse.statusCode}.';
        debugPrint('❌ Request Error: $message');
        throw ChatCompletionException(
          message,
          statusCode: streamedResponse.statusCode,
        );
      }

      debugPrint('✅ Streaming response started successfully');

      final StringBuffer remainder = StringBuffer();
      final StringBuffer contentBuffer = StringBuffer();
      final StringBuffer reasoningBuffer = StringBuffer();
      Map<String, dynamic>? usage;
      Map<String, dynamic>? meta;
      bool isDone = false;

      await for (final chunk in streamedResponse.stream.transform(
        utf8.decoder,
      )) {
        remainder.write(chunk);
        String current = remainder.toString();

        while (true) {
          final int separatorIndex = current.indexOf('\n\n');
          if (separatorIndex == -1) {
            remainder
              ..clear()
              ..write(current);
            break;
          }

          final String rawMessage = current.substring(0, separatorIndex);
          current = current.substring(separatorIndex + 2);
          final _SseEvent event = _parseSseEvent(rawMessage);

          if (event.data == '[DONE]') {
            isDone = true;
            continue;
          }

          switch (event.name) {
            case 'meta':
              meta = _coerceToMap(event.decodedData);
              break;
            case 'reasoning':
              final reasoningSegment = _extractText(event.decodedData);
              if (reasoningSegment.isNotEmpty) {
                reasoningBuffer.write(reasoningSegment);
              }
              break;
            case 'usage':
              usage = _coerceToMap(event.decodedData);
              break;
            case 'error':
              String errorMessage = _extractText(event.decodedData).trim();
              if (errorMessage.isEmpty) {
                errorMessage = 'The AI service reported an error.';
              }
              throw ChatCompletionException(errorMessage);
            case 'content':
            default:
              final contentSegment = _extractText(event.decodedData);
              if (contentSegment.isNotEmpty) {
                contentBuffer.write(contentSegment);
              }
              break;
          }
        }
      }

      if (!isDone) {
        debugPrint('⚠️  Chat SSE stream ended without a [DONE] marker.');
      }

      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('✅ CHAT COMPLETION SUCCESSFUL');
      debugPrint('Provider: ${payload['provider'] ?? 'N/A'}');
      debugPrint('Model ID: ${payload['model_id'] ?? payload['model'] ?? 'N/A'}');
      debugPrint('Content Length: ${contentBuffer.length} chars');
      if (reasoningBuffer.isNotEmpty) {
        debugPrint('Reasoning Length: ${reasoningBuffer.length} chars');
      }
      if (usage != null) {
        debugPrint('Usage: ${usage.toString()}');
      }
      debugPrint('═══════════════════════════════════════════════════════════');

      return ChatCompletionResult(
        content: contentBuffer.toString(),
        reasoning: reasoningBuffer.toString(),
        usage: usage,
        metadata: meta,
      );
    } finally {
      client.close();
    }
  }

  _SseEvent _parseSseEvent(String raw) {
    String? name;
    final List<String> dataLines = [];
    final lines = raw.split('\n');
    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.startsWith('event:')) {
        name = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trim());
      }
    }
    final data = dataLines.join('\n');
    return _SseEvent(name: name ?? 'message', data: data);
  }

  dynamic _tryDecodeJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _coerceToMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is String) {
      final decoded = _tryDecodeJson(value);
      return _coerceToMap(decoded);
    }
    return null;
  }

  String _extractText(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is Map<String, dynamic>) {
      final dynamic content =
          value['content'] ??
          value['text'] ??
          value['delta'] ??
          value['message'];
      return _extractText(content);
    }
    if (value is List) {
      return value.map(_extractText).join('');
    }
    return value.toString();
  }
}

class TranscriptionResult {
  const TranscriptionResult({required this.text, this.metadata});

  final String text;
  final Map<String, dynamic>? metadata;
}

class TranscriptionException implements Exception {
  const TranscriptionException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    if (statusCode != null) {
      return 'TranscriptionException($statusCode): $message';
    }
    return 'TranscriptionException: $message';
  }
}

class ChatCompletionResult {
  const ChatCompletionResult({
    required this.content,
    required this.reasoning,
    this.usage,
    this.metadata,
  });

  final String content;
  final String reasoning;
  final Map<String, dynamic>? usage;
  final Map<String, dynamic>? metadata;
}

class ChatCompletionException implements Exception {
  const ChatCompletionException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    if (statusCode != null) {
      return 'ChatCompletionException($statusCode): $message';
    }
    return 'ChatCompletionException: $message';
  }
}

class ChatCompletionAuthException extends ChatCompletionException {
  const ChatCompletionAuthException(super.message, {super.statusCode});
}

class _SseEvent {
  const _SseEvent({required this.name, required this.data});

  final String name;
  final String data;

  dynamic get decodedData => _decode();

  dynamic _decode() {
    if (data.isEmpty) return '';
    try {
      return jsonDecode(data);
    } catch (_) {
      return data;
    }
  }
}
