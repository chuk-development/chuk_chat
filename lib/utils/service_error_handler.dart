// lib/utils/service_error_handler.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Centralized error handling for service operations
class ServiceErrorHandler {
  const ServiceErrorHandler._();

  /// Handle Dio exceptions and return user-friendly error messages
  static String handleDioException(DioException error, {String? context}) {
    if (kDebugMode) {
      debugPrint('❌ DioException${context != null ? " ($context)" : ""}: ${error.type}');
      debugPrint('   Message: ${error.message}');
      if (error.response != null) {
        debugPrint('   Status: ${error.response?.statusCode}');
        debugPrint('   Data: ${error.response?.data}');
      }
    }

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return 'Connection timeout. Please check your internet connection.';
      case DioExceptionType.sendTimeout:
        return 'Request timeout. Please try again.';
      case DioExceptionType.receiveTimeout:
        return 'Server response timeout. Please try again.';
      case DioExceptionType.badCertificate:
        return 'Security error: Invalid SSL certificate. Please ensure you are on a trusted network.';
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        return _handleHttpStatusCode(statusCode, error.response?.data);
      case DioExceptionType.cancel:
        return 'Request was cancelled.';
      case DioExceptionType.connectionError:
        return 'Connection error. Please check your internet connection.';
      case DioExceptionType.unknown:
        return 'Network error. Please try again later.';
    }
  }

  /// Handle HTTP status codes and return appropriate messages
  static String _handleHttpStatusCode(int? statusCode, dynamic responseData) {
    if (statusCode == null) {
      return 'Unknown error occurred.';
    }

    // Try to extract error message from response
    String? errorMessage;
    if (responseData is Map) {
      errorMessage = responseData['error'] ?? responseData['message'];
    } else if (responseData is String) {
      errorMessage = responseData;
    }

    switch (statusCode) {
      case 400:
        return errorMessage ?? 'Invalid request. Please check your input.';
      case 401:
        return 'Authentication failed. Please sign in again.';
      case 403:
        return 'Access denied. You do not have permission for this action.';
      case 404:
        return 'Resource not found.';
      case 429:
        return 'Too many requests. Please wait a moment and try again.';
      case 500:
        return errorMessage ?? 'Server error. Please try again later.';
      case 502:
        return 'Bad gateway. The server is temporarily unavailable.';
      case 503:
        return 'Service unavailable. Please try again later.';
      case 504:
        return 'Gateway timeout. The server took too long to respond.';
      default:
        if (statusCode >= 400 && statusCode < 500) {
          return errorMessage ?? 'Client error ($statusCode). Please check your request.';
        } else if (statusCode >= 500) {
          return errorMessage ?? 'Server error ($statusCode). Please try again later.';
        }
        return errorMessage ?? 'Error occurred ($statusCode).';
    }
  }

  /// Handle generic exceptions
  static String handleGenericException(Object error, {String? context}) {
    if (kDebugMode) {
      debugPrint('❌ Exception${context != null ? " ($context)" : ""}: $error');
      if (error is Error) {
        debugPrint('   Stack trace: ${error.stackTrace}');
      }
    }

    if (error is DioException) {
      return handleDioException(error, context: context);
    }

    // Fallback for unknown errors
    return 'An unexpected error occurred. Please try again.';
  }

  /// Wrap an async operation with error handling
  static Future<T?> tryAsync<T>({
    required Future<T> Function() operation,
    required String context,
    void Function(String error)? onError,
  }) async {
    try {
      return await operation();
    } on DioException catch (e) {
      final errorMessage = handleDioException(e, context: context);
      onError?.call(errorMessage);
      return null;
    } catch (e) {
      final errorMessage = handleGenericException(e, context: context);
      onError?.call(errorMessage);
      return null;
    }
  }

  /// Check if an error is due to network connectivity
  static bool isNetworkError(Object error) {
    if (error is DioException) {
      return error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout;
    }
    return false;
  }

  /// Check if an error is due to authentication failure
  static bool isAuthError(Object error) {
    if (error is DioException &&
        error.type == DioExceptionType.badResponse) {
      return error.response?.statusCode == 401 ||
          error.response?.statusCode == 403;
    }
    return false;
  }

  /// Check if an error is due to rate limiting
  static bool isRateLimitError(Object error) {
    if (error is DioException &&
        error.type == DioExceptionType.badResponse) {
      return error.response?.statusCode == 429;
    }
    return false;
  }

  /// Check if an error is a server error (5xx)
  static bool isServerError(Object error) {
    if (error is DioException &&
        error.type == DioExceptionType.badResponse) {
      final statusCode = error.response?.statusCode;
      return statusCode != null && statusCode >= 500 && statusCode < 600;
    }
    return false;
  }

  /// Get retry delay for an error (used with exponential backoff)
  static Duration? getRetryDelay(Object error, int attemptNumber) {
    if (isRateLimitError(error)) {
      // Wait longer for rate limit errors
      return Duration(seconds: 30 * attemptNumber);
    } else if (isServerError(error)) {
      // Exponential backoff for server errors
      return Duration(seconds: (2 * attemptNumber).clamp(1, 30));
    } else if (isNetworkError(error)) {
      // Short delay for network errors
      return Duration(seconds: 2 * attemptNumber);
    }
    return null; // Don't retry by default
  }
}
