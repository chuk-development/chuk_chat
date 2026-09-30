// lib/platform_specific/chat/voice/voice_task_delegates.dart
//
// The two VoiceTaskDelegates a chat screen hands to a call. Both send the
// spoken task as a user message through the screen's own send path (the one
// the composer uses), return a task id at once, and report the final
// assistant text when that turn has finished.
//
//  * ChatVoiceDelegate — a normal chat: the hosted model with its full tool
//    loop does the work.
//  * AgentsVoiceDelegate — an Agents thread: the message goes to the host,
//    which runs it as a normal task of that thread; its `done` (folded into
//    the turn by the Agents transport) is what finishes the turn.
//
// The chat screen runs one turn at a time, so overlapping tasks are queued
// and each result is tied to its own turn, never guessed by order.

import 'dart:async';

import 'package:chuk_chat/platform_specific/chat/voice/voice_call_context.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// Sends one task text into the chat and completes when its turn ended.
/// Never throws.
typedef VoiceTaskSender = Future<VoiceTurnOutcome> Function(String text);

/// The shared body of both delegates.
abstract class VoiceTurnDelegate implements VoiceTaskDelegate {
  VoiceTurnDelegate(this._send, this._idPrefix);

  final VoiceTaskSender _send;
  final String _idPrefix;

  /// Synchronous, so a result added before [close] reaches the listener
  /// before the listener can be taken away.
  final StreamController<VoiceTaskResult> _results =
      StreamController<VoiceTaskResult>.broadcast(sync: true);
  final String _callTag = DateTime.now().microsecondsSinceEpoch.toRadixString(
    36,
  );
  final Set<String> _openIds = <String>{};
  int _next = 0;
  bool _closed = false;

  /// Tasks started and not reported yet.
  int get openTasks => _openIds.length;

  /// True once [close] ran: the delegate takes no more tasks.
  bool get isClosed => _closed;

  @override
  Stream<VoiceTaskResult> get results => _results.stream;

  /// Starts [task] and returns its id at once. Throws a [StateError] once the
  /// delegate is closed (its chat screen went away).
  @override
  Future<String> startTask(String task) async {
    if (_closed) {
      throw StateError('The chat of this call is closed.');
    }
    final String id = '$_idPrefix-$_callTag-${++_next}';
    final String? text = voiceTaskMessageText(task);
    if (text == null) {
      scheduleMicrotask(
        () => _emit(id, const VoiceTurnOutcome.failed('The task was empty.')),
      );
      return id;
    }
    _openIds.add(id);
    unawaited(
      _send(text).then(
        (VoiceTurnOutcome outcome) => _finish(id, outcome),
        onError: (Object _) => _finish(
          id,
          const VoiceTurnOutcome.failed('The task could not be run.'),
        ),
      ),
    );
    return id;
  }

  void _finish(String id, VoiceTurnOutcome outcome) {
    // Already reported (failOpenTasks): the late answer is dropped.
    if (!_openIds.remove(id)) return;
    _emit(id, outcome);
  }

  void _emit(String id, VoiceTurnOutcome outcome) {
    if (_results.isClosed) return;
    _results.add(
      VoiceTaskResult(
        taskId: id,
        status: outcome.ok
            ? VoiceTaskResult.statusDone
            : VoiceTaskResult.statusFailed,
        result: voiceResultText(outcome.text),
      ),
    );
  }

  /// Reports every task that is still open — queued or running — as failed
  /// with [reason], at once, while the stream is still open. A later answer
  /// of one of them is dropped.
  void failOpenTasks(String reason) {
    final List<String> ids = List<String>.of(_openIds);
    _openIds.clear();
    for (final String id in ids) {
      _emit(id, VoiceTurnOutcome.failed(reason));
    }
  }

  /// Takes no more tasks and closes the result stream. Turns already sent
  /// keep running in the chat; their answers land in the thread as usual.
  Future<void> close() async {
    _closed = true;
    if (!_results.isClosed) await _results.close();
  }

  /// [failOpenTasks] with [reason], then [close].
  Future<void> dispose({String reason = kVoiceTaskChatClosed}) async {
    if (!_closed) failOpenTasks(reason);
    await close();
  }
}

/// Why a task failed when its chat screen went away.
const String kVoiceTaskChatClosed = 'The chat was closed.';

/// Why a task failed when its call ended before the task started.
const String kVoiceTaskCallEnded = 'The call ended.';

/// A normal chat: the task goes through chuk_chat's send pipeline with its
/// client-side tool loop.
class ChatVoiceDelegate extends VoiceTurnDelegate {
  ChatVoiceDelegate(VoiceTaskSender send) : super(send, 'chat');
}

/// An Agents thread: the task goes through the thread's send path to the
/// host, which runs it and ends it with `done`.
class AgentsVoiceDelegate extends VoiceTurnDelegate {
  AgentsVoiceDelegate(VoiceTaskSender send) : super(send, 'agents');
}
