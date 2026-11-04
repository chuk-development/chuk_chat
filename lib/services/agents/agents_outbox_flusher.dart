// Sends the Agents outbox app-wide when the relay link comes back.
//
// The outbox ([AgentsTaskOutbox]) used to be flushed only by a mounted
// AgentsThreadView: its own paired transition, its Retry button and its
// watchdog. This listens to the shared relay link instead, so every queued
// prompt of every thread goes out on the transition into `paired`, whatever
// screen is open. The view keeps its own flush; running both is harmless,
// because a flush holds a per-thread claim and every entry goes out under the
// `task_id` it was given when it was queued, which the host dedupes.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';

class AgentsOutboxFlusher {
  AgentsOutboxFlusher._(this._source, this._tick);

  static AgentsOutboxFlusher? _instance;

  /// How often a paired link looks for a backed-off entry that came due.
  static const Duration _defaultTick = Duration(seconds: 10);

  /// Starts the app-wide flush. Idempotent, and a no-op in a build without
  /// Agents (`FEATURE_AGENTS` off).
  static void start() {
    if (!kFeatureAgents) return;
    _instance ??= AgentsOutboxFlusher._(
      AgentsRelayLink.instance.controller,
      _defaultTick,
    ).._attach();
  }

  /// Test seam: start on [source] instead of the shared link, without the
  /// build flag. Replaces a running instance.
  @visibleForTesting
  static AgentsOutboxFlusher startForTest(
    ValueListenable<AgentsRelayController?> source, {
    Duration tick = _defaultTick,
  }) {
    stopForTest();
    return _instance = AgentsOutboxFlusher._(source, tick).._attach();
  }

  @visibleForTesting
  static void stopForTest() {
    _instance?._detach();
    _instance = null;
  }

  final ValueListenable<AgentsRelayController?> _source;
  final Duration _tick;
  AgentsRelayController? _watched;
  bool _wasPaired = false;
  Timer? _timer;

  void _attach() {
    _source.addListener(_onController);
    _onController();
  }

  void _detach() {
    _source.removeListener(_onController);
    _unwatch();
  }

  void _unwatch() {
    _timer?.cancel();
    _timer = null;
    final AgentsRelayController? old = _watched;
    _watched = null;
    _wasPaired = false;
    if (old == null) return;
    try {
      old.state.removeListener(_onState);
    } catch (_) {
      // The view may already have disposed the old transport's notifier.
    }
  }

  void _onController() {
    final AgentsRelayController? next = _source.value;
    if (identical(next, _watched)) return;
    _unwatch();
    _watched = next;
    if (next == null) return;
    next.state.addListener(_onState);
    _onState();
  }

  void _onState() {
    final AgentsRelayController? controller = _watched;
    if (controller == null) return;
    final bool paired = controller.state.value.isPaired;
    if (paired && !_wasPaired) {
      unawaited(flushAllVia(controller));
      // A send that failed waits out its backoff, and nothing else would look
      // at the queue again while no thread view is mounted.
      _timer?.cancel();
      _timer = Timer.periodic(_tick, (_) => _onTick(controller));
    } else if (!paired) {
      _timer?.cancel();
      _timer = null;
    }
    _wasPaired = paired;
  }

  Future<void> _onTick(AgentsRelayController controller) async {
    if (!identical(controller, _watched)) return;
    if (!controller.state.value.isPaired) return;
    try {
      if (await AgentsTaskOutbox.anyDue()) await flushAllVia(controller);
    } catch (error) {
      if (kDebugMode) debugPrint('[agents-outbox] tick failed: $error');
    }
  }

  /// Every thread's queued prompts through [controller], each into the thread
  /// it was typed in. Never throws. Returns how many went out.
  static Future<int> flushAllVia(AgentsRelayController controller) async {
    try {
      final int sent = await AgentsTaskOutbox.flushAll(
        (OutboxTask task) => sendQueued(controller, task),
      );
      if (sent > 0 && kDebugMode) {
        debugPrint('[agents-outbox] sent $sent queued prompt(s)');
      }
      return sent;
    } catch (error) {
      if (kDebugMode) debugPrint('[agents-outbox] flushAll failed: $error');
      return 0;
    }
  }

  /// Sends one queued prompt into the thread it was typed in.
  ///
  /// The outbox drops the entry as soon as this returns, and a returned
  /// `send()` is no proof the host has the prompt: a half-open socket takes
  /// the frame and nobody reads it. So the prompt is first handed to
  /// [AgentsPendingTasks] under its `task_id`, the record a live send writes.
  /// That record is cleared by the host's `task_ack` and re-sent with the same
  /// id on the next pairing. The id is the one stored on the entry
  /// ([OutboxTask.taskId]), so two flushes of one entry are one task to the
  /// host.
  ///
  /// Throws [OutboxSendDeferred] when [controller] is not paired: the entry
  /// stays queued and no attempt is counted.
  static Future<void> sendQueued(
    AgentsRelayController controller,
    OutboxTask task,
  ) async {
    if (!controller.state.value.isPaired) throw const OutboxSendDeferred();
    final String taskId = task.taskId;
    await AgentsPendingTasks.record(
      sessionKey: task.sessionKey,
      taskId: taskId,
      prompt: task.prompt,
      modelId: task.modelId,
      providerSlug: task.providerSlug,
      reasoningEffort: task.reasoningEffort,
    );
    AgentsRunLedger.instance.taskSent(task.sessionKey, taskId);
    await controller.sendTask(
      task.prompt,
      sessionKey: task.sessionKey,
      modelId: task.modelId,
      providerSlug: task.providerSlug,
      reasoningEffort: task.reasoningEffort,
      taskId: taskId,
    );
    // It is on the wire and tracked until the host acknowledges it: the
    // bubble stops saying "waiting" and stops offering Retry.
    await AgentsQueuedMarks.clearMark(
      sessionKey: task.sessionKey,
      queueId: task.localId,
    );
  }
}
