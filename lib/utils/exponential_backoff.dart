import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Configuration for exponential backoff retry logic.
class BackoffConfig {
  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;
  final double jitter;

  const BackoffConfig({
    this.maxRetries = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.jitter = 0.1,
  });

  /// Default config for chat requests
  static const chat = BackoffConfig(
    maxRetries: 3,
    initialDelay: Duration(milliseconds: 500),
    maxDelay: Duration(seconds: 10),
  );

  /// Config for file uploads (longer delays)
  static const fileUpload = BackoffConfig(
    maxRetries: 3,
    initialDelay: Duration(seconds: 2),
    maxDelay: Duration(minutes: 1),
  );

  /// Config for critical operations (more retries)
  static const critical = BackoffConfig(
    maxRetries: 5,
    initialDelay: Duration(milliseconds: 500),
    maxDelay: Duration(seconds: 30),
  );
}

/// Result of a backoff operation.
class BackoffResult<T> {
  final T? data;
  final bool success;
  final String? error;
  final int attempts;
  final Duration totalDuration;

  const BackoffResult({
    this.data,
    required this.success,
    this.error,
    required this.attempts,
    required this.totalDuration,
  });

  factory BackoffResult.success(T data, int attempts, Duration duration) {
    return BackoffResult(
      data: data,
      success: true,
      attempts: attempts,
      totalDuration: duration,
    );
  }

  factory BackoffResult.failure(String error, int attempts, Duration duration) {
    return BackoffResult(
      success: false,
      error: error,
      attempts: attempts,
      totalDuration: duration,
    );
  }
}

/// Handles exponential backoff for failed API requests.
class ExponentialBackoff {
  /// Execute an operation with exponential backoff retry logic.
  ///
  /// [operation] - The async operation to execute
  /// [config] - Backoff configuration
  /// [shouldRetry] - Optional function to determine if error should trigger retry
  /// [onRetry] - Optional callback when retrying
  static Future<BackoffResult<T>> execute<T>({
    required Future<T> Function() operation,
    BackoffConfig config = const BackoffConfig(),
    bool Function(dynamic error)? shouldRetry,
    void Function(int attempt, Duration delay, dynamic error)? onRetry,
  }) async {
    final startTime = DateTime.now();
    int attempt = 0;

    while (attempt < config.maxRetries) {
      attempt++;

      try {
        final result = await operation();
        final duration = DateTime.now().difference(startTime);

        if (kDebugMode) {
          debugPrint('✅ Operation succeeded on attempt $attempt');
          debugPrint('   Total duration: ${duration.inMilliseconds}ms');
        }

        return BackoffResult.success(result, attempt, duration);
      } catch (error) {
        final shouldRetryError = shouldRetry?.call(error) ?? true;

        if (!shouldRetryError || attempt >= config.maxRetries) {
          final duration = DateTime.now().difference(startTime);

          if (kDebugMode) {
            debugPrint('❌ Operation failed after $attempt attempt(s)');
            debugPrint('   Error: $error');
            debugPrint('   Total duration: ${duration.inMilliseconds}ms');
          }

          return BackoffResult.failure(
            error.toString(),
            attempt,
            duration,
          );
        }

        // Calculate backoff delay with jitter
        final delay = _calculateDelay(attempt, config);

        if (kDebugMode) {
          debugPrint('⚠️  Attempt $attempt failed, retrying in ${delay.inMilliseconds}ms');
          debugPrint('   Error: $error');
        }

        // Call retry callback if provided
        onRetry?.call(attempt, delay, error);

        // Wait before retrying
        await Future.delayed(delay);
      }
    }

    // Should never reach here, but handle it just in case
    final duration = DateTime.now().difference(startTime);
    return BackoffResult.failure(
      'Max retries exceeded',
      attempt,
      duration,
    );
  }

  /// Calculate delay for a given attempt with exponential backoff and jitter.
  static Duration _calculateDelay(int attempt, BackoffConfig config) {
    // Calculate exponential delay
    final exponentialDelay = config.initialDelay.inMilliseconds *
        math.pow(config.multiplier, attempt - 1);

    // Apply max delay cap
    final cappedDelay = math.min(
      exponentialDelay.toDouble(),
      config.maxDelay.inMilliseconds.toDouble(),
    );

    // Add jitter to prevent thundering herd
    final jitterAmount = cappedDelay * config.jitter;
    final random = math.Random();
    final jitter = (random.nextDouble() * 2 - 1) * jitterAmount;

    final finalDelay = (cappedDelay + jitter).clamp(0, double.infinity).toInt();

    return Duration(milliseconds: finalDelay);
  }

  /// Execute an operation with simple retry (no backoff).
  static Future<BackoffResult<T>> executeSimple<T>({
    required Future<T> Function() operation,
    int maxRetries = 3,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    return execute(
      operation: operation,
      config: BackoffConfig(
        maxRetries: maxRetries,
        initialDelay: retryDelay,
        maxDelay: retryDelay,
        multiplier: 1.0,
        jitter: 0.0,
      ),
    );
  }

  /// Determine if an error should trigger a retry based on common scenarios.
  static bool shouldRetryError(dynamic error) {
    final errorString = error.toString().toLowerCase();

    // Network errors - should retry
    if (errorString.contains('network') ||
        errorString.contains('connection') ||
        errorString.contains('timeout') ||
        errorString.contains('socket')) {
      return true;
    }

    // Server errors (5xx) - should retry
    if (errorString.contains('500') ||
        errorString.contains('502') ||
        errorString.contains('503') ||
        errorString.contains('504')) {
      return true;
    }

    // Rate limiting (429) - should retry with backoff
    if (errorString.contains('429') || errorString.contains('rate limit')) {
      return true;
    }

    // Client errors (4xx except 429) - should NOT retry
    if (errorString.contains('400') ||
        errorString.contains('401') ||
        errorString.contains('403') ||
        errorString.contains('404')) {
      return false;
    }

    // Default: retry for unknown errors
    return true;
  }
}

/// Convenience extension for adding retry logic to Futures.
extension RetryableFunction<T> on Future<T> Function() {
  /// Execute this function with exponential backoff.
  Future<BackoffResult<T>> withBackoff([BackoffConfig? config]) {
    return ExponentialBackoff.execute(
      operation: this,
      config: config ?? const BackoffConfig(),
      shouldRetry: ExponentialBackoff.shouldRetryError,
    );
  }

  /// Execute this function with simple retry.
  Future<BackoffResult<T>> withRetry({int maxRetries = 3}) {
    return ExponentialBackoff.executeSimple(
      operation: this,
      maxRetries: maxRetries,
    );
  }
}
