import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/exponential_backoff.dart';

void main() {
  group('BackoffConfig', () {
    test('default values', () {
      const config = BackoffConfig();
      expect(config.maxRetries, equals(3));
      expect(config.initialDelay, equals(const Duration(seconds: 1)));
      expect(config.maxDelay, equals(const Duration(seconds: 30)));
      expect(config.multiplier, equals(2.0));
      expect(config.jitter, equals(0.1));
    });

    test('chat preset', () {
      expect(BackoffConfig.chat.maxRetries, equals(3));
      expect(BackoffConfig.chat.initialDelay, equals(const Duration(milliseconds: 500)));
      expect(BackoffConfig.chat.maxDelay, equals(const Duration(seconds: 10)));
    });

    test('fileUpload preset', () {
      expect(BackoffConfig.fileUpload.maxRetries, equals(3));
      expect(BackoffConfig.fileUpload.initialDelay, equals(const Duration(seconds: 2)));
      expect(BackoffConfig.fileUpload.maxDelay, equals(const Duration(minutes: 1)));
    });

    test('critical preset', () {
      expect(BackoffConfig.critical.maxRetries, equals(5));
      expect(BackoffConfig.critical.initialDelay, equals(const Duration(milliseconds: 500)));
      expect(BackoffConfig.critical.maxDelay, equals(const Duration(seconds: 30)));
    });

    test('custom config', () {
      const config = BackoffConfig(
        maxRetries: 10,
        initialDelay: Duration(milliseconds: 100),
        maxDelay: Duration(seconds: 5),
        multiplier: 3.0,
        jitter: 0.2,
      );
      expect(config.maxRetries, equals(10));
      expect(config.multiplier, equals(3.0));
      expect(config.jitter, equals(0.2));
    });
  });

  group('BackoffResult', () {
    test('success factory', () {
      final result = BackoffResult.success(
        'data',
        2,
        const Duration(seconds: 3),
      );
      expect(result.success, isTrue);
      expect(result.data, equals('data'));
      expect(result.attempts, equals(2));
      expect(result.totalDuration, equals(const Duration(seconds: 3)));
      expect(result.error, isNull);
    });

    test('failure factory', () {
      final result = BackoffResult.failure(
        'timeout',
        3,
        const Duration(seconds: 10),
      );
      expect(result.success, isFalse);
      expect(result.data, isNull);
      expect(result.error, equals('timeout'));
      expect(result.attempts, equals(3));
    });
  });

  group('ExponentialBackoff.execute', () {
    test('succeeds on first attempt', () async {
      final result = await ExponentialBackoff.execute<String>(
        operation: () async => 'success',
        config: const BackoffConfig(maxRetries: 3),
      );
      expect(result.success, isTrue);
      expect(result.data, equals('success'));
      expect(result.attempts, equals(1));
    });

    test('succeeds after retries', () async {
      int attempt = 0;
      final result = await ExponentialBackoff.execute<String>(
        operation: () async {
          attempt++;
          if (attempt < 3) throw Exception('not yet');
          return 'finally';
        },
        config: const BackoffConfig(
          maxRetries: 3,
          initialDelay: Duration(milliseconds: 10),
          maxDelay: Duration(milliseconds: 50),
          jitter: 0.0,
        ),
      );
      expect(result.success, isTrue);
      expect(result.data, equals('finally'));
      expect(result.attempts, equals(3));
    });

    test('fails after max retries', () async {
      final result = await ExponentialBackoff.execute<String>(
        operation: () async => throw Exception('always fails'),
        config: const BackoffConfig(
          maxRetries: 2,
          initialDelay: Duration(milliseconds: 10),
          maxDelay: Duration(milliseconds: 50),
          jitter: 0.0,
        ),
      );
      expect(result.success, isFalse);
      expect(result.data, isNull);
      expect(result.attempts, equals(2));
      expect(result.error, contains('always fails'));
    });

    test('shouldRetry=false stops retrying', () async {
      int attempt = 0;
      final result = await ExponentialBackoff.execute<String>(
        operation: () async {
          attempt++;
          throw Exception('auth error');
        },
        config: const BackoffConfig(
          maxRetries: 5,
          initialDelay: Duration(milliseconds: 10),
          jitter: 0.0,
        ),
        shouldRetry: (_) => false,
      );
      expect(result.success, isFalse);
      expect(attempt, equals(1)); // Only tried once
    });

    test('onRetry callback is called', () async {
      final retryAttempts = <int>[];
      int attempt = 0;

      await ExponentialBackoff.execute<String>(
        operation: () async {
          attempt++;
          if (attempt < 3) throw Exception('retry me');
          return 'done';
        },
        config: const BackoffConfig(
          maxRetries: 3,
          initialDelay: Duration(milliseconds: 10),
          maxDelay: Duration(milliseconds: 50),
          jitter: 0.0,
        ),
        onRetry: (attemptNum, delay, error) {
          retryAttempts.add(attemptNum);
        },
      );

      expect(retryAttempts, equals([1, 2]));
    });

    test('duration is tracked', () async {
      final result = await ExponentialBackoff.execute<String>(
        operation: () async {
          await Future.delayed(const Duration(milliseconds: 50));
          return 'delayed';
        },
        config: const BackoffConfig(maxRetries: 1),
      );
      expect(result.totalDuration.inMilliseconds, greaterThanOrEqualTo(50));
    });
  });

  group('ExponentialBackoff.executeSimple', () {
    test('succeeds immediately', () async {
      final result = await ExponentialBackoff.executeSimple<int>(
        operation: () async => 42,
      );
      expect(result.success, isTrue);
      expect(result.data, equals(42));
    });

    test('uses fixed delay (multiplier 1.0)', () async {
      int attempt = 0;
      final result = await ExponentialBackoff.executeSimple<String>(
        operation: () async {
          attempt++;
          if (attempt < 2) throw Exception('once');
          return 'ok';
        },
        maxRetries: 3,
        retryDelay: const Duration(milliseconds: 10),
      );
      expect(result.success, isTrue);
      expect(result.attempts, equals(2));
    });
  });

  group('ExponentialBackoff.shouldRetryError', () {
    test('network errors should retry', () {
      expect(ExponentialBackoff.shouldRetryError(Exception('network error')), isTrue);
      expect(ExponentialBackoff.shouldRetryError(Exception('connection refused')), isTrue);
      expect(ExponentialBackoff.shouldRetryError(Exception('timeout occurred')), isTrue);
      expect(ExponentialBackoff.shouldRetryError(Exception('socket exception')), isTrue);
    });

    test('server 5xx errors should retry', () {
      expect(ExponentialBackoff.shouldRetryError(Exception('500 Internal Server Error')), isTrue);
      expect(ExponentialBackoff.shouldRetryError(Exception('502 Bad Gateway')), isTrue);
      expect(ExponentialBackoff.shouldRetryError(Exception('503 Service Unavailable')), isTrue);
      expect(ExponentialBackoff.shouldRetryError(Exception('504 Gateway Timeout')), isTrue);
    });

    test('rate limiting (429) should retry', () {
      expect(ExponentialBackoff.shouldRetryError(Exception('429 Too Many Requests')), isTrue);
      expect(ExponentialBackoff.shouldRetryError(Exception('rate limit exceeded')), isTrue);
    });

    test('client 4xx errors (except 429) should NOT retry', () {
      expect(ExponentialBackoff.shouldRetryError(Exception('400 Bad Request')), isFalse);
      expect(ExponentialBackoff.shouldRetryError(Exception('401 Unauthorized')), isFalse);
      expect(ExponentialBackoff.shouldRetryError(Exception('403 Forbidden')), isFalse);
      expect(ExponentialBackoff.shouldRetryError(Exception('404 Not Found')), isFalse);
    });

    test('unknown errors default to retry', () {
      expect(ExponentialBackoff.shouldRetryError(Exception('something weird')), isTrue);
    });
  });
}
