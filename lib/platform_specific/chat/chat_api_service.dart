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
