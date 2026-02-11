import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/api_rate_limiter.dart';

void main() {
  late ApiRateLimiter limiter;

  setUp(() {
    limiter = ApiRateLimiter();
    limiter.clearAllHistory();
  });

  group('RateLimitConfig', () {
    test('chat preset', () {
      expect(RateLimitConfig.chat.maxRequests, equals(30));
      expect(RateLimitConfig.chat.timeWindow, equals(const Duration(minutes: 1)));
      expect(RateLimitConfig.chat.minRequestInterval, equals(const Duration(milliseconds: 500)));
    });

    test('fileConversion preset', () {
      expect(RateLimitConfig.fileConversion.maxRequests, equals(10));
      expect(RateLimitConfig.fileConversion.timeWindow, equals(const Duration(minutes: 5)));
    });

    test('general preset', () {
      expect(RateLimitConfig.general.maxRequests, equals(60));
      expect(RateLimitConfig.general.timeWindow, equals(const Duration(minutes: 1)));
    });

    test('custom config', () {
      const config = RateLimitConfig(
        maxRequests: 5,
        timeWindow: Duration(seconds: 10),
        minRequestInterval: Duration(milliseconds: 50),
      );
      expect(config.maxRequests, equals(5));
      expect(config.timeWindow, equals(const Duration(seconds: 10)));
    });
  });

  group('RateLimitResult', () {
    test('allowed factory', () {
      final result = RateLimitResult.allowed(5);
      expect(result.allowed, isTrue);
      expect(result.requestsRemaining, equals(5));
      expect(result.errorMessage, isNull);
      expect(result.retryAfter, isNull);
    });

    test('denied factory', () {
      final result = RateLimitResult.denied(
        message: 'Too fast',
        retryAfter: const Duration(seconds: 5),
        requestsRemaining: 0,
      );
      expect(result.allowed, isFalse);
      expect(result.requestsRemaining, equals(0));
      expect(result.errorMessage, equals('Too fast'));
      expect(result.retryAfter, equals(const Duration(seconds: 5)));
    });
  });

  group('checkRateLimit', () {
    test('first request is allowed', () {
      final result = limiter.checkRateLimit(
        endpoint: '/chat',
        userId: 'user1',
        config: RateLimitConfig.chat,
      );
      expect(result.allowed, isTrue);
      expect(result.requestsRemaining, equals(30));
    });

    test('requests within limit are allowed', () {
      const config = RateLimitConfig(
        maxRequests: 5,
        timeWindow: Duration(minutes: 1),
        minRequestInterval: Duration.zero,
      );

      for (int i = 0; i < 3; i++) {
        limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      }

      final result = limiter.checkRateLimit(
        endpoint: '/chat',
        userId: 'user1',
        config: config,
      );
      expect(result.allowed, isTrue);
      expect(result.requestsRemaining, equals(2));
    });

    test('exceeding limit is denied', () {
      const config = RateLimitConfig(
        maxRequests: 3,
        timeWindow: Duration(minutes: 1),
        minRequestInterval: Duration.zero,
      );

      for (int i = 0; i < 3; i++) {
        limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      }

      final result = limiter.checkRateLimit(
        endpoint: '/chat',
        userId: 'user1',
        config: config,
      );
      expect(result.allowed, isFalse);
      expect(result.requestsRemaining, equals(0));
      expect(result.errorMessage, isNotNull);
      expect(result.retryAfter, isNotNull);
    });

    test('different users are tracked separately', () {
      const config = RateLimitConfig(
        maxRequests: 2,
        timeWindow: Duration(minutes: 1),
        minRequestInterval: Duration.zero,
      );

      // Fill up user1's limit
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');

      // user2 should still be allowed
      final result = limiter.checkRateLimit(
        endpoint: '/chat',
        userId: 'user2',
        config: config,
      );
      expect(result.allowed, isTrue);
    });

    test('different endpoints are tracked separately', () {
      const config = RateLimitConfig(
        maxRequests: 2,
        timeWindow: Duration(minutes: 1),
        minRequestInterval: Duration.zero,
      );

      limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');

      final result = limiter.checkRateLimit(
        endpoint: '/upload',
        userId: 'user1',
        config: config,
      );
      expect(result.allowed, isTrue);
    });
  });

  group('getRequestsRemaining', () {
    test('no history returns max requests', () {
      final remaining = limiter.getRequestsRemaining(
        endpoint: '/chat',
        userId: 'user1',
        config: RateLimitConfig.chat,
      );
      expect(remaining, equals(30));
    });

    test('after requests, remaining decreases', () {
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');

      final remaining = limiter.getRequestsRemaining(
        endpoint: '/chat',
        userId: 'user1',
        config: RateLimitConfig.chat,
      );
      expect(remaining, equals(28));
    });
  });

  group('getTimeUntilReset', () {
    test('no active limit returns null', () {
      final time = limiter.getTimeUntilReset(
        endpoint: '/chat',
        userId: 'user1',
        config: RateLimitConfig.chat,
      );
      expect(time, isNull);
    });

    test('under limit returns null', () {
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      final time = limiter.getTimeUntilReset(
        endpoint: '/chat',
        userId: 'user1',
        config: RateLimitConfig.chat,
      );
      expect(time, isNull);
    });
  });

  group('clearUserHistory', () {
    test('clears specific user history', () {
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      limiter.recordRequest(endpoint: '/chat', userId: 'user2');

      limiter.clearUserHistory('user1');

      expect(
        limiter.getRequestsRemaining(
          endpoint: '/chat',
          userId: 'user1',
          config: RateLimitConfig.chat,
        ),
        equals(30),
      );
      // user2 unaffected
      expect(
        limiter.getRequestsRemaining(
          endpoint: '/chat',
          userId: 'user2',
          config: RateLimitConfig.chat,
        ),
        equals(29),
      );
    });
  });

  group('clearAllHistory', () {
    test('clears all users and endpoints', () {
      limiter.recordRequest(endpoint: '/chat', userId: 'user1');
      limiter.recordRequest(endpoint: '/upload', userId: 'user2');

      limiter.clearAllHistory();

      expect(
        limiter.getRequestsRemaining(
          endpoint: '/chat',
          userId: 'user1',
          config: RateLimitConfig.chat,
        ),
        equals(30),
      );
      expect(
        limiter.getRequestsRemaining(
          endpoint: '/upload',
          userId: 'user2',
          config: RateLimitConfig.chat,
        ),
        equals(30),
      );
    });
  });
}
