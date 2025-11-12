/// Upload rate limiter to prevent DoS attacks via excessive file uploads.
class UploadRateLimiter {
  UploadRateLimiter._();

  static final UploadRateLimiter _instance = UploadRateLimiter._();
  factory UploadRateLimiter() => _instance;

  /// Maximum uploads per time window
  static const int maxUploadsPerWindow = 10;

  /// Time window in minutes
  static const int timeWindowMinutes = 5;

  /// Track upload timestamps per user
  final Map<String, List<DateTime>> _uploadHistory = {};

  /// Check if an upload is allowed for a user.
  ///
  /// Returns true if allowed, false if rate limit exceeded.
  bool isUploadAllowed(String userId) {
    final now = DateTime.now();
    final windowStart = now.subtract(Duration(minutes: timeWindowMinutes));

    // Get or create upload history for user
    final userHistory = _uploadHistory.putIfAbsent(userId, () => []);

    // Remove old entries outside the time window
    userHistory.removeWhere((timestamp) => timestamp.isBefore(windowStart));

    // Check if user has exceeded the limit
    if (userHistory.length >= maxUploadsPerWindow) {
      return false;
    }

    return true;
  }

  /// Record an upload attempt for a user.
  void recordUpload(String userId) {
    final now = DateTime.now();
    final userHistory = _uploadHistory.putIfAbsent(userId, () => []);
    userHistory.add(now);
  }

  /// Get the number of uploads remaining for a user in the current window.
  int getUploadsRemaining(String userId) {
    final now = DateTime.now();
    final windowStart = now.subtract(Duration(minutes: timeWindowMinutes));

    final userHistory = _uploadHistory[userId] ?? [];

    // Count uploads in current window
    final uploadsInWindow = userHistory.where((timestamp) => timestamp.isAfter(windowStart)).length;

    return maxUploadsPerWindow - uploadsInWindow;
  }

  /// Get time until rate limit resets (in seconds).
  int? getTimeUntilReset(String userId) {
    final now = DateTime.now();
    final windowStart = now.subtract(Duration(minutes: timeWindowMinutes));

    final userHistory = _uploadHistory[userId] ?? [];

    // Remove old entries
    final recentUploads = userHistory.where((timestamp) => timestamp.isAfter(windowStart)).toList();

    if (recentUploads.isEmpty || recentUploads.length < maxUploadsPerWindow) {
      return null; // No rate limit active
    }

    // Find the oldest upload in the window
    recentUploads.sort();
    final oldestUpload = recentUploads.first;
    final resetTime = oldestUpload.add(Duration(minutes: timeWindowMinutes));

    final secondsUntilReset = resetTime.difference(now).inSeconds;
    return secondsUntilReset > 0 ? secondsUntilReset : null;
  }

  /// Clear upload history for a user (useful for testing or admin actions).
  void clearUserHistory(String userId) {
    _uploadHistory.remove(userId);
  }

  /// Clear all upload history (useful for testing).
  void clearAllHistory() {
    _uploadHistory.clear();
  }
}
