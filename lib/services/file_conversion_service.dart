import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/utils/file_upload_validator.dart';
import 'package:chuk_chat/utils/upload_rate_limiter.dart';
import 'package:chuk_chat/utils/secure_token_handler.dart';

/// Service for converting files to markdown using the /ai/convert-file endpoint.
/// Supports documents, images (with EXIF/OCR), audio (with transcription),
/// archives, e-books, and email files.
class FileConversionService {
  static String get _apiBaseUrl => ApiConfigService.apiBaseUrl;

  /// Supported file extensions grouped by category
  static const Set<String> supportedExtensions = {
    // Documents
    'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx',
    'odt', 'ods', 'odp', 'odg', 'odf',
    // Text
    'csv', 'json', 'jsonl', 'xml', 'html', 'htm', 'md', 'markdown',
    'txt', 'text',
    // Images (with EXIF and OCR)
    'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tiff', 'tif', 'webp',
    // Audio (with transcription)
    'wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg',
    // Archives
    'zip',
    // E-books
    'epub',
    // Email
    'msg', 'eml',
    // Code and other text formats
    'py', 'js', 'ts', 'jsx', 'tsx', 'java', 'c', 'cpp', 'h', 'hpp',
    'go', 'rs', 'rb', 'php', 'swift', 'kt', 'cs', 'sh', 'bash',
    'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf',
    'sql', 'prisma', 'graphql', 'proto',
    'css', 'scss', 'sass', 'less',
    'vue', 'svelte',
    'ipynb', 'rss', 'atom',
  };

  /// Convert a file to markdown using the /ai/convert-file endpoint.
  ///
  /// Returns a map with:
  /// - 'markdown': The markdown content string
  /// - 'success': Boolean indicating if conversion succeeded
  /// - 'error': Error message if conversion failed (null on success)
  static Future<Map<String, dynamic>> convertFile({
    required String filePath,
    required String accessToken,
    String? userId,
  }) async {
    try {
      final file = File(filePath);

      if (!await file.exists()) {
        return {
          'success': false,
          'error': 'File not found: $filePath',
          'markdown': null,
        };
      }

      // Rate limiting check (if userId provided)
      if (userId != null) {
        final rateLimiter = UploadRateLimiter();
        if (!rateLimiter.isUploadAllowed(userId)) {
          final timeUntilReset = rateLimiter.getTimeUntilReset(userId);
          final minutes = timeUntilReset != null ? (timeUntilReset / 60).ceil() : 5;
          return {
            'success': false,
            'error': 'Too many uploads. Please wait $minutes minute(s) before trying again.',
            'markdown': null,
          };
        }
      }

      // Validate file before upload (size, MIME type, archive content)
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('🔒 VALIDATING FILE UPLOAD');
      debugPrint('File: ${file.path.split('/').last}');
      debugPrint('═══════════════════════════════════════════════════════════');

      final validationResult = await FileUploadValidator.validateFile(filePath);

      if (!validationResult.isValid) {
        debugPrint('❌ VALIDATION FAILED: ${validationResult.errorMessage}');
        return {
          'success': false,
          'error': validationResult.errorMessage ?? 'File validation failed',
          'markdown': null,
        };
      }

      debugPrint('✅ VALIDATION PASSED');
      if (validationResult.fileSizeBytes != null) {
        debugPrint('File size: ${FileUploadValidator.formatFileSize(validationResult.fileSizeBytes!)}');
      }
      if (validationResult.mimeType != null) {
        debugPrint('MIME type: ${validationResult.mimeType}');
      }
      debugPrint('═══════════════════════════════════════════════════════════');

      // Record upload attempt for rate limiting
      if (userId != null) {
        UploadRateLimiter().recordUpload(userId);
      }

      final fileName = file.path.split('/').last;
      final fileExtension = fileName.split('.').last.toLowerCase();

      if (!supportedExtensions.contains(fileExtension)) {
        return {
          'success': false,
          'error': 'Unsupported file type: .$fileExtension',
          'markdown': null,
        };
      }

      // Validate token before use
      final tokenError = SecureTokenHandler.validateTokenForRequest(accessToken, context: 'File conversion');
      if (tokenError != null) {
        return {
          'success': false,
          'error': tokenError,
          'markdown': null,
        };
      }

      // Create Dio instance with proper timeout settings for large files
      final dio = Dio(
        BaseOptions(
          baseUrl: _apiBaseUrl,
          headers: {
            'Authorization': 'Bearer $accessToken',
          },
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 5), // For large files
          sendTimeout: const Duration(minutes: 5),    // For large files
        ),
      );

      // Log request with masked token
      SecureTokenHandler.logApiRequest(
        endpoint: '$_apiBaseUrl/ai/convert-file',
        method: 'POST',
        accessToken: accessToken,
        payload: {'file': fileName},
      );

      // Create multipart form data
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          filePath,
          filename: fileName,
        ),
      });

      // Send the request
      final response = await dio.post(
        '/ai/convert-file',
        data: formData,
        onSendProgress: (sent, total) {
          if (total != -1 && kDebugMode) {
            final progress = (sent / total * 100).toStringAsFixed(0);
            debugPrint('Upload progress: $progress% ($sent/$total bytes)');
          }
        },
      );

      // Log success response
      SecureTokenHandler.logApiResponse(
        endpoint: '/ai/convert-file',
        statusCode: response.statusCode ?? 200,
        success: true,
      );

      // Extract markdown from response
      final markdown = response.data['markdown'] as String?;

      if (markdown == null || markdown.isEmpty) {
        return {
          'success': false,
          'error': 'No markdown content returned from API',
          'markdown': null,
        };
      }

      return {
        'success': true,
        'error': null,
        'markdown': markdown,
      };
    } on DioException catch (e) {
      String errorMessage = 'File conversion failed';

      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        errorMessage = 'Request timed out. The file may be too large.';
      } else if (e.response?.statusCode == 413) {
        errorMessage = 'File is too large (max 10MB)';
      } else if (e.response?.statusCode == 401) {
        errorMessage = 'Authentication failed. Please sign in again.';
      } else if (e.response?.statusCode == 415) {
        errorMessage = 'Unsupported file type';
      } else if (e.response != null) {
        errorMessage = 'Server error: ${e.response!.statusCode}';
        if (e.response!.data != null) {
          final data = e.response!.data;
          if (data is Map && data.containsKey('detail')) {
            errorMessage = SecureTokenHandler.createSafeErrorMessage(
              data['detail'].toString(),
              token: accessToken,
            );
          } else if (data is Map && data.containsKey('error')) {
            errorMessage = SecureTokenHandler.createSafeErrorMessage(
              data['error'].toString(),
              token: accessToken,
            );
          }
        }
      }

      // Log error with secure handling
      SecureTokenHandler.logApiResponse(
        endpoint: '/ai/convert-file',
        statusCode: e.response?.statusCode ?? 0,
        error: '${e.type}: $errorMessage',
        success: false,
      );

      return {
        'success': false,
        'error': errorMessage,
        'markdown': null,
      };
    } catch (e, stackTrace) {
      final errorMessage = 'Unexpected error: ${e.toString()}';

      // Log unexpected error with secure handling
      if (kDebugMode) {
        debugPrint('═══════════════════════════════════════════════════════════');
        debugPrint('❌ FILE CONVERSION ERROR (Unexpected)');
        debugPrint('File: ${filePath.split('/').last}');
        debugPrint('Error: $errorMessage');
        debugPrint('Stack Trace: $stackTrace');
        debugPrint('═══════════════════════════════════════════════════════════');
      }

      return {
        'success': false,
        'error': 'Unexpected error: ${e.toString()}',
        'markdown': null,
      };
    }
  }

  /// Check if a file extension is supported for conversion
  static bool isExtensionSupported(String extension) {
    return supportedExtensions.contains(extension.toLowerCase());
  }

  /// Get the category of a file extension (for display purposes)
  static String getFileCategory(String extension) {
    final ext = extension.toLowerCase();

    if ({'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'odt', 'ods', 'odp'}.contains(ext)) {
      return 'document';
    } else if ({'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tiff', 'tif', 'webp'}.contains(ext)) {
      return 'image';
    } else if ({'wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg'}.contains(ext)) {
      return 'audio';
    } else if ({'zip'}.contains(ext)) {
      return 'archive';
    } else if ({'epub'}.contains(ext)) {
      return 'ebook';
    } else if ({'msg', 'eml'}.contains(ext)) {
      return 'email';
    } else {
      return 'text';
    }
  }
}
