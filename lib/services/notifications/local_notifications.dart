/// App-local notifications: the OS toast the app itself shows.
///
/// Port of chuk_chat's `notification_service_io.dart` (d31526a) to Agents,
/// changed by WS-7 and CHAT-128 (docs/agents/NOTIFICATIONS.md):
///
///  * **Every desktop is on.** Linux talks to the desktop over D-Bus,
///    Windows uses `flutter_local_notifications_windows`, macOS and the
///    phones use the plugin's own code.
///  * **Title is the agent, body is the answer.** The title is the agent's
///    name (rule 1). The body is a short preview of the answer, made on this
///    device (rule 2). The user can turn the preview off with "Show answer
///    preview in notifications" ([showAnswerPreviewKey], default on); the
///    body is then content-free ("Your answer is ready."). A stopped run
///    keeps its plain sentence. On Android the toast is always
///    `NotificationVisibility.private`, so a secure lock screen shows the
///    system's content-free placeholder, not the body.
///  * **The icon is the agent's face** (rule 3): a PNG file from
///    [AgentNotificationAvatar]. Android shows it as the large icon (the
///    small icon stays the monochrome app mark), Linux as the toast image,
///    macOS/iOS as an attachment, Windows as the app logo override. No
///    file: the app logo, as before.
///  * **One toast per thread.** On Android the slot is the session key as tag
///    and id 0 — exactly the slot the FCM push for the thread uses — so the
///    app's toast and the host's push replace each other instead of stacking,
///    and one `cancel` clears both. Elsewhere the id is the key's hash.
///
/// The plugin is behind [LocalNotificationsBackend] so the tests drive the
/// service without a platform channel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/notifications/notification_avatar.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';

/// The Android channel every Agents toast lands in.
const String kAgentsNotificationChannelId = 'cowork_answer_ready';
const String kAgentsNotificationChannelName = 'Answer ready';
const String kAgentsNotificationChannelDescription =
    'An agent finished a task or needs your input';

/// The logo a Linux toast draws. The same image the Android launcher uses,
/// copied into the Flutter assets because a Linux build ships no icon of its
/// own and the D-Bus call takes the picture, not an app id.
const String kAgentsNotificationIconAsset = 'assets/icons/app_icon.png';

/// What the service needs from the platform. The real one wraps
/// `FlutterLocalNotificationsPlugin`; tests pass a fake.
abstract class LocalNotificationsBackend {
  Future<bool> initialize({required void Function(String? payload) onTap});

  /// [iconPath] is the agent's avatar PNG, or null for the app logo.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required String tag,
    String? iconPath,
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

  /// The body when there is no answer text to preview.
  static const String defaultBody = 'Your answer is ready.';

  /// SharedPreferences key of the user setting "Show answer preview in
  /// notifications". Default on (CHAT-128). Off: the toast carries no
  /// answer text.
  static const String showAnswerPreviewKey =
      'notifications_show_answer_preview';

  /// Whether the toast may carry answer text. True when the setting was
  /// never set. False when it cannot be read (the safe side).
  static Future<bool> answerPreviewEnabled() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getBool(showAnswerPreviewKey) ?? true;
    } catch (error) {
      if (kDebugMode) debugPrint('[LocalNotifications] pref read: $error');
      return false;
    }
  }

  /// The body of a stopped or failed run. It never carries answer text.
  static const String stoppedBody = 'Open the chat to see what happened.';

  /// Finds the avatar PNG of an agent. Test seam; the default paints (or
  /// reuses) the file with [AgentNotificationAvatar].
  @visibleForTesting
  static Future<String?> Function(String agentId, String name) avatarPath =
      _defaultAvatarPath;

  static Future<String?> _defaultAvatarPath(String agentId, String name) =>
      AgentNotificationAvatar.instance
          .ensure(agentId, name: name)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);

  static Future<void> setAnswerPreviewEnabled(bool enabled) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(showAnswerPreviewKey, enabled);
  }

  /// The toast for a finished run of [sessionKey]. The title is
  /// [threadLabel] (the agent's name, or the chat's title). [preview] (the
  /// answer, made short by [notificationPreview]) is the body unless the
  /// user turned [showAnswerPreviewKey] off. [stopped] is a run that ended
  /// without finishing: its body is always [stoppedBody]. [agentId] selects
  /// the avatar icon.
  Future<void> showAnswerReady({
    required String sessionKey,
    required String threadLabel,
    String? runId,
    String? preview,
    bool stopped = false,
    String? agentId,
  }) async {
    if (_backend == null) return;
    final String label = threadLabel.trim();
    final String who = label.isEmpty ? 'Chuk Chat' : label;
    final String text = !stopped && await answerPreviewEnabled()
        ? notificationPreview(preview ?? '')
        : '';
    String? icon;
    if (agentId != null && agentId.isNotEmpty) {
      try {
        icon = await avatarPath(agentId, who);
      } catch (_) {
        icon = null;
      }
    }
    await showText(
      sessionKey: sessionKey,
      title: who,
      body: text.isNotEmpty ? text : (stopped ? stoppedBody : defaultBody),
      runId: runId,
      iconPath: icon,
    );
  }

  /// Shows a toast whose text is already final: the opened push preview, or
  /// its generic fallback. [iconPath] is the avatar PNG, or null.
  Future<void> showText({
    required String sessionKey,
    required String title,
    required String body,
    String? runId,
    String? iconPath,
  }) async {
    final LocalNotificationsBackend? b = _backend;
    if (b == null) return;
    try {
      await b.show(
        id: idFor(sessionKey),
        title: title,
        body: body,
        payload: payloadFor(sessionKey, runId: runId),
        tag: sessionKey,
        iconPath: iconPath,
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

  /// The Android half of a toast. Always [NotificationVisibility.private]:
  /// a secure lock screen shows the system's content-free placeholder
  /// instead of the body, even with the answer preview on. (The plugin has
  /// no `publicVersion`; Android's own placeholder is the public version.)
  @visibleForTesting
  static AndroidNotificationDetails androidDetails({
    required String title,
    required String body,
    required String tag,
    String? largeIconPath,
  }) {
    const Color brand = Color(brandColorValue);
    return AndroidNotificationDetails(
      kAgentsNotificationChannelId,
      kAgentsNotificationChannelName,
      channelDescription: kAgentsNotificationChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      // The small icon stays the monochrome app mark; the agent's face is
      // the large icon.
      icon: 'ic_notification',
      largeIcon: largeIconPath == null
          ? null
          : FilePathAndroidBitmap(largeIconPath),
      color: brand,
      ledColor: brand,
      ledOnMs: 1000,
      ledOffMs: 500,
      autoCancel: true,
      // One outstanding notification per thread, shared with the push.
      tag: tag,
      // The ticker reaches accessibility services: title only, never body.
      ticker: title,
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.private,
      // The whole body when the row is expanded.
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
    );
  }

  /// Test seam.
  @visibleForTesting
  void reset() {
    _backend = null;
    _initialized = false;
  }
}

/// Windows toast registration. The GUID names the activation callback; it
/// must stay the same across releases.
const String kWindowsNotificationAppId = 'dev.chuk.chat';
const String kWindowsNotificationGuid = '6f1c2b7e-3a4d-4f0b-9c8e-2d5a7b1e4c90';

/// The real backend: `flutter_local_notifications` on Android, iOS, macOS,
/// Linux and Windows. Not reachable from a widget test (platform channels), which is
/// why the service takes a backend.
class _PluginBackend implements LocalNotificationsBackend {
  _PluginBackend(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static bool get _supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isWindows;

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
        windows: const WindowsInitializationSettings(
          appName: 'Chuk Chat',
          appUserModelId: kWindowsNotificationAppId,
          guid: kWindowsNotificationGuid,
        ),
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
    String? iconPath,
  }) async {
    final String? icon = iconPath != null && File(iconPath).existsSync()
        ? iconPath
        : null;
    // iOS and macOS move an attachment into their own store, so each toast
    // gets its own copy of the avatar file.
    final String? darwinIcon =
        icon != null && (Platform.isIOS || Platform.isMacOS)
        ? await _attachmentCopy(icon, id)
        : null;
    final DarwinNotificationDetails darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      attachments: darwinIcon == null
          ? null
          : <DarwinNotificationAttachment>[
              DarwinNotificationAttachment(darwinIcon),
            ],
    );
    return _plugin.show(
      // Android: the FCM push for a thread is (tag, 0). The same slot here
      // means the app's toast and the push replace each other, never stack.
      id: Platform.isAndroid ? 0 : id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: LocalNotifications.androidDetails(
          title: title,
          body: body,
          tag: tag,
          largeIconPath: icon,
        ),
        iOS: darwin,
        macOS: darwin,
        linux: LinuxNotificationDetails(
          urgency: LinuxNotificationUrgency.normal,
          icon: icon != null
              ? FilePathLinuxIcon(icon)
              : AssetsLinuxIcon(kAgentsNotificationIconAsset),
        ),
        windows: WindowsNotificationDetails(
          images: icon == null
              ? const <WindowsImage>[]
              : <WindowsImage>[
                  WindowsImage(
                    Uri.file(icon, windows: true),
                    altText: title,
                    placement: WindowsImagePlacement.appLogoOverride,
                    crop: WindowsImageCrop.circle,
                  ),
                ],
        ),
      ),
    );
  }

  /// A copy of [path] in the temp directory, or null when the copy fails
  /// (the toast then shows without the picture).
  static Future<String?> _attachmentCopy(String path, int id) async {
    try {
      final Directory tmp = await getTemporaryDirectory();
      final String target =
          '${tmp.path}/notification_avatar_${id}_'
          '${DateTime.now().microsecondsSinceEpoch}.png';
      await File(path).copy(target);
      return target;
    } catch (_) {
      return null;
    }
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

/// The answer, made fit for one notification (docs/agents/NOTIFICATIONS.md,
/// rule 2): markdown and the app's own render tags removed, whitespace
/// folded, cut at a word near [maxChars] (300) and marked with `…`.
/// Empty when nothing readable is left.
String notificationPreview(String raw, {int maxChars = 300}) {
  if (raw.trim().isEmpty) return '';
  String text = raw;
  // Blocks the UI renders as cards or code carry no sentence worth reading.
  text = text.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ');
  text = text.replaceAll(
    RegExp(
      r'<(chart|map|email|think|thinking|artifact)\b[^>]*>[\s\S]*?(</\1>|$)',
      caseSensitive: false,
    ),
    ' ',
  );
  text = text.replaceAll(RegExp(r'<[^>\n]{1,80}>'), ' ');
  // Links keep their text, images go.
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  // Line markers: headings, quotes, list bullets, table rules.
  text = text.replaceAll(
    RegExp(r'^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+', multiLine: true),
    '',
  );
  text = text.replaceAll(
    RegExp(r'^\s*\|?[\s:|-]{3,}\|?\s*$', multiLine: true),
    ' ',
  );
  text = text.replaceAll('|', ' ');
  // Emphasis and inline code marks.
  text = text.replaceAll(RegExp(r'[*_`~]{1,3}'), '');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= maxChars) return text;
  final String cut = text.substring(0, maxChars);
  final int space = cut.lastIndexOf(' ');
  final String head = space > maxChars * 0.6 ? cut.substring(0, space) : cut;
  return '${head.trimRight()}\u2026';
}
