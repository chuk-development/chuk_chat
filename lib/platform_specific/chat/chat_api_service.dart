// lib/platform_specific/chat/chat_api_service.dart
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io'; // Import for SocketException
import 'dart:async'; // Import for TimeoutException

/// A service for handling chat-related API interactions,
/// such as file uploads.
class ChatApiService {
  static const String _apiBaseUrl =
      'https://api.chuk.chat'; // Adjust if your server is elsewhere

  // Callback for UI updates: (fileId, markdownContent, isUploading, snackBarMessage)
  final void Function(
          String fileId, String? markdownContent, bool isUploading, String? snackBarMessage)?
      onUploadStatusUpdate;

  ChatApiService({this.onUploadStatusUpdate});

  /// Uploads a file to the API and processes its content.
  /// Reports status updates via the `onUploadStatusUpdate` callback.
  Future<void> performFileUpload(File file, String fileName, String fileId) async {
    const int maxRetries = 3;
    const Duration timeoutDuration = Duration(seconds: 30);
    int retryCount = 0;
    bool uploadSuccess = false;

    // Report initial uploading state
    onUploadStatusUpdate?.call(fileId, null, true, null);

    while (retryCount < maxRetries && !uploadSuccess) {
      try {
        var request = http.MultipartRequest(
          'POST',
          Uri.parse('$_apiBaseUrl/upload_file'),
        );
        request.files.add(await http.MultipartFile.fromPath('file', file.path));

        var streamedResponse = await request.send().timeout(timeoutDuration);
        var response = await http.Response.fromStream(streamedResponse);

        if (response.statusCode == 200) {
          final jsonResponse = json.decode(response.body);
          onUploadStatusUpdate?.call(
              fileId, jsonResponse['markdown_content'], false, null); // Success
          debugPrint(
            'File "$fileName" conversion successful. Markdown content received.',
          );
          uploadSuccess = true;
        } else {
          final errorBody = json.decode(response.body);
          onUploadStatusUpdate?.call(
            fileId,
            null,
            false,
            'Failed to upload "$fileName" (Status: ${response.statusCode}): ${errorBody['detail'] ?? response.reasonPhrase}',
          );
          debugPrint(
              'File upload failed for "$fileName" (Status: ${response.statusCode}): ${response.body}');
          break; // Exit retry loop for server errors
        }
      } catch (e) {
        debugPrint(
            'Upload attempt failed for "$fileName" (Attempt ${retryCount + 1}/$maxRetries): $e');
        retryCount++;

        if (retryCount >= maxRetries) {
          String errorMessage =
              'Error uploading "$fileName" after $maxRetries attempts.';
          if (e is TimeoutException) {
            errorMessage = 'Upload of "$fileName" timed out after $maxRetries attempts.';
          } else if (e is SocketException) {
            errorMessage = 'Network error uploading "$fileName" after $maxRetries attempts.';
          } else {
            errorMessage = 'Error uploading "$fileName" after $maxRetries attempts: $e';
          }
          onUploadStatusUpdate?.call(fileId, null, false, errorMessage); // Final failure
        } else {
          await Future.delayed(Duration(seconds: retryCount * 2));
        }
      }
    }
  }
}
