// lib/voice/voice_tasks.dart
//
// Bookkeeping for tasks the worker hands to the chat through the delegate,
// and the retry rule for sending their results back. Pure Dart, so both are
// tested without a room.
//
// Why it matters: the worker marks a delegated task pending and waits for a
// `chuk.task_result`. A result that never arrives leaves the call waiting on
// it forever, so every started task must end in a result — a real one, or a
// failed one when the chat that owned the delegate goes away.

import 'dart:async';

import 'package:chuk_chat/voice/voice_call_models.dart';

/// The started tasks of one delegate that have no result yet.
class VoiceTaskLedger {
  VoiceTaskDelegate? _delegate;
  final Set<String> _pending = <String>{};

  /// The delegate tasks are started through right now.
  VoiceTaskDelegate? get delegate => _delegate;

  /// Task ids started through [delegate] with no result yet.
  Set<String> get pending => Set<String>.unmodifiable(_pending);

  /// Starts a new call's bookkeeping with [delegate] (may be null).
  void reset(VoiceTaskDelegate? delegate) {
    _delegate = delegate;
    _pending.clear();
  }

  /// A task was started through [through]. Returns true when [through] is
  /// still the current delegate and the task is now pending; false when the
  /// delegate was detached while the task was starting (the caller then owes
  /// the worker a failed result).
  bool started(VoiceTaskDelegate? through, String taskId) {
    if (through == null || !identical(through, _delegate)) return false;
    _pending.add(taskId);
    return true;
  }

  /// A result for [taskId] is on its way to the worker.
  void resolved(String taskId) => _pending.remove(taskId);

  /// Drops [delegate] if it is the current one. Returns the task ids that
  /// were still pending on it (each needs a failed result); empty when
  /// [delegate] was not the current one.
  List<String> detach(VoiceTaskDelegate delegate) {
    if (!identical(delegate, _delegate)) return const <String>[];
    _delegate = null;
    final List<String> orphans = _pending.toList(growable: false);
    _pending.clear();
    return orphans;
  }
}

/// Waits between delivery attempts: 1 s, 3 s, 6 s, then give up.
const List<Duration> kVoiceResultBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 6),
];

/// Runs [attempt] until it returns true, retrying after each wait in
/// [backoff] while [stillValid] holds. An attempt that throws counts as a
/// failure. Returns true once an attempt succeeds, false when the retries
/// run out or [stillValid] turns false.
Future<bool> deliverWithRetry(
  Future<bool> Function() attempt, {
  List<Duration> backoff = kVoiceResultBackoff,
  bool Function()? stillValid,
  Future<void> Function(Duration)? sleep,
}) async {
  final Future<void> Function(Duration) wait =
      sleep ?? (Duration d) => Future<void>.delayed(d);
  for (int i = 0; ; i++) {
    if (stillValid != null && !stillValid()) return false;
    bool ok;
    try {
      ok = await attempt();
    } catch (_) {
      ok = false;
    }
    if (ok) return true;
    if (i >= backoff.length) return false;
    await wait(backoff[i]);
  }
}
