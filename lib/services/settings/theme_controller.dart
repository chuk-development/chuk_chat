import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's theme mode, persisted so the choice survives a restart.
///
/// A [ValueNotifier] so [MaterialApp] can rebuild on a change with a plain
/// [ValueListenableBuilder] — no extra state-management dependency. The
/// controller loads its stored value lazily the first time it is asked to,
/// and never throws: a storage failure just leaves the system default.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController([super.initial = ThemeMode.system]);

  static const String _prefsKey = 'theme_mode_v1';

  bool _loaded = false;

  /// Read the stored mode into [value]. Idempotent: the disk read runs once.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      value = _parse(prefs.getString(_prefsKey));
    } catch (_) {
      // No preference is a valid state — keep the system default.
    }
  }

  /// Set the mode and persist it. A storage failure still updates the live
  /// value, so the app follows the choice for the session either way.
  Future<void> setMode(ThemeMode mode) async {
    value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, mode.name);
    } catch (_) {
      // Losing the preference is a small annoyance, not a crash.
    }
  }

  static ThemeMode _parse(String? raw) {
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return ThemeMode.system;
  }

  /// A short human label for a mode, for the settings row and picker.
  static String label(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }
}
