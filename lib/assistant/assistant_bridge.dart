import 'package:flutter/services.dart';

/// Untyped wrappers around the native assistant channel.
///
/// The Kotlin side lives in `android/app/src/main/kotlin/dev/chuk/chat/assist`.
/// A new device capability needs three edits: a wrapper here, a handler in
/// `AssistantHostActivity.kt`, and an `AssistantTool` entry in
/// `assistant_tools.dart`.
///
/// Every method throws [MissingPluginException] on a platform without the
/// channel (everything except Android), so callers must guard on
/// [AssistantPlatform.isSupported] or catch.
class AssistantBridge {
  AssistantBridge._();

  static const MethodChannel _channel = MethodChannel('chuk/assistant');

  /// Starts the microphone foreground service so Android keeps the recording
  /// alive while the overlay is open.
  static Future<void> startVoiceService() async {
    await _channel.invokeMethod<bool>('startVoiceService');
  }

  static Future<void> stopVoiceService() async {
    await _channel.invokeMethod<bool>('stopVoiceService');
  }

  static Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  static Future<void> openNotificationAccessSettings() async {
    await _channel.invokeMethod<void>('openNotificationAccessSettings');
  }

  static Future<void> openOverlaySettings() async {
    await _channel.invokeMethod<void>('openOverlaySettings');
  }

  static Future<void> openAssistantSettings() async {
    await _channel.invokeMethod<void>('openAssistantSettings');
  }

  static Future<void> openAppDetailsSettings() async {
    await _channel.invokeMethod<void>('openAppDetailsSettings');
  }

  static Future<bool> requestAssistantRole() async {
    final value = await _channel.invokeMethod<bool>('requestAssistantRole');
    return value ?? false;
  }

  static Future<bool> isAccessibilityEnabled() async {
    final enabled = await _channel.invokeMethod<bool>('isAccessibilityEnabled');
    return enabled ?? false;
  }

  static Future<Map<String, bool>> getPermissionStatuses() async {
    final value = await _channel.invokeMethod<dynamic>('getPermissionStatuses');
    final map = Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
    return map.map((key, value) => MapEntry(key, value == true));
  }

  static Future<bool> requestContactsPermission() async {
    final value = await _channel.invokeMethod<bool>(
      'requestContactsPermission',
    );
    return value ?? false;
  }

  static Future<bool> requestLocationPermission() async {
    final value = await _channel.invokeMethod<bool>(
      'requestLocationPermission',
    );
    return value ?? false;
  }

  static Future<Map<String, dynamic>> getCurrentContext() async {
    final value = await _channel.invokeMethod<dynamic>('getCurrentContext');
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  static Future<Map<String, dynamic>> collectScrollableContext({
    required String query,
    int maxScrolls = 4,
    bool restoreScroll = true,
  }) async {
    final value = await _channel.invokeMethod<dynamic>(
      'collectScrollableContext',
      {
        'query': query,
        'maxScrolls': maxScrolls,
        'restoreScroll': restoreScroll,
      },
    );
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  static Future<List<Map<String, dynamic>>> getRecentNotifications() async {
    final value = await _channel.invokeMethod<dynamic>(
      'getRecentNotifications',
    );
    final list = (value as List? ?? <dynamic>[])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    return list;
  }

  static Future<Map<String, dynamic>> findContact(String name) async {
    final value = await _channel.invokeMethod<dynamic>('findContact', {
      'name': name,
    });
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  static Future<bool> openDialerForContact(String name) async {
    final value = await _channel.invokeMethod<bool>('openDialerForContact', {
      'name': name,
    });
    return value ?? false;
  }

  static Future<bool> callContactDirect(String phone) async {
    final value = await _channel.invokeMethod<bool>('callContactDirect', {
      'phone': phone,
    });
    return value ?? false;
  }

  static Future<Map<String, dynamic>> openApp(String name) async {
    final value = await _channel.invokeMethod<dynamic>('openApp', {
      'name': name,
    });
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  /// Shows a place in the maps app of the device, or starts navigation to it.
  ///
  /// The Android side names no package, so the user's own maps app handles it.
  /// It also resolves an address to coordinates first — a bare text query only
  /// lands the user on a search result list.
  static Future<Map<String, dynamic>> openMaps({
    required String query,
    double? latitude,
    double? longitude,
    bool navigate = false,
  }) async {
    final value = await _channel.invokeMethod<dynamic>('openMaps', {
      'query': query,
      'latitude': latitude,
      'longitude': longitude,
      'navigate': navigate,
    });
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  static Future<List<Map<String, String>>> listInstalledApps() async {
    final value = await _channel.invokeMethod<dynamic>('listInstalledApps');
    final list = (value as List? ?? <dynamic>[])
        .map((item) => Map<String, String>.from(
              (item as Map).map((k, v) => MapEntry(k.toString(), v.toString())),
            ))
        .toList();
    return list;
  }

  static Future<bool> composeSmsForContact({
    required String name,
    required String message,
  }) async {
    final value = await _channel.invokeMethod<bool>('composeSmsForContact', {
      'name': name,
      'message': message,
    });
    return value ?? false;
  }

  static Future<bool> setTimer({
    required int seconds,
    String message = '',
  }) async {
    final value = await _channel.invokeMethod<bool>('setTimer', {
      'seconds': seconds,
      'message': message,
    });
    return value ?? false;
  }

  /// True if the companion clock app (com.example.uhr_app) is installed, so clock commands can be
  /// driven through it instead of the limited system AlarmClock intents.
  static Future<bool> isClockAppInstalled() async {
    final value = await _channel.invokeMethod<bool>('isClockAppInstalled');
    return value ?? false;
  }

  /// Sends a command to the companion clock app via an explicit broadcast.
  ///
  /// [command] is one of: timer_start, timer_pause, timer_resume, timer_reset, timer_adjust,
  /// timer_stop, timer_stop_all, stopwatch_start, stopwatch_pause, stopwatch_reset, stopwatch_lap.
  /// Returns a map with at least `handled` (bool) and `via` ("uhr_app" | "none").
  static Future<Map<String, dynamic>> clockCommand({
    required String command,
    int? seconds,
    int? deltaSeconds,
    int? timerId,
    String? label,
  }) async {
    final value = await _channel.invokeMethod<dynamic>('clockCommand', {
      'command': command,
      'seconds': ?seconds,
      'deltaSeconds': ?deltaSeconds,
      'timerId': ?timerId,
      'label': ?label,
    });
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  static Future<bool> setAlarm({
    required int hour,
    required int minutes,
    String message = '',
  }) async {
    final value = await _channel.invokeMethod<bool>('setAlarm', {
      'hour': hour,
      'minutes': minutes,
      'message': message,
    });
    return value ?? false;
  }

  static Future<bool> dismissTimer() async {
    final value = await _channel.invokeMethod<bool>('dismissTimer');
    return value ?? false;
  }

  static Future<bool> dismissAlarm() async {
    final value = await _channel.invokeMethod<bool>('dismissAlarm');
    return value ?? false;
  }

  static Future<bool> showTimers() async {
    final value = await _channel.invokeMethod<bool>('showTimers');
    return value ?? false;
  }

  static Future<bool> showAlarms() async {
    final value = await _channel.invokeMethod<bool>('showAlarms');
    return value ?? false;
  }

  static Future<Map<String, dynamic>> getLastKnownLocation() async {
    final value = await _channel.invokeMethod<dynamic>('getLastKnownLocation');
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  static Future<String?> captureScreenshotBase64() async {
    return _channel.invokeMethod<String>('captureScreenshotBase64');
  }

  static Future<bool> clickByText(String text) async {
    final result = await _channel.invokeMethod<bool>('clickByText', {
      'text': text,
    });
    return result ?? false;
  }

  static Future<bool> performGlobalAction(String action) async {
    final result = await _channel.invokeMethod<bool>('performGlobalAction', {
      'action': action,
    });
    return result ?? false;
  }

  /// Hard-cancel timer notifications (last resort if dismiss doesn't fire an action).
  static Future<bool> cancelTimerNotifications() async {
    final value = await _channel.invokeMethod<bool>('cancelTimerNotifications');
    return value ?? false;
  }

  /// Media transport command: play, pause, toggle, next, previous, stop.
  static Future<bool> mediaCommand(String command) async {
    final value = await _channel.invokeMethod<bool>('mediaCommand', {
      'command': command,
    });
    return value ?? false;
  }

  /// Returns metadata of the currently-playing media session.
  /// Pass [packageName] to restrict to a specific player (e.g. "com.spotify.music").
  static Future<Map<String, dynamic>> getNowPlaying({String? packageName}) async {
    final value = await _channel.invokeMethod<dynamic>('getNowPlaying', {
      'packageName': ?packageName,
    });
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  /// direction: up, down, mute, unmute, toggle_mute.
  static Future<bool> volumeAdjust(String direction, {bool showUi = true}) async {
    final value = await _channel.invokeMethod<bool>('volumeAdjust', {
      'direction': direction,
      'showUi': showUi,
    });
    return value ?? false;
  }

  static Future<bool> volumeSet(int percent, {bool showUi = true}) async {
    final value = await _channel.invokeMethod<bool>('volumeSet', {
      'percent': percent,
      'showUi': showUi,
    });
    return value ?? false;
  }

  static Future<Map<String, dynamic>> volumeGet() async {
    final value = await _channel.invokeMethod<dynamic>('volumeGet');
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }

  /// Opens Spotify (or web fallback) on a search results page for [query].
  static Future<Map<String, dynamic>> spotifySearch(String query) async {
    final value = await _channel.invokeMethod<dynamic>('spotifySearch', {
      'query': query,
    });
    return Map<String, dynamic>.from(value as Map? ?? <String, dynamic>{});
  }
}
