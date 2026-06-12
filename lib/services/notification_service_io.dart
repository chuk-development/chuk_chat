// lib/services/notification_service_io.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

/// Service for handling local notifications (completion notifications with deep linking)
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static GlobalKey<NavigatorState>? _navigatorKey;
  static bool _isInitialized = false;

  /// Brand accent used to tint the notification icon and title on Android.
  static const Color _brandColor = Color(0xFF285DA9);

  /// Initialize the notification service
  static Future<void> initialize(GlobalKey<NavigatorState> navigatorKey) async {
    if (_isInitialized) return;

    _navigatorKey = navigatorKey;

    const androidSettings = AndroidInitializationSettings('ic_notification');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
        linux: linuxSettings,
      ),
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create Android notification channel for completion notifications
    if (Platform.isAndroid) {
      await _createCompletionChannel();
    }

    _isInitialized = true;
    if (kDebugMode) {
      debugPrint('[NotificationService] Initialized');
    }
  }

  /// Create Android notification channel for AI completion notifications
  static Future<void> _createCompletionChannel() async {
    const channel = AndroidNotificationChannel(
      'ai_completion',
      'AI Responses',
      description: 'Notifications when AI responses are complete',
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
      enableLights: true,
      ledColor: _brandColor,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  /// Show a completion notification when AI response is ready
  static Future<void> showCompletionNotification({
    required String chatId,
    required String chatTitle,
    required String contentPreview,
  }) async {
    if (!_isInitialized) {
      if (kDebugMode) {
        debugPrint(
          '[NotificationService] Not initialized, skipping notification',
        );
      }
      return;
    }

    // Only show on Android and iOS for now
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final payload = jsonEncode({'chatId': chatId, 'action': 'open_chat'});
    final preview = contentPreview.isEmpty
        ? 'New AI response'
        : _formatContentPreview(contentPreview);
    // Use the chat name as the title so it is clear which chat replied.
    final trimmedTitle = chatTitle.trim();
    final title = trimmedTitle.isEmpty ? 'AI Chat' : trimmedTitle;

    try {
      await _plugin.show(
        id: chatId.hashCode, // Unique ID per chat
        title: title,
        body: preview,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'ai_completion',
            'AI Responses',
            channelDescription: 'Notifications when AI responses are complete',
            importance: Importance.high,
            priority: Priority.high,
            enableVibration: true,
            playSound: true,
            icon: 'ic_notification',
            color: _brandColor,
            ledColor: _brandColor,
            ledOnMs: 1000,
            ledOffMs: 500,
            // Dismiss the notification as soon as it is tapped.
            autoCancel: true,
            ticker: 'Response ready',
            // Expandable body so the full preview is readable.
            styleInformation: BigTextStyleInformation(
              preview,
              contentTitle: title,
              summaryText: 'Response ready',
            ),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: payload,
      );

      if (kDebugMode) {
        debugPrint(
          '[NotificationService] Showed completion notification for chat $chatId',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationService] Failed to show notification: $e');
      }
    }
  }

  /// Handle notification tap - navigate to the specific chat
  static void _onNotificationTapped(NotificationResponse response) {
    if (response.payload == null || _navigatorKey?.currentState == null) return;

    try {
      final data = jsonDecode(response.payload!);
      final chatId = data['chatId'] as String?;

      if (chatId != null) {
        if (kDebugMode) {
          debugPrint(
            '[NotificationService] Notification tapped, navigating to chat $chatId',
          );
        }
        // Dismiss the tapped notification (and any duplicate for this chat).
        unawaited(_plugin.cancel(id: chatId.hashCode));
        // Update selected chat and navigate
        ChatStorageService.selectedChatId = chatId;
        // Pop to root - the RootWrapper will show the correct chat
        _navigatorKey!.currentState!.popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[NotificationService] Failed to parse notification payload: $e',
        );
      }
    }
  }

  /// Check if app was launched from a notification
  static Future<void> checkLaunchNotification() async {
    if (!_isInitialized) return;

    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        final response = details!.notificationResponse;
        if (response != null) {
          _onNotificationTapped(response);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[NotificationService] Failed to check launch notification: $e',
        );
      }
    }
  }

  /// Format content preview for notification
  static String _formatContentPreview(String content, {int maxLength = 120}) {
    if (content.isEmpty) return '';

    // Strip common markdown
    String cleaned = stripToolCallBlocksForDisplay(content)
        .replaceAll(RegExp(r'```[\s\S]*?```'), '[code]') // Code blocks
        .replaceAll(RegExp(r'`[^`]+`'), '[code]') // Inline code
        .replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1') // Bold
        .replaceAll(RegExp(r'\*([^*]+)\*'), r'$1') // Italic
        .replaceAll(RegExp(r'^#+\s*', multiLine: true), '') // Headers
        .replaceAll(RegExp(r'\n+'), ' ') // Newlines to spaces
        .replaceAll(RegExp(r'\s+'), ' ') // Collapse whitespace
        .trim();

    if (cleaned.length <= maxLength) return cleaned;

    // Truncate at word boundary
    final truncated = cleaned.substring(0, maxLength);
    final lastSpace = truncated.lastIndexOf(' ');

    if (lastSpace > maxLength * 0.7) {
      return '${truncated.substring(0, lastSpace)}...';
    }
    return '${truncated.substring(0, maxLength - 3)}...';
  }

  /// Request notification permission (Android 13+)
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    if (androidPlugin == null) return false;

    final granted = await androidPlugin.requestNotificationsPermission();
    return granted ?? false;
  }
}
