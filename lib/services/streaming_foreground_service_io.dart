// lib/services/streaming_foreground_service_io.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Service to keep AI streaming alive when app is backgrounded or screen locked.
/// Only active on Android - iOS handles background execution differently.
class StreamingForegroundService {
  static bool _isInitialized = false;
  static bool _isRunning = false;

  /// Whether the foreground service is currently running
  static bool get isRunning => _isRunning;

  /// Initialize the foreground task system (call once at app startup)
  static Future<void> initialize() async {
    if (_isInitialized) return;
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ai_streaming_channel',
        channelName: 'AI Streaming',
        channelDescription: 'Keeps AI response streaming active',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showWhen: false,
        enableVibration: false,
        playSound: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
    if (kDebugMode) {
      debugPrint('[ForegroundService] Initialized');
    }
  }

  /// Start the foreground service when streaming begins
  static Future<void> startService() async {
    if (!Platform.isAndroid) return;
    if (_isRunning) return;

    if (!_isInitialized) {
      await initialize();
    }

    // Request notification permission on Android 13+
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // Start the service
    final result = await FlutterForegroundTask.startService(
      notificationTitle: 'Generating response...',
      notificationText: 'AI is responding',
      notificationIcon: null, // Uses default app icon
      notificationButtons: null,
      callback: _foregroundTaskCallback,
    );

    if (result is ServiceRequestSuccess) {
      _isRunning = true;
      if (kDebugMode) {
        debugPrint('[ForegroundService] Started');
      }
    } else if (result is ServiceRequestFailure) {
      if (kDebugMode) {
        debugPrint('[ForegroundService] Failed to start: ${result.error}');
      }
    }
  }

  /// Update the notification with streaming progress
  static Future<void> updateNotification({
    required String content,
    String? title,
  }) async {
    if (!Platform.isAndroid) return;
    if (!_isRunning) return;

    // Truncate content for notification (max ~100 chars)
    String displayContent = content;
    if (displayContent.length > 100) {
      displayContent = '${displayContent.substring(0, 97)}...';
    }

    // Remove newlines for cleaner notification
    displayContent = displayContent.replaceAll('\n', ' ').trim();

    if (displayContent.isEmpty) {
      displayContent = 'AI is responding...';
    }

    await FlutterForegroundTask.updateService(
      notificationTitle: title ?? 'Generating response...',
      notificationText: displayContent,
    );
  }

  /// Stop the foreground service when streaming completes
  static Future<void> stopService() async {
    if (!Platform.isAndroid) return;
    if (!_isRunning) return;

    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestSuccess) {
      _isRunning = false;
      if (kDebugMode) {
        debugPrint('[ForegroundService] Stopped');
      }
    } else if (result is ServiceRequestFailure) {
      if (kDebugMode) {
        debugPrint('[ForegroundService] Failed to stop: ${result.error}');
      }
      // Force reset state anyway
      _isRunning = false;
    }
  }

  /// Check if we can start foreground service (has required permissions)
  static Future<bool> canStart() async {
    if (!Platform.isAndroid) return false;

    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    return notificationPermission == NotificationPermission.granted;
  }
}

/// Callback for foreground task - we don't need to do anything here
/// since our streaming is managed by the main isolate
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  // This runs in a separate isolate, but we don't need it
  // Our streaming runs in the main isolate, this just keeps the service alive
  FlutterForegroundTask.setTaskHandler(_StreamingTaskHandler());
}

/// Minimal task handler - just keeps the service running
class _StreamingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (kDebugMode) {
      debugPrint('[ForegroundTask] onStart');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // No-op - we don't need periodic events
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    if (kDebugMode) {
      debugPrint('[ForegroundTask] onDestroy');
    }
  }

  @override
  void onReceiveData(Object data) {
    // No-op - we don't receive data
  }

  @override
  void onNotificationButtonPressed(String id) {
    // No-op - no buttons
  }

  @override
  void onNotificationPressed() {
    // Bring app to foreground when notification is tapped
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    // No-op
  }
}
