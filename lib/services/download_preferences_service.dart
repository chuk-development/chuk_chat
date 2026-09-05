// lib/services/download_preferences_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preferences for how downloaded files are saved across the app.
/// Backed by SharedPreferences so settings persist per-device.
class DownloadPreferencesService {
  const DownloadPreferencesService._();

  static const String _alwaysAskKey = 'download_always_ask';
  static const String _defaultFolderKey = 'download_default_folder';

  /// Notifier for the "always ask" toggle. Defaults to true so users are
  /// prompted by default and never get files written silently to disk.
  static final ValueNotifier<bool> alwaysAskNotifier = ValueNotifier<bool>(true);

  /// Notifier for the configured default download folder, or null if unset.
  static final ValueNotifier<String?> defaultFolderNotifier =
      ValueNotifier<String?>(null);

  static Future<void>? _loadFuture;

  /// Idempotent and concurrency-safe: parallel callers all await the same
  /// in-flight load instead of racing to overwrite the notifiers with
  /// default values.
  static Future<void> ensureLoaded() {
    return _loadFuture ??= _loadFromPrefs();
  }

  static Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final ask = prefs.getBool(_alwaysAskKey);
    if (ask != null) {
      alwaysAskNotifier.value = ask;
    }
    final folder = prefs.getString(_defaultFolderKey);
    if (folder != null && folder.isNotEmpty) {
      defaultFolderNotifier.value = folder;
    }
  }

  static Future<void> setAlwaysAsk(bool value) async {
    alwaysAskNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_alwaysAskKey, value);
  }

  static Future<void> setDefaultFolder(String? path) async {
    final normalized = (path == null || path.trim().isEmpty) ? null : path;
    defaultFolderNotifier.value = normalized;
    final prefs = await SharedPreferences.getInstance();
    if (normalized == null) {
      await prefs.remove(_defaultFolderKey);
    } else {
      await prefs.setString(_defaultFolderKey, normalized);
    }
  }

  /// True when the next download should bypass the system save dialog and
  /// write straight to [defaultFolder]. Otherwise the caller must prompt.
  static bool get shouldSkipPrompt {
    if (alwaysAskNotifier.value) return false;
    final folder = defaultFolderNotifier.value;
    return folder != null && folder.isNotEmpty;
  }

  static String? get defaultFolder => defaultFolderNotifier.value;
  static bool get alwaysAsk => alwaysAskNotifier.value;
}
