/// App-local notifications: the OS toast the app itself shows.
///
/// Port of chuk_chat's `notification_service_io.dart` (d31526a) to Agents,
/// with three changes that follow WS-7:
///
///  * **Linux is on.** chuk only toasted on Android/iOS; Agents's running
///    target is the Linux desktop, and a run ends while the window is behind
///    another one. `flutter_local_notifications_linux` talks to the desktop
///    over D-Bus, no daemon of ours.
///  * **No answer content.** The toast says "Answer ready" and names the
///    coworker. chuk put a preview of the reply in the body; here the reply
///    stays end-to-end between the host and the app, like the push does.
///  * **One toast per thread.** The id is the session key's hash, and on
///    Android the tag is the session key — the same tag the FCM push uses —
///    so the newest notification for a thread replaces the older one and one
///    `cancel` clears both channels.
///
/// The plugin is behind [LocalNotificationsBackend] so the tests drive the
/// service without a platform channel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:chuk_chat/services/notifications/notification_router.dart';

/// The Android channel every Agents toast lands in.
const String kAgentsNotificationChannelId = 'cowork_answer_ready';
const String kAgentsNotificationChannelName = 'Answer ready';
const String kAgentsNotificationChannelDescription =
    'A coworker finished a task or needs your input';

/// The logo a Linux toast draws. The same image the Android launcher uses,
/// copied into the Flutter assets because a Linux build ships no icon of its
/// own and the D-Bus call takes the picture, not an app id.
const String kAgentsNotificationIconAsset = 'assets/icons/app_icon.png';

/// What the service needs from the platform. The real one wraps
/// `FlutterLocalNotificationsPlugin`; tests pass a fake.
abstract class LocalNotificationsBackend {
  Future<bool> initialize({required void Function(String? payload) onTap});

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required String tag,
  });

  Future<void> cancel({required int id, required String tag});

  /// The payload of the notification that launched the app, when one did.
  Future<String?> launchPayload();

  /// Android 13+ runtime permission. True where no permission exists.
  Future<bool> requestPermission();
}

class LocalNotifications {
  LocalNotifications._();

  static final LocalNotifications instance = LocalNotifications._();

  LocalNotificationsBackend? _backend;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Brand accent used to tint the icon and title on Android (chuk's blue).
  static const int brandColorValue = 0xFF285DA9;

  /// Wires the platform plugin. Safe to call twice; a failure (no D-Bus
  /// session on a headless Linux, a missing plugin in a test binary) is
  /// swallowed: the app runs without toasts, nothing else changes.
  Future<void> initialize({LocalNotificationsBackend? backend}) async {
    if (_initialized) return;
    final LocalNotificationsBackend b =
        backend ?? _PluginBackend(FlutterLocalNotificationsPlugin());
    try {
      final bool ok = await b.initialize(onTap: _onTap);
      if (!ok) return;
      _backend = b;
      _initialized = true;
      if (kDebugMode) debugPrint('[LocalNotifications] initialised');
    } catch (error) {
      if (kDebugMode) debugPrint('[LocalNotifications] init failed: $error');
    }
  }

  /// Stable id per thread, so a newer toast replaces the older one.
  static int idFor(String sessionKey) => sessionKey.hashCode & 0x7fffffff;

  static String payloadFor(String sessionKey, {String? runId}) =>
      jsonEncode(<String, String>{'session_key': sessionKey, 'run_id': ?runId});

  /// "Answer ready" for [sessionKey]. [threadLabel] is the coworker's name
  /// (or whatever the shell calls the thread) — never the answer.
  Future<void> showAnswerReady({
    required String sessionKey,
    required String threadLabel,
    String? runId,
    String body = 'Your answer is ready.',
  }) async {
    final LocalNotificationsBackend? b = _backend;
    if (b == null) return;
    final String label = threadLabel.trim();
    try {
      await b.show(
        id: idFor(sessionKey),
        title: label.isEmpty ? 'Chuk Chat' : label,
        body: body,
        payload: payloadFor(sessionKey, runId: runId),
        tag: sessionKey,
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[LocalNotifications] show failed: $error');
    }
  }

  /// Clears the thread's toast — ours and, on Android, the FCM one that
  /// shares the tag. Called once the answer is on screen.
  Future<void> cancelForSession(String sessionKey) async {
    final LocalNotificationsBackend? b = _backend;
    if (b == null) return;
    try {
      await b.cancel(id: idFor(sessionKey), tag: sessionKey);
    } catch (error) {
      if (kDebugMode) debugPrint('[LocalNotifications] cancel failed: $error');
    }
  }

  /// A cold start from a toast: hand the target to the router so the shell
  /// opens the thread as soon as it is built.
  Future<void> checkLaunchNotification() async {
    final LocalNotificationsBackend? b = _backend;
    if (b == null) return;
    try {
      _onTap(await b.launchPayload());
    } catch (error) {
      if (kDebugMode) debugPrint('[LocalNotifications] launch check: $error');
    }
  }

  Future<bool> requestPermission() async {
    final LocalNotificationsBackend? b = _backend;
    if (b == null) return false;
    try {
      return await b.requestPermission();
    } catch (_) {
      return false;
    }
  }

  void _onTap(String? payload) {
    if (payload == null || payload.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(payload);
      final NotificationTarget? target = NotificationTarget.fromData(
        decoded is Map ? decoded : null,
      );
      if (target == null) return;
      // The tapped toast is gone; the shell replays the thread.
      unawaited(cancelForSession(target.sessionKey));
      NotificationRouter.instance.open(target);
    } catch (error) {
      if (kDebugMode) debugPrint('[LocalNotifications] bad payload: $error');
    }
  }

  /// Test seam.
  @visibleForTesting
  void reset() {
    _backend = null;
    _initialized = false;
  }
}

/// The real backend: `flutter_local_notifications` on Android, iOS, macOS
/// and Linux. Not reachable from a widget test (platform channels), which is
/// why the service takes a backend.
class _PluginBackend implements LocalNotificationsBackend {
  _PluginBackend(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static bool get _supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;

  @override
  Future<bool> initialize({
    required void Function(String? payload) onTap,
  }) async {
    if (!_supported) return false;
    const androidSettings = AndroidInitializationSettings('ic_notification');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    final linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
      // A D-Bus notification shows a logo only when the sender hands one over:
      // the desktop entry is not consulted, and a Linux build installs no
      // themed icon, so without this the toast has an empty icon slot.
      defaultIcon: AssetsLinuxIcon(kAgentsNotificationIconAsset),
    );
    final bool? ok = await _plugin.initialize(
      settings: InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
        linux: linuxSettings,
      ),
      onDidReceiveNotificationResponse: (NotificationResponse response) =>
          onTap(response.payload),
    );
    if (ok == false) return false;
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              kAgentsNotificationChannelId,
              kAgentsNotificationChannelName,
              description: kAgentsNotificationChannelDescription,
              importance: Importance.high,
              enableVibration: true,
              playSound: true,
              enableLights: true,
              ledColor: Color(LocalNotifications.brandColorValue),
            ),
          );
    }
    return true;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required String tag,
  }) {
    const Color brand = Color(LocalNotifications.brandColorValue);
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          kAgentsNotificationChannelId,
          kAgentsNotificationChannelName,
          channelDescription: kAgentsNotificationChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_notification',
          color: brand,
          ledColor: brand,
          ledOnMs: 1000,
          ledOffMs: 500,
          autoCancel: true,
          // One outstanding notification per thread, shared with the push.
          tag: tag,
          ticker: 'Answer ready',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        linux: LinuxNotificationDetails(
          urgency: LinuxNotificationUrgency.normal,
          icon: AssetsLinuxIcon(kAgentsNotificationIconAsset),
        ),
      ),
    );
  }

  @override
  Future<void> cancel({required int id, required String tag}) async {
    await _plugin.cancel(id: id, tag: Platform.isAndroid ? tag : null);
    if (Platform.isAndroid) {
      // The FCM notification for the same thread carries id 0 + the tag.
      await _plugin.cancel(id: 0, tag: tag);
    }
  }

  @override
  Future<String?> launchPayload() async {
    // Only the mobile platforms know which notification launched the app;
    // the Linux implementation throws UnimplementedError.
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  @override
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    return await android.requestNotificationsPermission() ?? false;
  }
}
