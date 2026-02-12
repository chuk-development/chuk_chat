// lib/services/streaming_foreground_service_stub.dart
// Web stub - foreground services don't exist on web

/// Service to keep AI streaming alive when app is backgrounded or screen locked.
/// Web stub - no-op implementation (web doesn't have foreground services)
class StreamingForegroundService {
  static final bool _isRunning = false;

  /// Whether the foreground service is currently running
  static bool get isRunning => _isRunning;

  /// Initialize the foreground task system (no-op on web)
  static Future<void> initialize() async {
    // No-op on web
  }

  /// Start the foreground service (no-op on web)
  static Future<void> startService() async {
    // No-op on web - browser handles tab state
  }

  /// Update the notification (no-op on web)
  static Future<void> updateNotification({
    required String content,
    String? title,
  }) async {
    // No-op on web
  }

  /// Stop the foreground service (no-op on web)
  static Future<void> stopService() async {
    // No-op on web
  }

  /// Check if we can start foreground service (always false on web)
  static Future<bool> canStart() async {
    return false;
  }
}
