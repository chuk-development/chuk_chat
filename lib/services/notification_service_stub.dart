// lib/services/notification_service_stub.dart
// Web stub - flutter_local_notifications not available on web
import 'package:flutter/material.dart';

/// Service for handling local notifications (completion notifications with deep linking)
/// Web stub - no-op implementation (web doesn't have local notifications)
class NotificationService {
  static bool _isInitialized = false;

  /// Initialize the notification service (no-op on web)
  static Future<void> initialize(GlobalKey<NavigatorState> navigatorKey) async {
    _isInitialized = true;
    // No-op on web - would use Web Notifications API if needed
  }

  /// Show a completion notification (no-op on web)
  static Future<void> showCompletionNotification({
    required String chatId,
    required String chatTitle,
    required String contentPreview,
  }) async {
    // No-op on web - could use Web Notifications API in future
  }

  /// Check if app was launched from a notification (no-op on web)
  static Future<void> checkLaunchNotification() async {
    // No-op on web
  }

  /// Request notification permission (always returns true on web)
  static Future<bool> requestPermission() async {
    return true;
  }
}
