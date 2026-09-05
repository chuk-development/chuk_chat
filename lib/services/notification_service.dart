// CoWork port of chuk_chat/lib/services/notification_service.dart
// (conditional export of notification_service_io.dart / _stub.dart)
// @ d31526a229fdde27c82adf3661d5d3a149db8340.
//
// The imported chat UI (streaming_manager_io.dart) calls this static API when
// a stream completes while chuk's root wrapper reported the app as
// backgrounded. CoWork keeps the signatures and routes them into its own
// notification layer (services/notifications/**, WS-7): one plugin, one
// channel, one toast per thread, and never any answer content in a toast.

import 'package:flutter/material.dart';

import 'package:cowork/services/notifications/cowork_notifications.dart';
import 'package:cowork/services/notifications/local_notifications.dart';

class NotificationService {
  static bool get isInitialized => LocalNotifications.instance.isInitialized;

  /// chuk passes its navigator key; CoWork's shell routes taps itself, so
  /// the key is accepted and unused.
  static Future<void> initialize([GlobalKey<NavigatorState>? navigatorKey]) =>
      CoworkNotifications.instance.initialize();

  static Future<bool> requestPermission() =>
      LocalNotifications.instance.requestPermission();

  /// Older name used by CoWork's own code.
  static Future<bool> requestPermissions() => requestPermission();

  /// chuk's completion toast. `contentPreview` is deliberately NOT shown:
  /// the toast says the answer is ready and names the chat, nothing more.
  static Future<void> showCompletionNotification({
    required String chatId,
    required String chatTitle,
    required String contentPreview,
  }) =>
      LocalNotifications.instance.showAnswerReady(
        sessionKey: chatId,
        threadLabel: chatTitle,
      );

  static Future<void> checkLaunchNotification() =>
      LocalNotifications.instance.checkLaunchNotification();

  static Future<void> cancelAll() async {}
}
