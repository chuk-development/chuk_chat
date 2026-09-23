/// Local, per-device debug switches (§ developer settings).
///
/// These change nothing on the host by themselves — they only ask the client to
/// send a little more on a task and to keep what comes back, so a developer can
/// inspect it. Off by default, so a normal run sends and keeps nothing extra.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// Reads and writes the developer debug toggles, so the settings page and the
/// thread view agree on one key instead of each spelling it out.
abstract final class DebugSettings {
  /// "Capture model context": when on, each task rides with `debug: true`, so
  /// the executor echoes back the raw context it sent to the model, and the
  /// thread view keeps the latest one for the copy button.
  static const String captureContextKey = 'dev_capture_context';

  /// The stored "capture model context" value. Defaults to false, including
  /// when the store is unavailable (a locked keystore, a missing plugin in a
  /// test), so a read never throws.
  static Future<bool> captureContext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(captureContextKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Persists the "capture model context" value. A storage failure is swallowed:
  /// the live toggle still holds for the session.
  static Future<void> setCaptureContext(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(captureContextKey, value);
    } catch (_) {
      // The live toggle still holds for the session.
    }
  }
}
