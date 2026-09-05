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
  final completedAt = event.completedAt ??
      (duration != null ? startedAt.add(duration) : clock);
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
  final call = existing ??
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
    call.status =
        state == 'succeeded' ? ToolCallStatus.completed : ToolCallStatus.error;
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
    _automationCalls.removeWhere((key, _) => key.startsWith('$sessionKey\u0000'));
    final previous = _runs[sessionKey];
    final run = CoworkRun(sessionKey)..running = true;
    // A debug context outlives the run it came from: the copy button wants the
    // latest one for the thread, whichever turn produced it.
    run.debugContext = previous?.debugContext;
    _runs[sessionKey] = run;
    notifyListeners();
    return run;
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
    if (existing != null && existing.running) return;
    final run = CoworkRun(sessionKey)
      ..running = true
      ..runId = runId
      ..detachedPrompt = prompt
      ..startedAt = startedAt ?? DateTime.now()
      ..hostStamped = startedAt != null;
    _runs[sessionKey] = run;
    notifyListeners();
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
    final run = _ensure(sessionKey);
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
    final run = _ensure(sessionKey);
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
    final run = _ensure(sessionKey);
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
    final run = _ensure(sessionKey);
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
    final run = _ensure(sessionKey);
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
    final run = _ensure(sessionKey);
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
    final run = _ensure(sessionKey);
    final call = approvalCallFromRelay(request);
    run.toolCalls.add(call);
    notifyListeners();
    return call;
  }

  /// Accumulates the model's thinking for the run.
  void reasoning(String sessionKey, String text) {
    if (text.isEmpty) return;
    _ensure(sessionKey).modelReasoning += text;
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
    _automationCalls.removeWhere((key, _) => key.startsWith('$sessionKey\u0000'));
    if (run != null) {
      run.running = false;
      notifyListeners();
    }
    return run;
  }

  /// Test seam: drop every run.
  @visibleForTesting
  void reset() {
    _runs.clear();
    _subagentCalls.clear();
  }

  CoworkRun _ensure(String sessionKey) =>
      _runs[sessionKey] ??= CoworkRun(sessionKey);
}
