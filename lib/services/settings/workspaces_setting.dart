// lib/services/settings/workspaces_setting.dart
//
// The "Workspaces" setting: custom AI personas with a system prompt, files
// and memory. Off by default in every build; the user turns it on under
// Settings. It replaced the FEATURE_WORKSPACES build flag (2026-11-11).
//
// Off only hides the entry points (sidebar, rail, composer picker, @-menu).
// Nothing is deleted: turning it on again brings every workspace back.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether Workspaces are on. One shared instance; default off.
class WorkspacesSetting extends ValueNotifier<bool> {
  WorkspacesSetting._() : super(false);

  static final WorkspacesSetting instance = WorkspacesSetting._();

  /// Stable storage key. Do not change it: a change drops the saved choice.
  static const String prefsKey = 'workspaces_enabled';

  bool _loaded = false;

  /// Read the stored choice. Runs once; never throws.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      value = prefs.getBool(prefsKey) ?? false;
    } catch (_) {
      // No stored value is a valid state: keep the default (off).
    }
  }

  /// Set and store the choice. The live value changes even if the write fails.
  Future<void> setEnabled(bool enabled) async {
    _loaded = true;
    value = enabled;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, enabled);
    } catch (_) {
      // The choice still holds for this run.
    }
  }

  /// Test hook: back to the unloaded default.
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    value = false;
  }
}

/// Shorthand for call sites: are Workspaces on right now?
bool get workspacesEnabled => WorkspacesSetting.instance.value;
