/// What the user has already seen, per coworker.
///
/// A messenger inbox needs an "unread" answer, and the app has exactly one fact
/// it can build that from: the last time something happened in a thread
/// ([CoworkAgent.lastActivity], written by `markActivity`) against the last time
/// the user had that thread open. This store keeps the second half — one
/// timestamp per thread key, persisted in `SharedPreferences` — and answers
///
///   unread == lastActivity > lastRead
///
/// That is a flag, not a count: the app does not know how many messages arrived
/// while the reader was away, and a made-up number would be worse than a dot.
/// The one number it can honestly show is how many coworkers are unread, which
/// is what the "Unread" filter counts.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/models/cowork_agent.dart';

class AgentReadMarks extends ChangeNotifier {
  AgentReadMarks();

  static final AgentReadMarks instance = AgentReadMarks();

  static const String _prefsKey = 'cowork_thread_read_marks_v1';

  final Map<String, DateTime> _marks = <String, DateTime>{};
  bool _loaded = false;

  bool get loaded => _loaded;

  /// When the user last had [threadKey] open, or null if never.
  DateTime? lastRead(String threadKey) => _marks[threadKey];

  /// True when something happened in one of [agent]'s threads after the user
  /// last had it open. An agent that never did anything is not unread.
  bool isUnread(CoworkAgent agent) {
    for (final CoworkThreadInfo thread in agent.threads) {
      final DateTime? activity = thread.lastActivity ?? agent.lastActivity;
      if (activity == null) continue;
      final DateTime? read = _marks[thread.key];
      if (read == null || activity.isAfter(read)) return true;
    }
    return false;
  }

  /// How many of [agents] are unread.
  int unreadCount(Iterable<CoworkAgent> agents) =>
      agents.where(isUnread).length;

  /// How many of one coworker's threads have something new in them. This is
  /// what the number on a roster badge counts today; the count of new messages
  /// needs the preview store that does not exist yet.
  int unreadThreads(CoworkAgent agent) {
    int count = 0;
    for (final CoworkThreadInfo thread in agent.threads) {
      final DateTime? activity = thread.lastActivity ?? agent.lastActivity;
      if (activity == null) continue;
      final DateTime? read = _marks[thread.key];
      if (read == null || activity.isAfter(read)) count++;
    }
    return count;
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final MapEntry<dynamic, dynamic> entry in decoded.entries) {
            final DateTime? when = DateTime.tryParse('${entry.value}');
            if (when != null) _marks['${entry.key}'] = when;
          }
        }
      }
    } catch (error) {
      debugPrint('⚠️ [AgentReadMarks] load failed: $error');
    }
    _loaded = true;
    notifyListeners();
  }

  /// Marks [threadKey] read as of [when] (now by default). A mark never moves
  /// backwards.
  Future<void> markRead(String threadKey, {DateTime? when}) async {
    final DateTime at = when ?? DateTime.now();
    final DateTime? previous = _marks[threadKey];
    if (previous != null && !at.isAfter(previous)) return;
    _marks[threadKey] = at;
    notifyListeners();
    await _persist();
  }

  /// Drops the mark of a thread whose coworker is gone.
  Future<void> forget(String threadKey) async {
    if (_marks.remove(threadKey) == null) return;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_marks.isEmpty) {
        await prefs.remove(_prefsKey);
        return;
      }
      await prefs.setString(
        _prefsKey,
        jsonEncode(<String, String>{
          for (final MapEntry<String, DateTime> e in _marks.entries)
            e.key: e.value.toIso8601String(),
        }),
      );
    } catch (error) {
      debugPrint('⚠️ [AgentReadMarks] persist failed: $error');
    }
  }
}
