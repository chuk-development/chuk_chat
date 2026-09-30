// lib/platform_specific/chat/voice/voice_turn_queue.dart
//
// Runs the tasks a voice call hands to a chat, one turn at a time, through
// the chat screen's own send path, and tells each caller how its turn ended.
// Pure Dart: the chat screen supplies the three hooks below.

import 'dart:async';

import 'package:chuk_chat/platform_specific/chat/voice/voice_call_context.dart';

/// How one voice task ended in the chat.
class VoiceTurnOutcome {
  const VoiceTurnOutcome.done(this.text) : ok = true;
  const VoiceTurnOutcome.failed(this.text) : ok = false;

  /// From the text the chat finalized the turn with.
  factory VoiceTurnOutcome.fromFinalText(String text) =>
      looksLikeFailedTurn(text)
      ? VoiceTurnOutcome.failed(
          text.trim().isEmpty ? 'The chat gave no answer.' : text,
        )
      : VoiceTurnOutcome.done(text);

  final bool ok;

  /// The final assistant text, or why the turn failed.
  final String text;
}

/// Called by the chat screen once the turn is under way: the chat it went to
/// and the index of the assistant row that will carry the answer.
typedef VoiceTurnStarted = void Function(String chatId, int placeholderIndex);

/// Sends [text] as a user message through the chat screen's send path. Calls
/// [onStarted] when the turn is under way; returns without calling it when
/// the send did not start (busy, offline, no model, …).
typedef VoiceTurnSend =
    Future<void> Function(String text, VoiceTurnStarted onStarted);

/// Why a task failed when its send was parked offline: the message waits in
/// the chat's offline queue, but the call cannot wait for its answer.
const String kVoiceTaskOffline =
    'Offline: the message waits and goes out when the connection is back.';

class VoiceTurnQueue {
  VoiceTurnQueue({
    required this.send,
    required this.isBusy,
    required this.currentChatId,
    this.isOffline,
    this.pollInterval = const Duration(milliseconds: 400),
    this.maxWait = const Duration(minutes: 10),
    this.turnTimeout = const Duration(minutes: 15),
  });

  final VoiceTurnSend send;

  /// True while the chat on screen has a turn of its own in flight.
  final bool Function() isBusy;

  /// The chat on screen right now.
  final String? Function() currentChatId;

  /// True while the device is offline. A send that did not start while
  /// offline fails its task at once with [kVoiceTaskOffline].
  final bool Function()? isOffline;

  /// How often a waiting task checks whether the chat is free.
  final Duration pollInterval;

  /// How long a task waits for a busy chat before it gives up.
  final Duration maxWait;

  /// How long a started turn may run before its task is reported failed.
  final Duration turnTimeout;

  final List<_Pending> _pending = <_Pending>[];
  final Map<String, Completer<VoiceTurnOutcome>> _running =
      <String, Completer<VoiceTurnOutcome>>{};
  bool _pumping = false;
  bool _disposed = false;

  /// The task whose send is in flight right now; it cannot be cancelled.
  _Pending? _dispatching;

  /// Tasks waiting for their turn, plus the one running.
  int get length => _pending.length + _running.length;

  /// Queues [text] for [chatId]. The future completes when the chat has
  /// answered, or failed, and never throws. [tag] names the call the task
  /// belongs to, for [cancelPending].
  Future<VoiceTurnOutcome> enqueue(String chatId, String text, {Object? tag}) {
    if (_disposed) {
      return Future<VoiceTurnOutcome>.value(
        const VoiceTurnOutcome.failed('The chat is closed.'),
      );
    }
    final _Pending pending = _Pending(chatId, text, DateTime.now(), tag);
    _pending.add(pending);
    unawaited(_pump());
    return pending.completer.future;
  }

  /// The chat finalized the assistant row [index] of [chatId] with [text].
  /// Returns true when that row belonged to a voice turn.
  bool complete(String chatId, int index, String text) {
    final Completer<VoiceTurnOutcome>? turn = _running.remove(
      _key(chatId, index),
    );
    if (turn == null || turn.isCompleted) return false;
    turn.complete(VoiceTurnOutcome.fromFinalText(text));
    return true;
  }

  /// The turn at row [index] of [chatId] was torn down without an answer.
  bool fail(String chatId, int index, String reason) {
    final Completer<VoiceTurnOutcome>? turn = _running.remove(
      _key(chatId, index),
    );
    if (turn == null || turn.isCompleted) return false;
    turn.complete(VoiceTurnOutcome.failed(reason));
    return true;
  }

  /// Fails the tasks of [tag] that have not started yet with [reason]. A
  /// task already running, or whose send is in flight, is left to finish.
  /// Returns how many were cancelled.
  int cancelPending(Object tag, String reason) {
    final List<_Pending> cancelled = <_Pending>[
      for (final _Pending p in _pending)
        if (p.tag == tag && !identical(p, _dispatching)) p,
    ];
    for (final _Pending p in cancelled) {
      _pending.remove(p);
      p.finish(VoiceTurnOutcome.failed(reason));
    }
    return cancelled.length;
  }

  /// Fails every waiting and running task. The queue takes no more work.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final _Pending p in _pending) {
      p.finish(const VoiceTurnOutcome.failed('The chat was closed.'));
    }
    _pending.clear();
    for (final Completer<VoiceTurnOutcome> turn in _running.values) {
      if (!turn.isCompleted) {
        turn.complete(const VoiceTurnOutcome.failed('The chat was closed.'));
      }
    }
    _running.clear();
  }

  static String _key(String chatId, int index) => '$chatId#$index';

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pending.isNotEmpty && !_disposed) {
        final _Pending head = _pending.first;
        if (currentChatId() != head.chatId) {
          _pending.remove(head);
          head.finish(
            const VoiceTurnOutcome.failed('That chat is no longer open.'),
          );
          continue;
        }
        if (isBusy()) {
          if (DateTime.now().difference(head.enqueuedAt) > maxWait) {
            _pending.remove(head);
            head.finish(
              const VoiceTurnOutcome.failed('The chat stayed busy too long.'),
            );
            continue;
          }
          await Future<void>.delayed(pollInterval);
          continue;
        }
        // Wait until the turn is under way or the send gave up, not until
        // the send returns: a send may hold on for the whole answer, and the
        // turn's own timeout has to run from its start.
        Completer<VoiceTurnOutcome>? turn;
        final Completer<void> settled = Completer<void>();
        void settle() {
          if (!settled.isCompleted) settled.complete();
        }

        _dispatching = head;
        unawaited(
          Future<void>.sync(
                () => send(head.text, (String chatId, int index) {
                  final Completer<VoiceTurnOutcome> c =
                      Completer<VoiceTurnOutcome>();
                  _running[_key(chatId, index)] = c;
                  turn = c;
                  settle();
                }),
              )
              .catchError((Object _) {
                // Handled below as "did not start".
              })
              .whenComplete(settle),
        );
        await settled.future;
        _dispatching = null;
        if (_disposed) break;
        final Completer<VoiceTurnOutcome>? started = turn;
        if (started == null) {
          // Parked offline: the message waits in the chat's own queue, the
          // call does not. Say so now instead of leaving the task open.
          if (isOffline?.call() ?? false) {
            _pending.remove(head);
            head.finish(const VoiceTurnOutcome.failed(kVoiceTaskOffline));
            continue;
          }
          // Lost a race with the reader's own send: wait and try again.
          if (isBusy() &&
              DateTime.now().difference(head.enqueuedAt) <= maxWait) {
            await Future<void>.delayed(pollInterval);
            continue;
          }
          _pending.remove(head);
          head.finish(
            const VoiceTurnOutcome.failed('The message could not be sent.'),
          );
          continue;
        }
        _pending.remove(head);
        final VoiceTurnOutcome outcome = await started.future.timeout(
          turnTimeout,
          onTimeout: () {
            _running.removeWhere(
              (String _, Completer<VoiceTurnOutcome> c) => c == started,
            );
            return const VoiceTurnOutcome.failed('The task took too long.');
          },
        );
        head.finish(outcome);
      }
    } finally {
      _pumping = false;
    }
  }
}

class _Pending {
  _Pending(this.chatId, this.text, this.enqueuedAt, this.tag);

  final String chatId;
  final String text;
  final DateTime enqueuedAt;
  final Object? tag;
  final Completer<VoiceTurnOutcome> completer = Completer<VoiceTurnOutcome>();

  void finish(VoiceTurnOutcome outcome) {
    if (!completer.isCompleted) completer.complete(outcome);
  }
}
