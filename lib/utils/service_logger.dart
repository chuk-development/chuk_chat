// lib/utils/service_logger.dart
import 'package:flutter/foundation.dart';

/// Centralized logging utility for services with consistent formatting
class ServiceLogger {
  const ServiceLogger._();

  /// Log levels for different types of messages
  static const String _levelDebug = '🔍';
  static const String _levelInfo = 'ℹ️';
  static const String _levelWarning = '⚠️';
  static const String _levelError = '❌';
  static const String _levelSuccess = '✅';

  /// Log a debug message (only in debug mode)
  static void debug(String message, {String? context}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_levelDebug$contextStr $message');
  }

  /// Log an info message (only in debug mode)
  static void info(String message, {String? context}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_levelInfo$contextStr $message');
  }

  /// Log a warning message (only in debug mode)
  static void warning(String message, {String? context}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_levelWarning$contextStr $message');
  }

  /// Log an error message (only in debug mode)
  static void error(String message, {String? context, Object? exception, StackTrace? stackTrace}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_levelError$contextStr $message');
    if (exception != null) {
        debugPrint('   Exception: $exception');
    }
    if (stackTrace != null) {
        debugPrint('   Stack trace: $stackTrace');
    }
  }

  /// Log a success message (only in debug mode)
  static void success(String message, {String? context}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_levelSuccess$contextStr $message');
  }

  /// Log an API request (only in debug mode)
  static void apiRequest({
    required String method,
    required String endpoint,
    Map<String, dynamic>? params,
    Map<String, dynamic>? headers,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('🌐$contextStr API Request: $method $endpoint');
    if (params != null && params.isNotEmpty) {
        debugPrint('   Params: $params');
    }
    if (headers != null && headers.isNotEmpty) {
      // Mask authorization headers
      final safeHeaders = Map<String, dynamic>.from(headers);
      if (safeHeaders.containsKey('Authorization')) {
        safeHeaders['Authorization'] = '[MASKED]';
      }
        debugPrint('   Headers: $safeHeaders');
    }
  }

  /// Log an API response (only in debug mode)
  static void apiResponse({
    required String method,
    required String endpoint,
    required int statusCode,
    dynamic responseData,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    final statusEmoji = statusCode >= 200 && statusCode < 300 ? '✅' : '❌';
    debugPrint('$statusEmoji$contextStr API Response: $method $endpoint ($statusCode)');
    if (responseData != null) {
      // Truncate large responses
      final dataStr = responseData.toString();
      if (dataStr.length > 500) {
          debugPrint('   Data: ${dataStr.substring(0, 500)}... [truncated]');
      } else {
          debugPrint('   Data: $dataStr');
      }
    }
  }

  /// Log a service operation start (only in debug mode)
  static void operationStart(String operationName, {String? context}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('▶️$contextStr Starting: $operationName');
  }

  /// Log a service operation completion (only in debug mode)
  static void operationComplete(String operationName, {String? context, Duration? duration}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    final durationStr = duration != null ? ' (${duration.inMilliseconds}ms)' : '';
    debugPrint('✅$contextStr Completed: $operationName$durationStr');
  }

  /// Log a service operation failure (only in debug mode)
  static void operationFailed(String operationName, {String? context, Object? exception}) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('❌$contextStr Failed: $operationName');
    if (exception != null) {
        debugPrint('   Reason: $exception');
    }
  }

  /// Log data persistence operations (only in debug mode)
  static void persistence({
    required String action,
    required String dataType,
    String? identifier,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    final idStr = identifier != null ? ' ($identifier)' : '';
    debugPrint('💾$contextStr $action $dataType$idStr');
  }

  /// Log cache operations (only in debug mode)
  static void cache({
    required String action,
    required String key,
    bool hit = false,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    final emoji = hit ? '✅' : '❌';
    debugPrint('🗄️$contextStr Cache $action: $key $emoji');
  }

  /// Log authentication events (only in debug mode)
  static void auth({
    required String event,
    String? userId,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    final userStr = userId != null ? ' (user: ${_maskUserId(userId)})' : '';
    debugPrint('🔐$contextStr Auth: $event$userStr');
  }

  /// Log network status changes (only in debug mode)
  static void networkStatus({
    required bool isOnline,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    final status = isOnline ? 'ONLINE' : 'OFFLINE';
    final emoji = isOnline ? '🌐' : '📴';
      debugPrint('$emoji$contextStr Network status: $status');
  }

  /// Log stream events (only in debug mode)
  static void stream({
    required String event,
    required String streamId,
    String? data,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('📡$contextStr Stream $event: $streamId');
    if (data != null) {
      // Truncate large data
      if (data.length > 200) {
          debugPrint('   Data: ${data.substring(0, 200)}... [truncated]');
      } else {
          debugPrint('   Data: $data');
      }
    }
  }

  /// Log file operations (only in debug mode)
  static void fileOperation({
    required String action,
    required String fileName,
    int? sizeBytes,
    String? context,
  }) {
    if (!kDebugMode) return;
    final contextStr = context != null ? ' [$context]' : '';
    final sizeStr = sizeBytes != null ? ' (${_formatBytes(sizeBytes)})' : '';
    debugPrint('📁$contextStr File $action: $fileName$sizeStr');
  }

  /// Mask user ID for privacy (show first 8 chars only)
  static String _maskUserId(String userId) {
    if (userId.length <= 8) return userId;
    return '${userId.substring(0, 8)}...';
  }

  /// Format bytes to human-readable string
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  /// Log a divider line (for separating sections in logs)
  static void divider({String? label}) {
    if (!kDebugMode) return;
    if (label != null) {
      debugPrint('━━━━━━━━━━━━━━━━━━━━━ $label ━━━━━━━━━━━━━━━━━━━━━');
    } else {
        debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    }
  }
}
