/// Which half of the Agents build is in front: chuk_chat's own chats
/// ("Chats") or the agents ("Agents").
///
/// Only the Agents build (`FEATURE_AGENTS=true`) has two halves. The switch at
/// the top of both (`widgets/app_mode_switch.dart`) writes here, and the
/// messenger shell shows the half this names. The plain build never reads it.
/// Home (the dashboard the agents build, docs/DASHBOARD.md) is not a mode: it
/// is the first page of the Agents half, and the shell keeps that state.
///
/// The choice is remembered per device in SharedPreferences under
/// [AppModeService.prefsKey]. With nothing remembered, a device that holds a
/// pairing opens on Agents (it has a computer to talk to), and a device
/// without one opens on Chats: Agents has nothing for it but the "Add your
/// computer" path, and chuk chat works right away. The default is not
/// written: only a choice the user made is.
///
/// Stored values of older builds: `chat` (the plain chats, before
/// 2026-11-02) reads as Chats; `home` (the dashboard as a half of its own,
/// 2026-11-02 to 2026-11-05) reads as Agents, where Home lives now.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two halves, in the order the switch shows them: Chats on the left,
/// Agents on the right.
enum AppMode { chats, agents }

/// The current [AppMode], with its persistence.
///
/// A plain [ValueNotifier]: the shell listens to it, and the switch writes it
/// through [select]. Nothing here can throw into the UI: a preference that
/// cannot be read or written costs the next launch its remembered choice,
/// nothing more.
class AppModeService extends ValueNotifier<AppMode> {
  /// [initial] is what the shell shows until [load] has answered. Agents, by
  /// default: it is where a device with a computer lands, so the common case
  /// never sees the other half flash first.
  AppModeService({AppMode initial = AppMode.agents}) : super(initial);

  /// The preference key of the remembered choice (`chats` or `agents`; the
  /// old `chat` and `home` are read too, see [parse]).
  static const String prefsKey = 'app_home_mode';

  /// How long the default may wait for the pairing store. It lives in secure
  /// storage, which can be slow to open; past this the shell keeps what it
  /// shows.
  static const Duration pairingTimeout = Duration(seconds: 2);

  bool _loaded = false;
  bool _chosen = false;
  bool _disposed = false;

  /// Whether [load] has answered.
  bool get loaded => _loaded;

  /// Reads the remembered choice, or works out the default.
  ///
  /// [hasPairing] answers whether this device holds a pairing record. It is
  /// only asked when nothing is remembered. A choice the user makes while
  /// this runs wins over whatever it finds.
  Future<void> load({required Future<bool> Function() hasPairing}) async {
    AppMode? found;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      found = parse(prefs.getString(prefsKey));
    } catch (_) {
      // No preferences: fall through to the default.
    }
    if (found == null) {
      try {
        final bool paired = await hasPairing().timeout(pairingTimeout);
        found = paired ? AppMode.agents : AppMode.chats;
      } catch (_) {
        // The store did not answer in time, or failed: keep what is shown.
        found = value;
      }
    }
    if (_disposed) return;
    _loaded = true;
    if (!_chosen) value = found;
  }

  /// The user picked [mode]: show it and remember it.
  Future<void> select(AppMode mode) async {
    if (_disposed) return;
    _chosen = true;
    value = mode;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // On desktop Linux every write rewrites the whole preferences file, so
      // a value that is already there is not written again.
      if (prefs.getString(prefsKey) != mode.name) {
        await prefs.setString(prefsKey, mode.name);
      }
    } catch (_) {
      // The choice still holds for this session.
    }
  }

  /// Shows [mode] without remembering it: a move the app made for the user
  /// (a notification tap, a Home widget that opens the main agent), not a
  /// choice of where to land next time. Like [select], it wins over a [load]
  /// that is still running.
  void show(AppMode mode) {
    if (_disposed) return;
    _chosen = true;
    value = mode;
  }

  /// The mode a stored value names, or null for anything else. The old
  /// `chat` is Chats; the old `home` (the dashboard) is Agents, which holds
  /// Home now.
  static AppMode? parse(String? raw) => switch (raw) {
    'chats' => AppMode.chats,
    'chat' => AppMode.chats,
    'agents' => AppMode.agents,
    'home' => AppMode.agents,
    _ => null,
  };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
