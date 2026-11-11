// lib/services/settings/tool_detail_service.dart
//
// The "Tool detail" setting: how much of a turn's tool work the chat shows.
// It changes only what the client draws, never what the model does.
//
// | Mode     | Groups while running | Groups once done | Done turn       |
// |----------|----------------------|------------------|-----------------|
// | Compact  | closed, title only   | closed           | folds           |
// | Standard | closed, title+detail | closed           | folds           |
// | Detailed | open                 | closed           | folds           |
// | Verbose  | open                 | open             | stays open      |
//
// A turn with a failed step never folds by itself, in every mode.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How much tool detail the chat shows. Default [standard].
enum ToolDetailMode {
  compact,
  standard,
  detailed,
  verbose;

  /// Running group titles carry the live detail (" · pnpm test").
  bool get showsLiveDetail => this != ToolDetailMode.compact;

  /// A running group shows its steps without a tap.
  bool get opensRunningGroups =>
      this == ToolDetailMode.detailed || this == ToolDetailMode.verbose;

  /// A finished group shows its steps without a tap.
  bool get opensSettledGroups => this == ToolDetailMode.verbose;

  /// A finished turn stays open instead of folding to one line.
  bool get keepsSettledTurnOpen => this == ToolDetailMode.verbose;

  /// Each finished step prints a one-line result.
  bool get showsResultSummaries =>
      this == ToolDetailMode.detailed || this == ToolDetailMode.verbose;

  /// Read a stored name; anything unknown is [standard].
  static ToolDetailMode parse(String? raw) {
    for (final ToolDetailMode mode in ToolDetailMode.values) {
      if (mode.name == raw) return mode;
    }
    return ToolDetailMode.standard;
  }
}

/// The persisted [ToolDetailMode], one shared instance.
class ToolDetailService extends ValueNotifier<ToolDetailMode> {
  ToolDetailService._() : super(ToolDetailMode.standard);

  static final ToolDetailService instance = ToolDetailService._();

  /// Stable storage key. Do not change it: a change drops the saved choice.
  static const String prefsKey = 'tool_detail_mode';

  bool _loaded = false;

  /// Read the stored mode. Runs once; never throws.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      value = ToolDetailMode.parse(prefs.getString(prefsKey));
    } catch (_) {
      // No stored value is a valid state: keep the default.
    }
  }

  /// Set and store the mode. The live value changes even if the write fails.
  Future<void> setMode(ToolDetailMode mode) async {
    _loaded = true;
    value = mode;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, mode.name);
    } catch (_) {}
  }

  /// Test hook: back to the default, as if nothing was stored.
  @visibleForTesting
  void debugReset() {
    _loaded = false;
    value = ToolDetailMode.standard;
  }
}
