import 'package:flutter/foundation.dart';

/// API rate limiting configuration for different endpoint types.
class RateLimitConfig {
  final int maxRequests;
  final Duration timeWindow;
  final Duration minRequestInterval;

  const RateLimitConfig({
    required this.maxRequests,
    required this.timeWindow,
    this.minRequestInterval = const Duration(milliseconds: 100),
  });

  /// Default config for chat API requests (30 requests per minute)
  static const chat = RateLimitConfig(
    maxRequests: 30,
    timeWindow: Duration(minutes: 1),
    minRequestInterval: Duration(milliseconds: 500),
  );

  /// Config for file conversion API (10 requests per 5 minutes)
  static const fileConversion = RateLimitConfig(
    maxRequests: 10,
    timeWindow: Duration(minutes: 5),
    minRequestInterval: Duration(seconds: 1),
  );

  /// Config for general API requests (60 requests per minute)
  static const general = RateLimitConfig(
    maxRequests: 60,
    timeWindow: Duration(minutes: 1),
    minRequestInterval: Duration(milliseconds: 200),
  );
}

/// Result of a rate limit check.
class RateLimitResult {
  final bool allowed;
  final String? errorMessage;
  final Duration? retryAfter;
  final int requestsRemaining;

  const RateLimitResult({
    required this.allowed,
    this.errorMessage,
    this.retryAfter,
    required this.requestsRemaining,
  });

  factory RateLimitResult.allowed(int requestsRemaining) {
    return RateLimitResult(
      allowed: true,
      requestsRemaining: requestsRemaining,
    );
  }

  factory RateLimitResult.denied({
    required String message,
    required Duration retryAfter,
    required int requestsRemaining,
  }) {
    return RateLimitResult(
      allowed: false,
      errorMessage: message,
      retryAfter: retryAfter,
      requestsRemaining: requestsRemaining,
    );
  }
}

/// Manages API rate limiting with per-endpoint and per-user tracking.
class ApiRateLimiter {
  ApiRateLimiter._();

  static final ApiRateLimiter _instance = ApiRateLimiter._();
  factory ApiRateLimiter() => _instance;

  /// Track requests by endpoint and user
  final Map<String, Map<String, List<DateTime>>> _requestHistory = {};

  /// Track last request time for minimum interval enforcement
  final Map<String, DateTime> _lastRequestTime = {};

  /// Check if a request is allowed based on rate limits.
  RateLimitResult checkRateLimit({
    required String endpoint,
    required String userId,
    required RateLimitConfig config,
  }) {
    final now = DateTime.now();
    final key = '$endpoint:$userId';

    // Check minimum interval between requests
    final lastRequest = _lastRequestTime[key];
    if (lastRequest != null) {
      final timeSinceLastRequest = now.difference(lastRequest);
      if (timeSinceLastRequest < config.minRequestInterval) {
        final retryAfter = config.minRequestInterval - timeSinceLastRequest;
        return RateLimitResult.denied(
          message: 'Too many requests. Please wait ${retryAfter.inSeconds} second(s).',
          retryAfter: retryAfter,
          requestsRemaining: 0,
        );
      }
    }

    // Get or create request history for this endpoint+user
    final endpointHistory = _requestHistory.putIfAbsent(endpoint, () => {});
    final userHistory = endpointHistory.putIfAbsent(userId, () => []);

    // Remove requests outside the time window
    final windowStart = now.subtract(config.timeWindow);
    userHistory.removeWhere((timestamp) => timestamp.isBefore(windowStart));

    // Check if rate limit is exceeded
    if (userHistory.length >= config.maxRequests) {
      final oldestRequest = userHistory.first;
      final resetTime = oldestRequest.add(config.timeWindow);
      final retryAfter = resetTime.difference(now);

      return RateLimitResult.denied(
        message: 'Rate limit exceeded. Try again in ${_formatDuration(retryAfter)}.',
        retryAfter: retryAfter,
        requestsRemaining: 0,
      );
    }

    // Calculate remaining requests
    final requestsRemaining = config.maxRequests - userHistory.length;

    return RateLimitResult.allowed(requestsRemaining);
  }

  /// Record a successful request.
  void recordRequest({
    required String endpoint,
    required String userId,
  }) {
    final now = DateTime.now();
    final key = '$endpoint:$userId';

    // Update last request time
    _lastRequestTime[key] = now;

    // Add to history
    final endpointHistory = _requestHistory.putIfAbsent(endpoint, () => {});
    final userHistory = endpointHistory.putIfAbsent(userId, () => []);
    userHistory.add(now);
  }

  /// Get the number of requests remaining for a user on an endpoint.
  int getRequestsRemaining({
    required String endpoint,
    required String userId,
    required RateLimitConfig config,
  }) {
    final now = DateTime.now();
    final windowStart = now.subtract(config.timeWindow);

    final userHistory = _requestHistory[endpoint]?[userId] ?? [];
    final recentRequests = userHistory.where((t) => t.isAfter(windowStart)).length;

    return config.maxRequests - recentRequests;
  }

  /// Get time until rate limit resets.
  Duration? getTimeUntilReset({
    required String endpoint,
    required String userId,
    required RateLimitConfig config,
  }) {
    final now = DateTime.now();
    final windowStart = now.subtract(config.timeWindow);

    final userHistory = _requestHistory[endpoint]?[userId] ?? [];
    final recentRequests = userHistory.where((t) => t.isAfter(windowStart)).toList();

    if (recentRequests.isEmpty || recentRequests.length < config.maxRequests) {
      return null; // No rate limit active
    }

    // Find oldest request in window
    recentRequests.sort();
    final oldestRequest = recentRequests.first;
    final resetTime = oldestRequest.add(config.timeWindow);

    final timeUntilReset = resetTime.difference(now);
    return timeUntilReset.isNegative ? null : timeUntilReset;
  }

  /// Clear rate limit history for a user (useful for testing or admin actions).
  void clearUserHistory(String userId) {
    _requestHistory.forEach((endpoint, users) {
      users.remove(userId);
    });
    _lastRequestTime.removeWhere((key, _) => key.endsWith(':$userId'));
  }

  /// Clear all rate limit history.
  void clearAllHistory() {
    _requestHistory.clear();
    _lastRequestTime.clear();
  }

  /// Format duration for user-friendly display.
  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours} hour(s)';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes} minute(s)';
    } else {
      return '${duration.inSeconds} second(s)';
    }
  }

  /// Log rate limit status (debug mode only).
  void logRateLimitStatus({
    required String endpoint,
    required String userId,
    required RateLimitConfig config,
  }) {
    if (!kDebugMode) return;

    final remaining = getRequestsRemaining(
      endpoint: endpoint,
      userId: userId,
      config: config,
    );
    final resetTime = getTimeUntilReset(
      endpoint: endpoint,
      userId: userId,
      config: config,
    );

      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      debugPrint('📊 RATE LIMIT STATUS');
      debugPrint('Endpoint: $endpoint');
      debugPrint('Requests remaining: $remaining/${config.maxRequests}');
    if (resetTime != null) {
        debugPrint('Resets in: ${_formatDuration(resetTime)}');
    } else {
        debugPrint('No active limit');
    }
      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }
}
