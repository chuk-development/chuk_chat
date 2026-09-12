import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Why the app last stopped being signed in.
///
/// A sign-out the user did not ask for is reported as "I opened the app and
/// three seconds later I was on the login page", and the code has half a dozen
/// paths that can end there: a refused refresh token, a host that rotated the
/// pair, a call that never arrived, a sign-out the app itself triggered. None
/// of them left a trace in a release build, so the report could not be
/// answered.
///
/// This writes one line per event to the platform log — `adb logcat | grep
/// COWORK-AUTH` reads it back — and keeps the last few in preferences so the
/// answer survives the restart that follows.
class AuthTrace {
  const AuthTrace._();

  static const String prefsKey = 'cowork.auth_trace_v1';

  /// How many entries are kept. Enough to hold a startup and the sign-out
  /// that followed it.
  static const int keep = 20;

  /// The writes run one after another. Two events can land in the same frame
  /// — a signedOut and the recovery it starts — and a read-modify-write of the
  /// same list from both would keep only the later one.
  static Future<void> _chain = Future<void>.value();

  /// Notes one auth event. [event] is a short tag ('signed-out',
  /// 'recovery-unreachable'); [detail] carries whatever names the cause.
  static void note(String event, {Map<String, Object?> detail = const {}}) {
    final String line = detail.isEmpty ? event : '$event ${jsonEncode(detail)}';
    // Not behind kDebugMode: a release build is where this is needed.
    debugPrint('COWORK-AUTH $line');
    final String entry = '${DateTime.now().toIso8601String()} $line';
    _chain = _chain.then((_) => _append(entry));
    unawaited(_chain);
  }

  static Future<void> _append(String line) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> lines = prefs.getStringList(prefsKey) ?? <String>[];
      lines.add(line);
      if (lines.length > keep) lines.removeRange(0, lines.length - keep);
      await prefs.setStringList(prefsKey, lines);
    } catch (_) {
      // The log is a convenience; never let it break a sign-in path.
    }
  }

  /// The kept entries, oldest first. For a settings screen or a bug report.
  static Future<List<String>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(prefsKey) ?? <String>[];
    } catch (_) {
      return <String>[];
    }
  }

  static Future<void> clear() async {
    await settled();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {
      // Nothing to do.
    }
  }

  /// Resolves once every pending write has landed. [note] is deliberately
  /// fire-and-forget, so a reader (and a test) needs a way to wait.
  static Future<void> settled() => _chain;
}

/// Local `unawaited`, so this file pulls in nothing but what it uses.
void unawaited(Future<void> future) {
  future.then<void>((_) {}, onError: (Object _) {});
}
