import 'package:chuk_chat/utils/io_helper.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/utils/file_upload_validator.dart';
import 'package:chuk_chat/utils/upload_rate_limiter.dart';
import 'package:chuk_chat/utils/secure_token_handler.dart';
import 'package:chuk_chat/utils/api_rate_limiter.dart';
import 'package:chuk_chat/utils/certificate_pinning.dart';

/// Service for converting files to markdown using the /v1/ai/convert-file endpoint.
/// Supports documents, images (with EXIF/OCR), audio (with transcription),
/// archives, e-books, and email files.
///
/// Note: Plain text files (code, config, etc.) are handled directly by
/// ChatApiService and ProjectStorageService without using this API.
/// This service is only used for binary files (PDF, Office docs, audio, etc.)
class FileConversionService {
  static String get _apiBaseUrl => ApiConfigService.apiBaseUrl;

  /// Maximum tokens per file (40k tokens ≈ 160k characters at ~4 chars/token)
  static const int maxTokensPerFile = 40000;
  static const int maxCharsPerFile = 160000; // ~4 chars per token

  /// Convert a file to markdown using the /v1/ai/convert-file endpoint.
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

      // Upload rate limiting check (if userId provided)
      if (userId != null) {
        final uploadLimiter = UploadRateLimiter();
        if (!uploadLimiter.isUploadAllowed(userId)) {
          final timeUntilReset = uploadLimiter.getTimeUntilReset(userId);
          final minutes = timeUntilReset != null
              ? (timeUntilReset / 60).ceil()
              : 5;
          return {
            'success': false,
            'error':
                'Too many uploads. Please wait $minutes minute(s) before trying again.',
            'markdown': null,
          };
        }

        // API rate limiting check (general API throttling)
        final apiLimiter = ApiRateLimiter();
        final rateLimitResult = apiLimiter.checkRateLimit(
          endpoint: '/v1/ai/convert-file',
          userId: userId,
          config: RateLimitConfig.fileConversion,
        );

        if (!rateLimitResult.allowed) {
          return {
            'success': false,
            'error': rateLimitResult.errorMessage ?? 'Rate limit exceeded',
            'markdown': null,
          };
        }

        // Log rate limit status in debug mode
        apiLimiter.logRateLimitStatus(
          endpoint: '/v1/ai/convert-file',
          userId: userId,
          config: RateLimitConfig.fileConversion,
        );
      }

      // Validate file before upload (size, MIME type, archive content)
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }
      if (kDebugMode) {
        debugPrint('🔒 VALIDATING FILE UPLOAD');
      }
      if (kDebugMode) {
        debugPrint('File: ${file.path.split('/').last}');
      }
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }

      final validationResult = await FileUploadValidator.validateFile(filePath);

      if (!validationResult.isValid) {
        if (kDebugMode) {
          debugPrint('❌ VALIDATION FAILED: ${validationResult.errorMessage}');
        }
        return {
          'success': false,
          'error': validationResult.errorMessage ?? 'File validation failed',
          'markdown': null,
        };
      }

      if (kDebugMode) {
        debugPrint('✅ VALIDATION PASSED');
      }
      if (validationResult.fileSizeBytes != null) {
        if (kDebugMode) {
          debugPrint(
            'File size: ${FileUploadValidator.formatFileSize(validationResult.fileSizeBytes!)}',
          );
        }
      }
      if (validationResult.mimeType != null) {
        if (kDebugMode) {
          debugPrint('MIME type: ${validationResult.mimeType}');
        }
      }
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }

      // Record upload attempt and API request for rate limiting
      if (userId != null) {
        UploadRateLimiter().recordUpload(userId);
        ApiRateLimiter().recordRequest(
          endpoint: '/v1/ai/convert-file',
          userId: userId,
        );
      }

      final fileName = file.path.split('/').last;
      final fileExtension = fileName.split('.').last.toLowerCase();

      // Check if file type is supported (use FileConstants as single source of truth)
      if (!FileConstants.allowedExtensions.contains(fileExtension)) {
        return {
          'success': false,
          'error': 'Unsupported file type: .$fileExtension',
          'markdown': null,
        };
      }

      // Validate token before use
      final tokenError = SecureTokenHandler.validateTokenForRequest(
        accessToken,
        context: 'File conversion',
      );
      if (tokenError != null) {
        return {'success': false, 'error': tokenError, 'markdown': null};
      }

      // Create Dio instance with proper timeout settings and certificate pinning
      final dio = CertificatePinning.createSecureDio(
        baseUrl: _apiBaseUrl,
        headers: {'Authorization': 'Bearer $accessToken'},
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 5), // For large files
        sendTimeout: const Duration(minutes: 5), // For large files
      );

      // Log request with masked token
      SecureTokenHandler.logApiRequest(
        endpoint: '$_apiBaseUrl/v1/ai/convert-file',
        method: 'POST',
        accessToken: accessToken,
        payload: {'file': fileName},
      );

      // Create multipart form data
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(filePath, filename: fileName),
      });

      // Send the request
      final response = await dio.post(
        '/v1/ai/convert-file',
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
        endpoint: '/v1/ai/convert-file',
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

      // Check if converted content exceeds token limit (40k tokens ≈ 160k chars)
      if (markdown.length > maxCharsPerFile) {
        final estimatedTokens = (markdown.length / 4).round();
        if (kDebugMode) {
          debugPrint(
            '⚠️ File too large after conversion: ${markdown.length} chars (~$estimatedTokens tokens)',
          );
        }
        return {
          'success': false,
          'error':
              'File is too large (~$estimatedTokens tokens). Maximum allowed is $maxTokensPerFile tokens. Try a smaller file.',
          'markdown': null,
        };
      }

      return {'success': true, 'error': null, 'markdown': markdown};
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
        endpoint: '/v1/ai/convert-file',
        statusCode: e.response?.statusCode ?? 0,
        error: '${e.type}: $errorMessage',
        success: false,
      );

      return {'success': false, 'error': errorMessage, 'markdown': null};
    } catch (e, stackTrace) {
      final errorMessage = 'Unexpected error: ${e.toString()}';

      // Log unexpected error with secure handling
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        debugPrint('❌ FILE CONVERSION ERROR (Unexpected)');
        debugPrint('File: ${filePath.split('/').last}');
        debugPrint('Error: $errorMessage');
        debugPrint('Stack Trace: $stackTrace');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }

      return {
        'success': false,
        'error': 'Unexpected error: ${e.toString()}',
        'markdown': null,
      };
    }
  }

  /// Convert a file from bytes (web platform) using the /v1/ai/convert-file endpoint.
  static Future<Map<String, dynamic>> convertFileFromBytes({
    required Uint8List bytes,
    required String fileName,
    required String accessToken,
  }) async {
    try {
      final fileExtension = fileName.split('.').last.toLowerCase();

      if (!FileConstants.allowedExtensions.contains(fileExtension)) {
        return {
          'success': false,
          'error': 'Unsupported file type: .$fileExtension',
          'markdown': null,
        };
      }

      final tokenError = SecureTokenHandler.validateTokenForRequest(
        accessToken,
        context: 'File conversion',
      );
      if (tokenError != null) {
        return {'success': false, 'error': tokenError, 'markdown': null};
      }

      final dio = CertificatePinning.createSecureDio(
        baseUrl: _apiBaseUrl,
        headers: {'Authorization': 'Bearer $accessToken'},
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 5),
        sendTimeout: const Duration(minutes: 5),
      );

      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: fileName),
      });

      final response = await dio.post('/v1/ai/convert-file', data: formData);

      final markdown = response.data['markdown'] as String?;

      if (markdown == null || markdown.isEmpty) {
        return {
          'success': false,
          'error': 'No markdown content returned from API',
          'markdown': null,
        };
      }

      if (markdown.length > maxCharsPerFile) {
        final estimatedTokens = (markdown.length / 4).round();
        return {
          'success': false,
          'error':
              'File is too large (~$estimatedTokens tokens). Maximum allowed is $maxTokensPerFile tokens.',
          'markdown': null,
        };
      }

      return {'success': true, 'error': null, 'markdown': markdown};
    } on DioException catch (e) {
      String errorMessage = 'File conversion failed';
      if (e.response?.statusCode == 413) {
        errorMessage = 'File is too large (max 10MB)';
      } else if (e.response?.statusCode == 401) {
        errorMessage = 'Authentication failed. Please sign in again.';
      } else if (e.response != null) {
        errorMessage = 'Server error: ${e.response!.statusCode}';
      }
      return {'success': false, 'error': errorMessage, 'markdown': null};
    } catch (e) {
      return {
        'success': false,
        'error': 'Unexpected error: ${e.toString()}',
        'markdown': null,
      };
    }
  }

  /// Check if a file extension is supported for conversion
  /// Uses FileConstants as the single source of truth
  static bool isExtensionSupported(String extension) {
    return FileConstants.allowedExtensions.contains(extension.toLowerCase());
  }

  /// Get the category of a file extension (for display purposes)
  /// Uses FileConstants for consistent file type detection
  static String getFileCategory(String extension) {
    final ext = extension.toLowerCase();

    if (FileConstants.convertApiExtensions.contains(ext)) {
      // Binary files that need API conversion
      if (FileConstants.audioExtensions.contains(ext)) {
        return 'audio';
      } else if ({'epub'}.contains(ext)) {
        return 'ebook';
      } else if ({'msg', 'eml'}.contains(ext)) {
        return 'email';
      } else {
        return 'document';
      }
    } else if (FileConstants.isImage(ext)) {
      return 'image';
    } else if ({'zip'}.contains(ext)) {
      return 'archive';
    } else {
      return 'text';
    }
  }
}
