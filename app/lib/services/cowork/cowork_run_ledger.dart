/// The run ledger: what a host run *did*, in the shapes the imported chat
/// renderer already knows how to draw.
///
/// CoWork's transport speaks [CoworkRelayInbound]; chuk_chat's `MessageBubble`
/// speaks [ToolCall] and [ContentBlock]. The adapter
/// (`services/websocket_chat_service.dart`) turns the *text* channels into
/// `ChatStreamEvent`s; everything else — a tool that ran, a child agent, a file
/// the agent handed over, an approval the user answered — has no place in that
/// stream, because emitting it would mean emitting a `ToolCallsEvent`, and a
/// `ToolCallsEvent` is exactly what would wake the client-side tool loop back
/// up. So those events land here instead, keyed by session, and the fold
/// (`services/tool_call_handler.dart`) hands the finished pile to the renderer
/// as `ToolLoopResult.toolCalls` / `.producedBlocks` when the turn completes.
///
/// The ledger is a [ChangeNotifier] so the thread view can drive "this coworker
/// is working" off it instead of re-deriving run state from the raw stream.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:cowork/models/content_block.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/automations/automation_ledger.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/image_storage_service.dart';

/// The renderer's shape of one host `tool` frame.
///
/// ONE mapping for both paths: the live ledger ([CoworkRunLedger.recordTool])
/// and the replay loader call this, so a frame draws the same card whether it
/// arrived during the run or came back from the host's transcript (beads
/// cowork-b45 / cowork-al2, docs/WIRE_CONTRACT.md "Tool events and
/// timestamps"). The host's clock is used when the frame carries it; [now]
/// (default [DateTime.now]) stands in on an old host.
ToolCall toolCallFromRelay(CoworkRelayTool event, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final arguments = <String, dynamic>{
    if (event.argumentMap != null)
      ...event.argumentMap!
    else if (event.arguments != null && event.arguments!.isNotEmpty)
      'command': event.arguments,
    if (event.exitCode != null) 'exit_code': event.exitCode,
  };
  final startedAt = event.startedAt ?? clock;
  final duration = event.duration;
  final completedAt =
      event.completedAt ?? (duration != null ? startedAt.add(duration) : clock);
  final call = ToolCall(
    id: event.callId,
    name: event.name,
    arguments: arguments,
    status: event.failed ? ToolCallStatus.error : ToolCallStatus.completed,
    result: event.detail ?? event.result,
    startedAt: startedAt,
  );
  call.completedAt = completedAt;
  return call;
}

/// How a run ended, once it is over.
///
/// The thread needs to tell "stopped" from "still thinking" and from "it
/// answered" — a run that ends with nothing to show must still say so
/// (bead cowork-gnr8). [answered] is the ordinary end; the other three are the
/// ends that leave the thread empty.
enum CoworkRunOutcome {
  /// The host sent a terminal and it carried an answer.
  answered,

  /// The user's stop, the ESTOP file, or the host's wall-clock guard.
  stopped,

  /// An error terminal, or a transport that failed under the run.
  failed,

  /// No terminal ever came and the run went quiet: the app lost it.
  lost,
}

/// What a run terminal means for the thread, from the two fields that say it.
///
/// A terminal that carries an answer is an answer whatever its reason says; one
/// that carries none is a stop (`estop` / `interrupted` / `timeout`, see
/// [CoworkRelayDone.wasStopped]) or a failure, and either way the thread has to
/// say so instead of leaving the reader with the working dots.
CoworkRunOutcome coworkRunOutcomeFor({String? reason, String? finalAnswer}) {
  if (finalAnswer != null && finalAnswer.trim().isNotEmpty) {
    return CoworkRunOutcome.answered;
  }
  if (reason == 'estop' || reason == 'interrupted' || reason == 'timeout') {
    return CoworkRunOutcome.stopped;
  }
  // A terminal that says the run finished IS the run finishing, even with an
  // empty answer field: the answer was streamed, or there was nothing to say.
  // `lost` is reserved for a run that produced no terminal at all.
  if (reason == null || reason == 'finished') return CoworkRunOutcome.answered;
  return CoworkRunOutcome.failed;
}

/// The one quiet line a run that produced nothing leaves in the thread. Null
/// for a run that answered — that one speaks for itself.
///
/// ONE wording for both paths, like every other live/replay mapping in this
/// file: the live thread writes it when the terminal lands, and the replay
/// loader writes it when the same run comes back from the host's transcript.
String? coworkRunEndNotice(CoworkRunOutcome outcome) => switch (outcome) {
  CoworkRunOutcome.answered => null,
  CoworkRunOutcome.stopped => 'Stopped. No answer was written.',
  CoworkRunOutcome.failed => 'This run failed. No answer was written.',
  CoworkRunOutcome.lost => 'Lost this run. No answer came back.',
};

/// Everything one run produced, in renderer shapes.
class CoworkRun {
  CoworkRun(this.sessionKey);

  /// The executor session (thread) this run belongs to.
  final String sessionKey;

  /// Tool calls in the order the host reported them, including the synthetic
  /// `subagent` and `ask_user` ones.
  final List<ToolCall> toolCalls = <ToolCall>[];

  /// Side-effect blocks — today only `sandboxArtifact`, one per relayed file.
  final List<ContentBlock> blocks = <ContentBlock>[];

  /// The model's own thinking, accumulated across the run.
  String modelReasoning = '';

  /// The final answer the host reported on `done`, when it sent one.
  String? finalAnswer;

  /// Why the run ended, as the host said it (`finished`, `estop`, …).
  String? reason;

  int? iterations;
  int? tokensSpent;

  /// The host's id for this run, echoed back with `run_ack`.
  String? runId;

  /// The latest `debug_context` payload for this session, for the copy button.
  Map<String, dynamic>? debugContext;

  /// True between [CoworkRunLedger.begin] and [CoworkRunLedger.finish].
  bool running = false;

  /// A host running header confirmed this turn; distinguishes it from a newly
  /// submitted local request racing an older replay's idle header.
  bool hostObserved = false;

  /// When the run started, for an elapsed readout. The host's clock once a
  /// `run_state` or a `done` carried it, else this client's.
  DateTime startedAt = DateTime.now();

  /// When the host said the run ended (`done.finished_at`). Null while it
  /// runs, and on an old host.
  DateTime? finishedAt;

  /// The run's length as the host measured it, when it sent both clocks.
  Duration? get workedFor {
    final finished = finishedAt;
    if (finished == null || !hostStamped) return null;
    final elapsed = finished.difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// True once [startedAt] is the host's clock, not this client's.
  bool hostStamped = false;

  /// The message rows of this run (`done.first_mid` / `last_mid`).
  int? firstMid;
  int? lastMid;

  /// The prompt the host says an already-in-flight run is working on, learned
  /// from a `run_state` header. Null for a run this client started itself.
  String? detachedPrompt;

  /// How this run ended. Null while it runs.
  CoworkRunOutcome? outcome;

  /// When the user pressed Stop and the frame went out. The terminal is
  /// expected; until it lands the thread already knows the run is on its way
  /// out. Null while nobody asked.
  DateTime? stopRequestedAt;

  /// True once the user's stop for this run is on the wire.
  bool get stopRequested => stopRequestedAt != null;

  /// When the app last asked the host what happened to a silent run. Cleared
  /// by any sign of life; [CoworkRunLedger.ceilingGrace] after it, with still
  /// nothing, the run counts as lost.
  DateTime? probedAt;

  /// The last time this run produced anything at all — a token, a tool event,
  /// a child agent, a host header. The ceiling is measured from here, so a run
  /// that keeps working is never declared lost.
  DateTime lastActivity = DateTime.now();

  /// Anything at all arrived for this run — a token, a tool event, a child
  /// agent. A run that produced something left a visible trace in the thread,
  /// so it needs no line of its own even when it ended badly.
  bool producedOutput = false;

  /// True once the run is over and it left the thread with nothing: the reader
  /// has to be told what happened instead of watching the dots for ever.
  bool get endedWithoutAnswer =>
      !running &&
      outcome != null &&
      outcome != CoworkRunOutcome.answered &&
      !producedOutput &&
      (finalAnswer == null || finalAnswer!.trim().isEmpty);
}

/// Process-wide ledger of host runs, keyed by session key.
/// The renderer's shape of one child agent, live or replayed — ONE mapping
/// (bead cowork-266). [existing] is the card already open for this
/// `subagent_id` (the ledger keeps one per child); null opens a new one.
/// Terminal states close the card: `succeeded` completes it, `failed` /
/// `cancelled` mark it as an error, and the outcome text is the error, else
/// the result, else the state itself.
ToolCall subagentCallFromRelay(
  ToolCall? existing, {
  required String subagentId,
  required String title,
  required String state,
  String? result,
  String? error,
  DateTime? now,
}) {
  final call =
      existing ??
      ToolCall(
        name: 'subagent',
        arguments: <String, dynamic>{
          'subagent_id': subagentId,
          if (title.isNotEmpty) 'title': title,
        },
        status: ToolCallStatus.running,
      );
  call.arguments['state'] = state;
  final terminal =
      state == 'succeeded' || state == 'failed' || state == 'cancelled';
  if (terminal) {
    call.status = state == 'succeeded'
        ? ToolCallStatus.completed
        : ToolCallStatus.error;
    call.result = error ?? result ?? state;
    call.completedAt = now ?? DateTime.now();
  } else {
    call.result = result;
  }
  return call;
}

/// The renderer's shape of one relayed file, once its bytes are in the local
/// blob store at [storagePath] — ONE mapping for the live ledger and the
/// replay loader (bead cowork-266).
ContentBlock artifactBlockFromFile(String storagePath, CoworkRelayFile file) {
  return ContentBlock.sandboxArtifact(
    SandboxArtifactPayload(
      storagePath: storagePath,
      filename: file.name,
      mime: file.mimeType,
      sizeBytes: file.bytes?.length ?? file.declaredSize ?? 0,
      document: file.document,
    ),
  );
}

/// The renderer's shape of a here.now publish approval, as a completed
/// `ask_user` tool call — ONE mapping for both paths (bead cowork-266).
///
/// An OPEN request carries its two options under `arguments['options']`,
/// which is where the imported `AskUserCard` reads them from: that is what
/// makes the card tappable. A request whose outcome is known (a replayed row
/// with `decision`, or one the run outlived) keeps the options under
/// `offered_options` instead and records `decision` / `decision_reason`, so
/// the same card shows what happened and offers nothing to press.
ToolCall approvalCallFromRelay(
  CoworkRelayApprovalRequest request, {
  bool decided = false,
  DateTime? now,
}) {
  final question = request.name.isEmpty
      ? 'Publish to the web?'
      : 'Publish "${request.name}" to the web?';
  const options = <String>['Publish', 'Deny'];
  final settled = decided || request.isDecided;
  final payload = <String, dynamic>{
    'question': question,
    if (!settled) 'options': options,
    if (settled) 'offered_options': options,
    'approvalId': request.approvalId,
    if (settled)
      'decision': request.isApproved
          ? 'Publish'
          : (request.isDecided ? 'Deny' : 'Expired'),
    if (request.decisionReason != null)
      'decision_reason': request.decisionReason,
  };
  return ToolCall(
    name: 'ask_user',
    arguments: <String, dynamic>{
      ...payload,
      'action': request.action,
      'path': request.path,
      'file_count': request.fileCount,
      'total_bytes': request.totalBytes,
      'public': request.public,
    },
    status: ToolCallStatus.completed,
    result: jsonEncode(payload),
  )..completedAt = now ?? DateTime.now();
}

class CoworkRunLedger extends ChangeNotifier {
  CoworkRunLedger._();

  static final CoworkRunLedger instance = CoworkRunLedger._();

  final Map<String, CoworkRun> _runs = <String, CoworkRun>{};

  /// Subagent id -> the [ToolCall] standing in for it, keyed
  /// `"<sessionKey>\u0000<subagentId>"` so two threads cannot collide.
  final Map<String, ToolCall> _subagentCalls = <String, ToolCall>{};

  /// One transcript line per automation id, like a child agent's
  /// (docs/WIRE_CONTRACT.md, "Automations").
  final Map<String, ToolCall> _automationCalls = <String, ToolCall>{};

  /// How long a run may produce nothing before the app asks the host what
  /// happened to it. Tool frames only arrive when a command FINISHES, so this
  /// has to be longer than an ordinary command, not shorter.
  static Duration ceiling = const Duration(minutes: 3);

  /// How long the host then has to say "still running" before the run counts
  /// as lost. The probe is a replay request, which the host answers with a
  /// `run_state` header within a round trip.
  static Duration ceilingGrace = const Duration(seconds: 30);

  /// How long a stop may stay unanswered before the run is ended anyway. The
  /// executor acks a stop before it fires it, so the terminal is usually here
  /// within a second; the thread must not keep spinning if it is not.
  static Duration stopGrace = const Duration(seconds: 10);

  /// A run this client started that the host has not confirmed yet is left
  /// alone by an idle `run_state` header for this long — the header may have
  /// been computed before the task reached the host (see [reconcileIdle]).
  static Duration idleHeaderGrace = const Duration(seconds: 10);

  /// Called when a run has produced nothing for [ceiling]. The thread view
  /// hangs the probe here: it asks the host for a fresh `run_state`, which
  /// either revives the run or reconciles it away.
  void Function(String sessionKey)? onRunSilent;

  /// The ceiling, applied. Called from the thread view's existing watchdog
  /// tick — the ledger owns no timer of its own, because a process-wide
  /// singleton that arms one would keep firing long after the thread that
  /// cared about the run was gone.
  ///
  /// Three steps, in order:
  ///  * a stop whose terminal never came ends the run once [stopGrace] passed;
  ///  * a run that has produced nothing for [ceiling] is asked about ONCE
  ///    (a long command sends no frame while it works, so the host's answer,
  ///    not the silence, is what decides);
  ///  * a run still silent [ceilingGrace] after that is declared lost.
  void sweep({DateTime? now}) {
    final clock = now ?? DateTime.now();
    for (final run in _runs.values.toList(growable: false)) {
      if (!run.running) continue;
      final stoppedAt = run.stopRequestedAt;
      if (stoppedAt != null && clock.difference(stoppedAt) >= stopGrace) {
        _endWithoutAnswer(run.sessionKey, CoworkRunOutcome.stopped);
        continue;
      }
      final silent = clock.difference(run.lastActivity);
      if (run.probedAt != null) {
        if (clock.difference(run.probedAt!) >= ceilingGrace) {
          _endWithoutAnswer(run.sessionKey, CoworkRunOutcome.lost);
        }
        continue;
      }
      if (silent >= ceiling) {
        run.probedAt = clock;
        onRunSilent?.call(run.sessionKey);
      }
    }
  }

  /// The run for [sessionKey], if one is on record.
  CoworkRun? runFor(String sessionKey) => _runs[sessionKey];

  /// True while a run for [sessionKey] is in flight.
  bool isRunning(String sessionKey) => _runs[sessionKey]?.running ?? false;

  /// Every session with a run in flight.
  Iterable<String> get runningSessions =>
      _runs.entries.where((e) => e.value.running).map((e) => e.key);

  /// Starts a fresh run for [sessionKey], discarding whatever the previous one
  /// left behind. One run at a time per session: the executor serves a thread's
  /// tasks in order, so a `begin` is always a new turn.
  CoworkRun begin(String sessionKey) {
    _subagentCalls.removeWhere((key, _) => key.startsWith('$sessionKey\u0000'));
    _automationCalls.removeWhere(
      (key, _) => key.startsWith('$sessionKey\u0000'),
    );
    final previous = _runs[sessionKey];
    final run = CoworkRun(sessionKey)..running = true;
    // A debug context outlives the run it came from: the copy button wants the
    // latest one for the thread, whichever turn produced it.
    run.debugContext = previous?.debugContext;
    _runs[sessionKey] = run;
    notifyListeners();
    return run;
  }

  /// Records that something happened in [sessionKey]'s run, so the ceiling
  /// starts again. Every frame that proves the run is alive lands here.
  void touch(String sessionKey) {
    final run = _runs[sessionKey];
    if (run == null || !run.running) return;
    run
      ..lastActivity = DateTime.now()
      ..producedOutput = true
      ..probedAt = null;
  }

  /// The user pressed Stop and the frame went out. The terminal that follows
  /// is what really ends the run; this only makes sure the thread stops
  /// animating even when that terminal never arrives.
  void stopRequested(String sessionKey) {
    final run = _runs[sessionKey];
    if (run == null || !run.running) return;
    run.stopRequestedAt = DateTime.now();
    notifyListeners();
  }

  /// Ends a run that produced no answer, with the reason the caller knows.
  /// Idempotent: a terminal that arrives after the ceiling fired finds the run
  /// already closed and changes nothing.
  void _endWithoutAnswer(String sessionKey, CoworkRunOutcome outcome) {
    final run = _runs[sessionKey];
    if (run == null || !run.running) return;
    run
      ..running = false
      ..outcome = outcome;
    finalizeStaleToolCalls(run.toolCalls);
    notifyListeners();
  }

  /// Test seam / explicit path: end [sessionKey]'s run as lost.
  void markLost(String sessionKey) =>
      _endWithoutAnswer(sessionKey, CoworkRunOutcome.lost);

  /// Reconciles what this client believes against what the host says.
  ///
  /// Called on reconnect and on thread open. A run the app still draws as live
  /// that the host no longer lists is over — it produced nothing, so the
  /// thread says so instead of bringing the typing dots back (bead
  /// cowork-gnr8).
  void reconcile(String sessionKey, {required bool hostRunning}) {
    if (hostRunning) {
      touch(sessionKey);
      return;
    }
    reconcileIdle(sessionKey);
  }

  /// Marks the host as already busy with [sessionKey] — a run that started
  /// before this client attached (`run_state: running`). Idempotent: it never
  /// clobbers a run this client is already tracking.
  void adoptRunning(
    String sessionKey, {
    String? runId,
    String? prompt,
    DateTime? startedAt,
  }) {
    final existing = _runs[sessionKey];
    if (existing != null && existing.running) {
      existing.hostObserved = true;
      touch(sessionKey);
      return;
    }
    final run = CoworkRun(sessionKey)
      ..running = true
      ..hostObserved = true
      ..runId = runId
      ..detachedPrompt = prompt
      ..startedAt = startedAt ?? DateTime.now()
      ..hostStamped = startedAt != null;
    _runs[sessionKey] = run;
    notifyListeners();
  }

  /// A fresh host idle header reconciles a run whose terminal was missed
  /// while disconnected. Retain all collected content until replay lands.
  ///
  /// The host is the truth about its own runs, so an idle header closes a run
  /// this client started as well — that is the run whose terminal was lost
  /// when the socket, the page or the app went away, and leaving it open is
  /// exactly the thread that types for ever (bead cowork-gnr8). The one
  /// exception is the race the header cannot know about: a task submitted a
  /// moment ago, whose header was computed before it reached the host. That
  /// one is left alone for [idleHeaderGrace].
  void reconcileIdle(String sessionKey) {
    final run = _runs[sessionKey];
    if (run == null || !run.running) return;
    if (!run.hostObserved &&
        DateTime.now().difference(run.startedAt) < idleHeaderGrace) {
      return;
    }
    _endWithoutAnswer(
      sessionKey,
      run.stopRequested ? CoworkRunOutcome.stopped : CoworkRunOutcome.lost,
    );
  }

  /// Opens a tool line. The relay reports one `tool` event per *completed*
  /// command today, so the adapter opens and closes in the same step; a host
  /// that grows real start events gets a live spinner for free.
  ToolCall openTool(
    String sessionKey,
    String name, {
    String? arguments,
    String? callId,
  }) {
    final run = _live(sessionKey);
    // [callId] is the host's id for the call, so the frame that closes it
    // ([recordTool]) finds this line and not another one of the same name.
    final call = ToolCall(
      id: callId,
      name: name,
      arguments: <String, dynamic>{
        if (arguments != null && arguments.isNotEmpty) 'command': arguments,
      },
      status: ToolCallStatus.running,
      startedAt: DateTime.now(),
    );
    run.toolCalls.add(call);
    notifyListeners();
    return call;
  }

  /// Records one finished tool call as the host reported it — THE path for a
  /// `tool` frame that carries its result (every frame from a current host).
  /// Live and replay share [toolCallFromRelay], so the same frame draws the
  /// same card on both. A line the host opened earlier (`status: running`,
  /// same name or same call id) is filled in instead of duplicated.
  ToolCall recordTool(String sessionKey, CoworkRelayTool event) {
    final run = _live(sessionKey);
    final mapped = toolCallFromRelay(event);
    for (var i = run.toolCalls.length - 1; i >= 0; i--) {
      final candidate = run.toolCalls[i];
      if (candidate.status != ToolCallStatus.running) continue;
      // Two known ids that differ are two calls: never fill the other one
      // (P8 review F11). Without a host id the name is all there is.
      if (event.callId != null && candidate.id != event.callId) continue;
      if (candidate.name != event.name) continue;
      // Fill the open line in place: the renderer holds the same object.
      candidate.arguments
        ..clear()
        ..addAll(mapped.arguments);
      candidate.status = mapped.status;
      candidate.result = mapped.result;
      candidate.completedAt = mapped.completedAt;
      notifyListeners();
      return candidate;
    }
    run.toolCalls.add(mapped);
    notifyListeners();
    return mapped;
  }

  /// Closes the newest still-running line called [name] (or appends a closed
  /// one when the host never sent a start).
  ToolCall closeTool(
    String sessionKey,
    String name, {
    String? arguments,
    String? result,
    int? exitCode,
    bool failed = false,
    Duration? duration,
  }) {
    final run = _live(sessionKey);
    ToolCall? call;
    for (var i = run.toolCalls.length - 1; i >= 0; i--) {
      final candidate = run.toolCalls[i];
      if (candidate.name == name &&
          candidate.status == ToolCallStatus.running) {
        call = candidate;
        break;
      }
    }
    call ??= openTool(sessionKey, name, arguments: arguments);
    // Failure is read from the protocol (exit code / timeout / error field),
    // never guessed from the text.
    call.status = failed ? ToolCallStatus.error : ToolCallStatus.completed;
    call.result = result;
    call.completedAt = duration == null
        ? DateTime.now()
        : call.startedAt.add(duration);
    if (exitCode != null) {
      call.arguments['exit_code'] = exitCode;
    }
    notifyListeners();
    return call;
  }

  /// Records a child agent's lifecycle step as its own tool line, opened on the
  /// first state seen and closed when the child reaches a terminal state.
  ToolCall subagent(
    String sessionKey, {
    required String subagentId,
    required String title,
    required String state,
    String? result,
    String? error,
  }) {
    final run = _live(sessionKey);
    final key = '$sessionKey\u0000$subagentId';
    final existing = _subagentCalls[key];
    final call = subagentCallFromRelay(
      existing,
      subagentId: subagentId,
      title: title,
      state: state,
      result: result,
      error: error,
    );
    if (existing == null) {
      _subagentCalls[key] = call;
      run.toolCalls.add(call);
    }
    notifyListeners();
    return call;
  }

  /// Records an automation event as its own tool line, one per automation
  /// id, updated on every later event (docs/WIRE_CONTRACT.md,
  /// "Automations"). The SAME mapping the replay loader uses.
  ToolCall automation(String sessionKey, CoworkRelayAutomation event) {
    final run = _live(sessionKey);
    final key = '$sessionKey\u0000${event.automation.id}';
    final existing = _automationCalls[key];
    final call = automationCallFromRelay(existing, event);
    if (existing == null) {
      _automationCalls[key] = call;
      run.toolCalls.add(call);
    }
    notifyListeners();
    return call;
  }

  /// Lands a relayed file: the bytes go into the local blob store FIRST, and
  /// only then does the `sandboxArtifact` block that points at them get
  /// appended. A block whose bytes were never written would render as a broken
  /// card, so the order is the guarantee, not an optimisation.
  ///
  /// A file that arrived broken (bad base64, size mismatch) writes nothing and
  /// produces no block — [CoworkRelayFile.error] already says why.
  Future<ContentBlock?> file(String sessionKey, CoworkRelayFile file) async {
    final bytes = file.bytes;
    if (bytes == null || !file.isValid) return null;
    final run = _live(sessionKey);
    final String storagePath;
    try {
      storagePath = await ImageStorageService.uploadEncryptedImage(bytes);
    } catch (error) {
      if (kDebugMode) debugPrint('[cowork-ledger] blob write failed: $error');
      return null;
    }
    final block = artifactBlockFromFile(storagePath, file);
    run.blocks.add(block);
    notifyListeners();
    return block;
  }

  /// Records a here.now publish approval as a completed `ask_user` tool call.
  /// The options ride in [ToolCall.arguments] because that is where the
  /// imported `AskUserCard` reads them from; the same payload is mirrored into
  /// [ToolCall.result] so the expanded tool line shows the whole request.
  ToolCall approval(String sessionKey, CoworkRelayApprovalRequest request) {
    final run = _live(sessionKey);
    final call = approvalCallFromRelay(request);
    run.toolCalls.add(call);
    notifyListeners();
    return call;
  }

  /// Accumulates the model's thinking for the run.
  void reasoning(String sessionKey, String text) {
    if (text.isEmpty) return;
    _live(sessionKey).modelReasoning += text;
  }

  /// Stashes the latest raw model context for the copy button. Never rendered.
  void debugContext(String sessionKey, Map<String, dynamic> payload) {
    _ensure(sessionKey).debugContext = payload;
  }

  /// Closes the run. The pile stays on record until the fold [take]s it.
  void finish(
    String sessionKey, {
    String? finalAnswer,
    String? reason,
    int? iterations,
    int? tokensSpent,
    String? runId,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? firstMid,
    int? lastMid,
  }) {
    final run = _ensure(sessionKey);
    run.running = false;
    run.finalAnswer = finalAnswer;
    run.reason = reason;
    run.outcome = coworkRunOutcomeFor(
      reason: reason,
      finalAnswer: finalAnswer,
    );
    run.iterations = iterations;
    run.tokensSpent = tokensSpent;
    if (runId != null) run.runId = runId;
    // The host's clock wins over this client's estimate, once it came.
    if (startedAt != null) {
      run.startedAt = startedAt;
      run.hostStamped = true;
    }
    if (finishedAt != null) run.finishedAt = finishedAt;
    if (firstMid != null) run.firstMid = firstMid;
    if (lastMid != null) run.lastMid = lastMid;
    // Nothing may be left spinning once the host says the run is over.
    finalizeStaleToolCalls(run.toolCalls);
    notifyListeners();
  }

  /// Hands the run for [sessionKey] to the fold and forgets it. Returns null
  /// when nothing was recorded (a turn with no tools, no files, no reasoning
  /// still gets a run from [begin], so null only means "not this session").
  CoworkRun? take(String sessionKey) {
    final run = _runs.remove(sessionKey);
    _subagentCalls.removeWhere((key, _) => key.startsWith('$sessionKey\u0000'));
    _automationCalls.removeWhere(
      (key, _) => key.startsWith('$sessionKey\u0000'),
    );
    if (run != null) {
      run.running = false;
      notifyListeners();
    }
    return run;
  }

  /// Test seam: drop every run.
  @visibleForTesting
  void reset() {
    onRunSilent = null;
    _runs.clear();
    _subagentCalls.clear();
    _automationCalls.clear();
  }

  CoworkRun _ensure(String sessionKey) =>
      _runs[sessionKey] ??= CoworkRun(sessionKey);

  /// [_ensure], plus the proof that the run is alive: every frame that folds
  /// into the run restarts the ceiling, so only a run that truly produces
  /// nothing can be declared lost.
  CoworkRun _live(String sessionKey) {
    final run = _ensure(sessionKey);
    if (run.running) {
      run
        ..lastActivity = DateTime.now()
        ..producedOutput = true
        ..probedAt = null;
    }
    return run;
  }
}
