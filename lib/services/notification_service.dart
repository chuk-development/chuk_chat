// Agents port of chuk_chat/lib/services/notification_service.dart
// (conditional export of notification_service_io.dart / _stub.dart)
// @ d31526a229fdde27c82adf3661d5d3a149db8340.
//
// The imported chat UI (streaming_manager_io.dart) calls this static API when
// a stream completes while chuk's root wrapper reported the app as
// backgrounded. Agents keeps the signatures and routes them into its own
// notification layer (services/notifications/**, WS-7): one plugin, one
// channel, one toast per thread. Answer text goes into a toast only when the
// user turned on "Show answer preview in notifications" (default off); the
// preview is then made on the device.

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/notifications/local_notifications.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

class NotificationService {
  static bool get isInitialized => LocalNotifications.instance.isInitialized;

  /// chuk passes its navigator key; Agents's shell routes taps itself, so
  /// the key is accepted and unused.
  static Future<void> initialize([GlobalKey<NavigatorState>? navigatorKey]) =>
      AgentsNotifications.instance.initialize();

  static Future<bool> requestPermission() =>
      LocalNotifications.instance.requestPermission();

  /// Older name used by Agents's own code.
  static Future<bool> requestPermissions() => requestPermission();

  /// chuk's completion toast: the chat's title, and a short preview of the
  /// answer (built on this device) only when the user turned the preview
  /// setting on ([LocalNotifications.showAnswerPreviewKey], default off).
  ///
  /// Not for an Agents thread: its toast comes from the thread view's live
  /// `done` ([AgentsNotifications.onLiveDone]), which knows the coworker's
  /// name and the run, and the host's push covers a thread nobody had open.
  /// A second toast from here would land in the same slot and overwrite that
  /// one with the chat title (bead chuk_chat-kl8x).
  static Future<void> showCompletionNotification({
    required String chatId,
    required String chatTitle,
    required String contentPreview,
  }) async {
    if (ChatOrigin.isAgentsThread(chatId)) return;
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: chatId,
      threadLabel: chatTitle,
      preview: contentPreview,
    );
  }

  static Future<void> checkLaunchNotification() =>
      LocalNotifications.instance.checkLaunchNotification();

  static Future<void> cancelAll() async {}
}
