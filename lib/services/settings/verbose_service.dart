// lib/services/settings/verbose_service.dart
//
// The "verbose view" switch. Off by default. Off, the user sees only the
// result of a task. On, the client shows every command, every MCP call, and
// every browser action as a log.
//
// This switch changes only what the client SHOWS. It never changes what the
// agent does. The server always streams the events. The switch decides if the
// client renders them.
//
// This service is the one true store for the switch. The thread view and the
// settings pages all read it, so they always agree.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The persisted verbose-view switch, as a [ChangeNotifier] singleton.
///
/// Call [load] once at startup to read the stored value. A read is safe before
/// [load]: [enabled] returns the default (false) until the stored value is in.
class VerboseService extends ChangeNotifier {
  VerboseService._();

  /// The one shared instance. All readers use it, so all readers agree.
  static final VerboseService instance = VerboseService._();

  /// The stable key for the stored switch. Do not change it. A change would
  /// drop the user's saved choice.
  static const String _prefsKey = 'verbose_view_enabled';

  /// The old developer key for the same idea. [load] adopts its value when the
  /// new key is not set yet, so an old choice still holds after the upgrade.
  static const String _legacyKey = 'dev_verbose_logging';

  bool _enabled = false;
  bool _loaded = false;

  /// Whether the client shows the full log. Default false. Safe to read before
  /// [load]: it returns the default until the stored value is read.
  bool get enabled => _enabled;

  /// Whether [load] has run. A page can show a spinner until this is true.
  bool get loaded => _loaded;

  /// Read the stored value into [enabled]. Idempotent: the disk read runs once.
  /// Never throws. A storage failure leaves the default (false).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Prefer the new key. Fall back to the old developer key so an earlier
      // choice still holds. Default false when neither is set.
      final stored = prefs.getBool(_prefsKey) ?? prefs.getBool(_legacyKey);
      _enabled = stored ?? false;
    } catch (_) {
      // No stored value is a valid state. Keep the default (false).
    }
    notifyListeners();
  }

  /// Set the switch and persist it. Always updates the live value and notifies
  /// listeners, so the UI follows the choice even if the write fails. Writes
  /// the old key too, so any reader that still uses it agrees.
  Future<void> setEnabled(bool value) async {
    _loaded = true;
    if (_enabled != value) {
      _enabled = value;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
      // Mirror the old key so an old reader sees the same value.
      await prefs.setBool(_legacyKey, value);
    } catch (_) {
      // Losing the stored value is a small annoyance, not a crash. The live
      // value still holds for the session.
    }
  }
}
