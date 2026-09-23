/// Agents relay client — the app's transport for a LOCAL run.
///
/// This is the controller (phone/desktop) side of the local relay protocol.
/// It opens one WebSocket to a local host, joins a channel, runs the pairing
/// **joiner** ceremony (§15: joiner = desktop) against the host initiator,
/// then seals/opens Agents frames (§14) over the now-authenticated channel.
///
/// ## Wire protocol (must match the Python host byte for byte)
///
///  * Connect a WebSocket to `ws://<host>:<port>` (default `ws://127.0.0.1:8787`).
///  * First message: `{"type":"join","channel":"<channel_id>","role":"controller"}`.
///    `channel_id` is the part of the pairing code before the **last** `-`.
///  * Pairing envelope:
///    `{"type":"pairing","step":"commit|pubkey|reveal|confirm-d|confirm-c|
///    device-d|device-c","data":{...}}` — `data` is the exact map the Dart
///    pairing state machine produces/consumes. The joiner (this app) sends
///    `pubkey`, `confirm-d` and `device-d`; it consumes `commit`, `reveal`,
///    `confirm-c` and `device-c`.
///  * Sealed frame envelope: `{"type":"frame","frame":"<base64>"}` where the
///    base64 payload is the UTF-8 of [AgentsFrame.toJsonString]
///    ([_frameToWire] / [_frameFromWire]).
///
/// The transport is decoupled from any UI. The WebSocket is injected through a
/// [RelaySocket] seam and a [RelaySocketConnector], so the whole flow is
/// testable against a fake in-Dart executor without a real server.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/skills/agents_skill.dart';
import 'package:chuk_chat/services/agents/agents_approved_devices.dart';
import 'package:chuk_chat/services/agents/agents_frame.dart';
import 'package:chuk_chat/services/agents/agents_frame_codec.dart';
import 'package:chuk_chat/services/agents/agents_pairing.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_reconnect.dart';
import 'package:chuk_chat/services/agents/agents_controller_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart'
    show AgentsCloudRelayAddress;
import 'package:chuk_chat/services/agents/agents_heal_channel.dart';
import 'package:chuk_chat/services/agents/agents_host_session.dart';
import 'package:chuk_chat/services/executor_provisioning.dart';
import 'package:chuk_chat/services/herenow/herenow_store.dart';
import 'package:chuk_chat/services/mcp/mcp_probe_control.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';
import 'package:chuk_chat/services/session_refresh_scheduler.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/websocket_connector.dart' as ws_connector;
import 'package:web_socket_channel/web_socket_channel.dart';

/// A minimal duplex socket seam: an inbound stream of text frames and a way to
/// send text. Injected so the relay client can run against a fake in tests.
abstract interface class RelaySocket {
  /// Frames arriving from the peer. Each element is the raw String (or bytes)
  /// delivered by the underlying transport.
  Stream<dynamic> get incoming;

  /// Sends one text frame to the peer.
  void send(String data);

  /// Closes the socket.
  Future<void> close();
}

/// Opens a [RelaySocket] to [url]. Default is [defaultRelaySocketConnector];
/// tests inject one that returns a fake.
typedef RelaySocketConnector = Future<RelaySocket> Function(Uri url);

/// Production connector.
///
/// Certificate pinning is meaningful only for TLS (`wss://`) to our own
/// backend; the Agents host runs on a plain `ws://` (localhost / LAN), which
/// has no certificate to pin. Using the pinned client for a plain `ws://`
/// breaks the connection in release builds (the socket drops mid-pairing), so
/// we branch: pinned connector for `wss://`, a plain WebSocket for `ws://`.
Future<RelaySocket> defaultRelaySocketConnector(Uri url) async {
  final WebSocketChannel channel = url.scheme == 'wss'
      ? await ws_connector.connectWebSocket(url)
      : WebSocketChannel.connect(url);
  await channel.ready;
  return _WebSocketRelaySocket(channel);
}

class _WebSocketRelaySocket implements RelaySocket {
  _WebSocketRelaySocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get incoming => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}

/// Where the relay client is in its lifecycle. Drives the UI directly.
enum AgentsRelayPhase {
  /// Nothing connected yet.
  idle,

  /// Opening the socket.
  connecting,

  /// Socket open, running the pairing ceremony.
  pairing,

  /// Paired: channel key established, host device approved, frames flow.
  paired,

  /// A failure the user must see (connect refused, pairing aborted).
  error,

  /// The socket closed after having been paired.
  closed,
}

/// Immutable snapshot of the relay client state, exposed as a [ValueListenable].
@immutable
class AgentsRelayState {
  const AgentsRelayState({
    required this.phase,
    this.detail,
    this.sas,
    this.peerDeviceId,
  });

  final AgentsRelayPhase phase;

  /// Human-readable status or error message (safe to show).
  final String? detail;

  /// The short authentication string, for optional on-screen reassurance.
  final String? sas;

  /// The approved host device id, once paired.
  final String? peerDeviceId;

  bool get isPaired => phase == AgentsRelayPhase.paired;

  @override
  bool operator ==(Object other) =>
      other is AgentsRelayState &&
      other.phase == phase &&
      other.detail == detail &&
      other.sas == sas &&
      other.peerDeviceId == peerDeviceId;

  @override
  int get hashCode => Object.hash(phase, detail, sas, peerDeviceId);
}

/// A decoded, opened frame delivered from the executor into the thread.
sealed class AgentsRelayInbound {
  const AgentsRelayInbound();
}

/// The host says the run for [sessionKey] is still running (wire `heartbeat`).
///
/// The one frame that carries no content on purpose. A model reading a long
/// prompt sends no token until the prefill is done, and a shell command or a
/// browser step sends none while it works, so a healthy run can be silent for
/// minutes. Without this, the app cannot tell that silence from a host that is
/// gone — and it used to guess, which is how a working run was reported to the
/// user as an overloaded server.
///
/// [seq] counts up from 1 per run and [elapsedSeconds] is the host's own clock
/// on the run; both are diagnostics. A host too old to send heartbeats simply
/// never produces one, and nothing may require them.
class AgentsRelayHeartbeat extends AgentsRelayInbound {
  const AgentsRelayHeartbeat({
    this.runId,
    this.sessionKey,
    this.seq = 0,
    this.elapsedSeconds,
  });
  final String? runId;
  final String? sessionKey;
  final int seq;
  final double? elapsedSeconds;
}

/// The host says what it did with one `task` frame (wire `task_ack`).
///
/// The frame that turns a silent drop into an answer. A `task` used to be
/// fire-and-forget: the app sealed it, the socket said "sent", and if the host
/// was not provisioned for the current controller session it fell off the end
/// of its handler — no run, no log, no error. The app could not tell that apart
/// from a frame that never left the phone, so the thread kept the typing dots
/// for ever (the 04:49 message that was simply gone).
///
/// One ack per `task` that carried a [taskId]. [status] is the whole contract:
///  * `accepted` — the host holds the task and handed it to the executor;
///  * `duplicate` — the host already took this [taskId]. It is running or
///    finished. Do not send it again and do not paint a second bubble;
///  * `rejected` — the host could not take it, and [reason] says why
///    (`not_provisioned`, `queue_full`, `malformed`).
///
/// No ack at all now means one thing only: the frame never reached the host.
class AgentsRelayTaskAck extends AgentsRelayInbound {
  const AgentsRelayTaskAck({
    required this.taskId,
    required this.status,
    this.sessionKey,
    this.runId,
    this.reason,
  });

  /// The app's own id for the send, echoed back byte for byte.
  final String taskId;

  /// `accepted`, `duplicate` or `rejected`.
  final String status;

  /// The thread the task belongs to; null on a host that leaves the key off.
  final String? sessionKey;

  /// The executor's id for the work, when the host knows one (accepted, and
  /// duplicate once the first attempt started running). The wire calls it
  /// `request_id`; an older host that sent `run_id` is read the same way.
  final String? runId;

  /// Short slug, only on a rejection: `not_provisioned`, `queue_full` or
  /// `malformed` (docs/WIRE_CONTRACT.md, "Task acknowledgement").
  final String? reason;

  /// True while the host holds the task: nothing to re-send, nothing to draw.
  bool get isHeld => status == 'accepted' || status == 'duplicate';

  /// True when the host already had this task. The app must stay quiet: the
  /// answer is coming from the first attempt.
  bool get isDuplicate => status == 'duplicate';

  /// True when the host refused the task. This is a real failure, and the
  /// thread has to say so instead of spinning.
  bool get isRejected => status == 'rejected';

  /// The one rejection the app can do something about: re-provision, then send
  /// the same task id again.
  bool get isRetryable => isRejected && reason == 'not_provisioned';

  /// Null for a frame that names no task — there would be nothing to clear.
  static AgentsRelayTaskAck? fromPayload(Map<String, dynamic> payload) {
    final id = payload['task_id'];
    if (id is! String || id.isEmpty) return null;
    final status = payload['status'];
    final session = payload['session_key'];
    final runId = payload['request_id'] ?? payload['run_id'];
    final reason = payload['reason'];
    return AgentsRelayTaskAck(
      taskId: id,
      // An unknown status is treated as a rejection: the app must never keep
      // waiting on a word it does not understand.
      status: status is String && status.isNotEmpty ? status : 'rejected',
      sessionKey: session is String && session.isNotEmpty ? session : null,
      runId: runId is String && runId.isNotEmpty ? runId : null,
      reason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }
}

/// An assistant text delta.
class AgentsRelayDelta extends AgentsRelayInbound {
  const AgentsRelayDelta(
    this.text, {
    this.replay = false,
    this.mid,
    this.sentAt,
  });
  final String text;
  final DateTime? sentAt;

  /// True when this delta is part of a transcript replay, not a live run. The
  /// UI renders it as history: no streaming caret, no running spinner.
  final bool replay;

  /// The message-store row id of this event, the replay cursor. Every replayed
  /// event carries one; a live event may. The app keeps the highest [mid] it
  /// saw per session and sends it back as `after_id` on the next replay, so the
  /// host only re-streams what the app is missing. Null on a host too old to
  /// report it, and on live events that carry none.
  final int? mid;
}

/// A user turn, only ever produced by a transcript replay (the server is the
/// truth). A live run never streams the user's own message back, because the
/// live client wrote it locally; a reconnecting or reinstalled client did not,
/// so replay must carry both sides of the thread. [replay] is always true here.
class AgentsRelayUser extends AgentsRelayInbound {
  const AgentsRelayUser(this.text, {this.replay = true, this.mid, this.sentAt});
  final String text;
  final DateTime? sentAt;

  /// Always true: a user event exists only in a replay stream.
  final bool replay;

  /// The message-store row id of this turn — the replay cursor. See
  /// [AgentsRelayDelta.mid].
  final int? mid;
}

/// A reasoning delta — the model's thinking, which is a separate channel from
/// the answer and is rendered separately (never folded into the reply text).
///
/// The host emits it live and in a replay (`{"type":"reasoning"}`, docs/
/// WIRE_CONTRACT.md; landed by session b5, HANDOVER_2026-09-05_REASONING_
/// TOOLFRAMES.md) whenever the model's reasoning effort is on.
class AgentsRelayReasoning extends AgentsRelayInbound {
  const AgentsRelayReasoning(
    this.text, {
    this.replay = false,
    this.mid,
    this.sentAt,
  });
  final String text;
  final DateTime? sentAt;

  /// True when this is a stored turn re-streamed by a replay, not the model
  /// thinking right now. Without it the adapter cannot tell the two apart and
  /// a replayed thought would render as a live one.
  final bool replay;

  /// The replay cursor of the row this came from, when the host sent one.
  final int? mid;
}

/// A host clock value (unix seconds, float) as a local [DateTime]. Null for
/// anything that is not a number.
DateTime? epochSecondsToDateTime(Object? value) {
  if (value is! num) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (value * 1000).round(),
    isUtc: true,
  ).toLocal();
}

/// One tool call that ran, as reported by the executor.
///
/// The executor's `tool` payload carries `name`, `command`, `exit_code`,
/// `stdout`, `stderr` and `timed_out`. Those map onto a short argument form, a
/// short result form, the full detail for the expanded view, and success vs
/// failure. [duration] is only ever set when the host actually reports a
/// `duration_ms` — it is never guessed.
class AgentsRelayTool extends AgentsRelayInbound {
  const AgentsRelayTool(
    this.name, {
    this.status,
    this.arguments,
    this.result,
    this.detail,
    this.exitCode,
    this.timedOut = false,
    this.duration,
    this.failed = false,
    this.replay = false,
    this.mid,
    this.argumentMap,
    this.callId,
    this.startedAt,
    this.completedAt,
    this.raw = const {},
  });

  /// Builds a tool line from a decoded `tool` payload.
  factory AgentsRelayTool.fromPayload(Map<String, dynamic> payload) {
    final name = '${payload['name'] ?? payload['tool'] ?? 'tool'}';
    final status = payload['status'];
    final exitCode = _asInt(payload['exit_code']);
    final timedOut = payload['timed_out'] == true;
    final stdout = _asText(payload['stdout']);
    final stderr = _asText(payload['stderr']);
    // The native arguments (docs/WIRE_CONTRACT.md, "Tool events and
    // timestamps"): an object on a current host, a string the loop could not
    // parse, or absent on an old host that only sent `command`.
    final rawArguments = payload['arguments'];
    final argumentMap = rawArguments is Map
        ? Map<String, dynamic>.from(rawArguments)
        : null;
    final arguments = _asText(payload['command']) ?? _asText(rawArguments);
    // Failure is read from the protocol, never from the text: the host's own
    // verdict when it sent one, else a non-zero exit code, a timeout, or an
    // explicit error field.
    final failed =
        status == 'error' ||
        timedOut ||
        (exitCode != null && exitCode != 0) ||
        payload['error'] != null;
    final detailParts = <String>[
      if (stdout != null && stdout.isNotEmpty) stdout,
      if (stderr != null && stderr.isNotEmpty) stderr,
    ];
    // `result` is the text the model got; stdout/stderr are its projection on
    // the shell tools, and the fallback on an old host.
    final result =
        _asText(payload['result']) ??
        _asText(payload['error']) ??
        (stderr != null && stderr.isNotEmpty && failed ? stderr : stdout);
    return AgentsRelayTool(
      name,
      status: status is String ? status : null,
      arguments: arguments,
      result: result,
      detail: detailParts.isEmpty ? null : detailParts.join('\n'),
      exitCode: exitCode,
      timedOut: timedOut,
      duration: _asDuration(payload['duration_ms']),
      failed: failed,
      replay: payload['replay'] == true,
      mid: _asInt(payload['mid']),
      argumentMap: argumentMap,
      callId: _asText(payload['call_id']),
      startedAt: epochSecondsToDateTime(payload['started_at']),
      completedAt: epochSecondsToDateTime(payload['completed_at']),
      raw: payload,
    );
  }

  final String name;
  final String? status;

  /// Short form of what the tool was called with (for `run_command`: the
  /// command line).
  final String? arguments;

  /// Short form of what came back.
  final String? result;

  /// The full output, shown only when the line is expanded.
  final String? detail;

  final int? exitCode;
  final bool timedOut;

  /// Wall-clock duration, only when the host reported one.
  final Duration? duration;

  /// True when the protocol says the call failed (non-zero exit, timeout, or an
  /// explicit error).
  final bool failed;

  /// True when this tool line is part of a transcript replay, not a live run.
  final bool replay;

  /// The message-store row id of this call — the replay cursor. See
  /// [AgentsRelayDelta.mid].
  final int? mid;

  /// The native arguments as the model sent them, when the host forwarded
  /// them as an object. Null on an old host (only [arguments] then).
  final Map<String, dynamic>? argumentMap;

  /// The host's id for this call, when it sent one. Live and replay carry the
  /// same id for the same call, so a card keeps its identity across both.
  final String? callId;

  /// The host's clock for the call: when it was dispatched and when its result
  /// came back. Null on an old host; the ledger then uses its own clock.
  final DateTime? startedAt;
  final DateTime? completedAt;

  final Map<String, dynamic> raw;

  static String? _asText(Object? value) => value is String ? value : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static Duration? _asDuration(Object? value) {
    final ms = _asInt(value);
    if (ms == null || ms < 0) return null;
    return Duration(milliseconds: ms);
  }
}

/// A file the agent produced and pushed into the thread (§9,
/// `send_file_to_user`).
///
/// The base64 body is decoded exactly **once**, here in the transport, and only
/// the resulting bytes travel on. The encoded string is never kept, so a big
/// screenshot does not sit in memory twice. A body that does not decode, or
/// whose length contradicts the declared [declaredSize], arrives with
/// [bytes] null and [error] set, so the UI can show a failure card instead of
/// crashing.
class AgentsRelayFile extends AgentsRelayInbound {
  const AgentsRelayFile({
    required this.name,
    required this.mimeType,
    required this.declaredSize,
    this.bytes,
    this.error,
    this.replay = false,
    this.mid,
    this.document,
  });

  final String name;
  final String mimeType;
  final int? declaredSize;
  final Uint8List? bytes;
  final String? error;
  final Map<String, dynamic>? document;

  /// True when this file came back from the host's transcript, not from a
  /// live run (docs/WIRE_CONTRACT.md, "Persisted subagent / file / approval
  /// events"). A replayed file carries its row id in [mid].
  final bool replay;
  final int? mid;

  bool get isImage => mimeType.startsWith('image/');
  bool get isValid => bytes != null && error == null;
}

/// The run finished. The executor reports why, and how many rounds it took.
class AgentsRelayDone extends AgentsRelayInbound {
  const AgentsRelayDone({
    this.finalAnswer,
    this.sessionKey,
    this.hostNotified = false,
    this.reason,
    this.iterations,
    this.tokensSpent,
    this.replay = false,
    this.runId,
    this.whileAway = false,
    this.startedAt,
    this.finishedAt,
    this.firstMid,
    this.lastMid,
    this.hasMore = false,
    this.oldestMid,
    this.pageBeforeId,
  });

  /// The loop's own final answer, when it sent one.
  final String? finalAnswer;
  final String? sessionKey;
  final bool hostNotified;

  /// The run's clock on the host (docs/WIRE_CONTRACT.md, "Run timestamps on
  /// done"). Null on an old host.
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// The run's length as the host measured it, when both clocks came.
  Duration? get workedFor {
    final started = startedAt;
    final finished = finishedAt;
    if (started == null || finished == null) return null;
    final elapsed = finished.difference(started);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// The message rows of this run. [lastMid] on a LIVE `done` is where the
  /// replay cursor moves to, so the next replay does not send this run again.
  final int? firstMid;
  final int? lastMid;

  /// Replay paging (docs/WIRE_CONTRACT.md, Bead cowork-axx), on the
  /// history-end `done` of a paged replay only: whether an older page exists,
  /// the first row of this page (ask `before_id: oldestMid` for the next), and
  /// the `before_id` this page was asked with (null on the newest page).
  final bool hasMore;
  final int? oldestMid;
  final int? pageBeforeId;

  /// The termination reason the runtime reported (`finished`, `estop`,
  /// `interrupted`, …).
  final String? reason;

  /// How many rounds the loop ran.
  final int? iterations;

  /// Tokens the run spent (prompt + completion), for a cost readout. Null for a
  /// host too old to report it; zero when the backend sent no usage.
  final int? tokensSpent;

  /// True when the run ended because the kill switch fired, not because the
  /// agent finished. Read from the protocol's reason, never from text.
  /// Stopped short of an answer: the user's stop, the ESTOP file, or the
  /// host's wall-clock guard (`timeout`, Bead cowork-qxa). All render alike.
  bool get wasStopped =>
      reason == 'estop' || reason == 'interrupted' || reason == 'timeout';

  /// True when this ``done`` closes a transcript replay, not a live run. The UI
  /// must NOT render it as a "done" card and must not treat it as a run ending —
  /// it only marks the end of the replayed history. Also flagged by [replay].
  final bool replay;

  /// True when the closed stream was a replay, by flag or by reason.
  bool get isReplay => replay || reason == 'replay';

  /// True only for the history-end marker that closes a replay stream
  /// (`reason == 'replay'`). It renders nothing and ends replay mode.
  ///
  /// This is the distinction [isReplay] cannot make: a *persisted run terminal*
  /// replayed from the host also arrives with `replay == true`, but it carries a
  /// real reason (`finished`, …) and must be rendered as a completion card.
  bool get isHistoryEnd => reason == 'replay';

  /// The host's id for the run this `done` closes, when it reported one. The
  /// app echoes it back with [AgentsRelayController.sendRunAck] after it
  /// rendered a live `done`, so the host marks the run seen.
  final String? runId;

  /// True when a replayed run terminal finished with no app attached (the host
  /// never got a `run_ack` for it). The UI shows an "Answer ready" affordance.
  final bool whileAway;
}

/// The host's answer to a `replay`: is a run for this session in flight right
/// now (§ run detachment)? Emitted first in every replay response, before the
/// stored transcript.
///
/// A run belongs to the host process, not to a socket, so a run started before
/// this app connected — or before it was reinstalled — is still going. The app
/// shows "Working…" with the original [prompt] instead of an idle composer.
class AgentsRelayRunState extends AgentsRelayInbound {
  const AgentsRelayRunState({
    required this.sessionKey,
    required this.state,
    this.runId,
    this.startedAt,
    this.prompt,
    this.browserOpen,
    this.vncAvailable = false,
  });

  /// Builds a run state from a decoded `run_state` payload, or null when the
  /// session key or state is missing (nothing to route it to). Dropped, never
  /// thrown, so a malformed frame cannot break the socket read loop.
  static AgentsRelayRunState? fromPayload(Map<String, dynamic> payload) {
    final sessionKey = payload['session_key'];
    final state = payload['state'];
    if (sessionKey is! String || state is! String) return null;
    final runId = payload['run_id'];
    final startedAt = payload['started_at'];
    final prompt = payload['prompt'];
    final browserOpen = payload['browser_open'];
    return AgentsRelayRunState(
      sessionKey: sessionKey,
      state: state,
      runId: runId is String && runId.isNotEmpty ? runId : null,
      startedAt: startedAt is num ? startedAt.toDouble() : null,
      prompt: prompt is String ? prompt : null,
      browserOpen: browserOpen is bool ? browserOpen : null,
      vncAvailable: payload['vnc_available'] == true,
    );
  }

  /// The thread this state is about — the same key the replay named.
  final String sessionKey;

  /// The raw state string the host reported: `running` or `idle`. Read from the
  /// protocol, never guessed.
  final String state;

  /// The in-flight run's id, when one is running.
  final String? runId;

  /// Unix seconds when the run started, for an elapsed readout.
  final double? startedAt;

  /// The prompt the in-flight run is working on, so the app can show what it is
  /// busy with even though it never saw the send.
  final String? prompt;

  /// Whether the agent has a browser open, as the host sees it (Bead
  /// cowork-vzm, `browser_open`). Null on a host that does not send it.
  final bool? browserOpen;
  final bool vncAvailable;

  /// True when a run for [sessionKey] is in flight on the host.
  bool get isRunning => state == 'running';
}

/// A child agent's lifecycle step (§7.6). Only state transitions surface here —
/// `queued` → `running` → `succeeded`/`failed`/`cancelled` — so the thread shows
/// the shape of a delegated fan-out without drowning in each child's own
/// streamed output. Built from a `subagent_state` event; a `subagent_output`
/// event (a child's delta/tool) is not turned into one of these.
class AgentsRelaySubagent extends AgentsRelayInbound {
  const AgentsRelaySubagent({
    required this.subagentId,
    required this.title,
    required this.state,
    this.result,
    this.error,
    this.tokensSpent,
    this.replay = false,
    this.mid,
  });

  /// True when this state came back from the host's transcript (one frame per
  /// stored state row; the app keeps one card per [subagentId], last state
  /// wins). A replayed state carries its row id in [mid].
  final bool replay;
  final int? mid;

  /// The child's stable id (`sa_…`).
  final String subagentId;

  /// The child's title, as the parent named it. May be empty.
  final String title;

  /// The lifecycle state string the runtime reported: `queued`, `running`,
  /// `succeeded`, `failed`, `cancelled`. Read from the protocol, never guessed.
  final String state;

  /// The child's final result, on success. Null until then.
  final String? result;

  /// The child's error text, on failure. Null otherwise.
  final String? error;

  /// Tokens (prompt + completion) the child spent. Null when the runtime did
  /// not report any (a child that reported no usage omits it).
  final int? tokensSpent;

  /// True once the child has reached a terminal state.
  bool get isTerminal =>
      state == 'succeeded' || state == 'failed' || state == 'cancelled';
}

/// One state change of an automation (docs/WIRE_CONTRACT.md, "Automations"):
/// `created` / `fired` / `paused` / `resumed` / `cancelled` / `failed` /
/// `done`. Live, and replayed from the host's transcript (`replay`, `mid`).
/// The app keeps ONE card per [AgentsAutomation.id]; the last event wins.
class AgentsRelayAutomation extends AgentsRelayInbound {
  const AgentsRelayAutomation({
    required this.event,
    required this.automation,
    this.runId,
    this.reason,
    this.at,
    this.replay = false,
    this.mid,
  });

  /// Which change this is.
  final String event;

  /// The automation's whole state after the change.
  final AgentsAutomation automation;

  /// On `fired`: the run the automation started.
  final String? runId;

  /// On `fired` from a watcher: the reason the script gave `trigger()`.
  final String? reason;

  /// When the host recorded the change.
  final DateTime? at;

  final bool replay;
  final int? mid;

  /// Builds one from a decoded `automation` payload, or null when it names
  /// no automation. Dropped, never thrown.
  static AgentsRelayAutomation? fromPayload(Map<String, dynamic> payload) {
    final automation = AgentsAutomation.fromPayload(payload);
    if (automation == null) return null;
    final rawEvent = payload['event'];
    final rawRun = payload['run_id'];
    final rawReason = payload['reason'];
    return AgentsRelayAutomation(
      event: rawEvent is String && rawEvent.isNotEmpty ? rawEvent : 'updated',
      automation: automation,
      runId: rawRun is String && rawRun.isNotEmpty ? rawRun : null,
      reason: rawReason is String && rawReason.isNotEmpty ? rawReason : null,
      at: epochSecondsToDateTime(payload['at']),
      replay: payload['replay'] == true,
      mid: AgentsRelayTool._asInt(payload['mid']),
    );
  }
}

/// The host's answer to an `automation_list` request: every automation of
/// [sessionKey], or of the whole host when [sessionKey] is null.
class AgentsRelayAutomationList extends AgentsRelayInbound {
  const AgentsRelayAutomationList({required this.automations, this.sessionKey});

  final List<AgentsAutomation> automations;
  final String? sessionKey;

  static AgentsRelayAutomationList fromPayload(Map<String, dynamic> payload) {
    final raw = payload['automations'];
    final list = <AgentsAutomation>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          final automation = AgentsAutomation.fromPayload(
            entry.map((k, v) => MapEntry('$k', v)),
          );
          if (automation != null) list.add(automation);
        }
      }
    }
    final scope = payload['session_key'];
    return AgentsRelayAutomationList(
      automations: list,
      sessionKey: scope is String && scope.isNotEmpty ? scope : null,
    );
  }
}

/// The host's answer to a `skills_list` request or a `skill_control`
/// (docs/WIRE_CONTRACT.md, "Skills"): every skill of the host with its switch,
/// plus what the host could not load or refused.
class AgentsRelaySkillsList extends AgentsRelayInbound {
  const AgentsRelaySkillsList({
    required this.skills,
    this.errors = const <String>[],
  });

  final List<AgentsSkill> skills;
  final List<String> errors;

  static AgentsRelaySkillsList fromPayload(Map<String, dynamic> payload) {
    final raw = payload['skills'];
    final list = <AgentsSkill>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          final skill = AgentsSkill.fromPayload(
            entry.map((k, v) => MapEntry('$k', v)),
          );
          if (skill != null) list.add(skill);
        }
      }
    }
    final rawErrors = payload['errors'];
    final errors = <String>[
      if (rawErrors is List)
        for (final e in rawErrors)
          if (e is String && e.isNotEmpty) e,
    ];
    return AgentsRelaySkillsList(skills: list, errors: errors);
  }
}

/// What one coworker runs on, has spent and how long it has worked
/// (docs/WIRE_CONTRACT.md, "Agent status"; bead cowork-6ag).
///
/// Every block is nullable on purpose: the host sends a block only for a figure
/// it **measured**. A missing block is "nothing measured yet", which is not the
/// same as zero, and the panel must be able to tell them apart.
@immutable
class AgentsRelayAgentStatus {
  const AgentsRelayAgentStatus({
    required this.sessionKey,
    this.model,
    this.tokens,
    this.runtime,
    this.sandbox,
  });

  final String sessionKey;

  /// `{id, provider?, reasoning_effort?, source}`.
  final Map<String, dynamic>? model;

  /// `{total, runs, last_run}`.
  final Map<String, dynamic>? tokens;

  /// `{started_at, active_seconds, runs, running, current_seconds?}`.
  final Map<String, dynamic>? runtime;

  /// `{kind, container?, container_id?, workspace?}`.
  final Map<String, dynamic>? sandbox;

  static Map<String, dynamic>? _block(Object? value) {
    if (value is! Map) return null;
    return value.map((k, v) => MapEntry('$k', v));
  }

  static AgentsRelayAgentStatus fromPayload(Map<String, dynamic> payload) {
    final key = payload['session_key'];
    return AgentsRelayAgentStatus(
      sessionKey: key is String ? key : 'default',
      model: _block(payload['model']),
      tokens: _block(payload['tokens']),
      runtime: _block(payload['runtime']),
      sandbox: _block(payload['sandbox']),
    );
  }
}

/// One coworker name the host keeps for this pairing (bead cowork-817,
/// WIRE_CONTRACT "Coworker names"). [host] marks the coworker that runs on
/// the host itself; its [agentId] is `host:<device_id>`.
@immutable
class AgentsHostAgentName {
  const AgentsHostAgentName({
    required this.agentId,
    required this.name,
    this.host = false,
  });

  final String agentId;
  final String name;
  final bool host;

  @override
  bool operator ==(Object other) =>
      other is AgentsHostAgentName &&
      other.agentId == agentId &&
      other.name == name &&
      other.host == host;

  @override
  int get hashCode => Object.hash(agentId, name, host);
}

/// The host's `agent_list`: every coworker name it keeps, sent once per attach
/// and after each `agent_create` / `agent_rename` it applied.
class AgentsRelayAgentList extends AgentsRelayInbound {
  const AgentsRelayAgentList({required this.agents});

  final List<AgentsHostAgentName> agents;

  static AgentsRelayAgentList fromPayload(Map<String, dynamic> payload) {
    final raw = payload['agents'];
    final list = <AgentsHostAgentName>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final id = entry['agent_id'];
        final name = entry['name'];
        if (id is! String || id.isEmpty || name is! String) continue;
        final trimmed = name.trim();
        if (trimmed.isEmpty) continue;
        list.add(
          AgentsHostAgentName(
            agentId: id,
            name: trimmed,
            host: entry['host'] == true,
          ),
        );
      }
    }
    return AgentsRelayAgentList(agents: list);
  }
}

/// One member's turn in a group room (§16.1). Streamed live as the room talks.
class AgentsRelayRoomTurn extends AgentsRelayInbound {
  const AgentsRelayRoomTurn({
    required this.roomId,
    required this.round,
    required this.agentId,
    required this.handle,
    required this.text,
  });

  /// Which room this turn belongs to, so the app routes it to the right open
  /// room when several run at once.
  final String roomId;

  final int round;
  final String agentId;
  final String handle;
  final String text;
}

/// A group-room exchange ended. [reason] is a raw stop string from the host
/// (`no_more_mentions` / `rounds_exhausted` / `messages_exhausted` / `stopped` /
/// `turn_failed`); the UI maps it through `AgentsRoomStop.fromWire`.
class AgentsRelayRoomDone extends AgentsRelayInbound {
  const AgentsRelayRoomDone({
    required this.roomId,
    required this.reason,
    this.messagesSent,
    this.rounds,
  });

  /// Which room ended.
  final String roomId;

  final String reason;
  final int? messagesSent;
  final int? rounds;
}

/// A room's stored transcript, replayed on request (§16.1). Replaces whatever
/// the page currently shows for [roomId] with [turns].
class AgentsRelayRoomHistory extends AgentsRelayInbound {
  const AgentsRelayRoomHistory({required this.roomId, required this.turns});

  final String roomId;
  final List<AgentsRelayRoomTurn> turns;
}

/// The executor reported an error.
class AgentsRelayRunError extends AgentsRelayInbound {
  const AgentsRelayRunError(this.message);
  final String message;
}

/// The raw context the executor sent to the model for one round, echoed back
/// only when the task was sent with `debug: true` (the developer "capture model
/// context" toggle). It is a developer aid: the thread keeps the latest one per
/// session so it can be copied to the clipboard, and it never renders in the
/// conversation. [payload] is the whole decoded event, so nothing is lost — the
/// named fields are the ones the copy button reads first.
class AgentsRelayDebugContext extends AgentsRelayInbound {
  const AgentsRelayDebugContext({
    required this.sessionKey,
    required this.payload,
    this.round,
  });

  /// The session the context belongs to — the same key the task was sent with.
  final String sessionKey;

  /// Which round of the run this context is for, when the host reported one.
  final int? round;

  /// The whole decoded `debug_context` payload (messages, stats, everything),
  /// kept verbatim so the copy button has the full picture.
  final Map<String, dynamic> payload;
}

/// One raw RFB byte chunk of the live browser view (§9.1). Opaque on purpose —
/// the RFB protocol is spoken by `flutter_rfb`, never parsed here.
class AgentsRelayBrowserData extends AgentsRelayInbound {
  const AgentsRelayBrowserData(this.bytes);
  final Uint8List bytes;
}

/// Status of the live browser view: `started`, `stopped`, or `error` (§9.1).
class AgentsRelayBrowserView extends AgentsRelayInbound {
  const AgentsRelayBrowserView({
    required this.status,
    this.message = '',
    this.password,
    this.vncAvailable = false,
    this.reason = '',
  });
  final String status;
  final String message;

  /// The machine-readable half of [message] (`docs/WIRE_CONTRACT.md`,
  /// bead cowork-qp5i): `opening` / `no_browser` on `started`, and
  /// `no_sandbox` / `no_display` / `vnc_start_failed` / `exec_failed` /
  /// `bridge_failed` on `error`. Empty when there is nothing to explain, and
  /// empty from a host too old to send it — so a reader falls back to the
  /// text only when this is empty, and fails closed when it is a code it does
  /// not know.
  final String reason;

  /// Per-view VNC secret, only on `started` (§9.1 hardening). Never log it.
  final String? password;
  final bool vncAvailable;
}

/// The executor is asking the user to approve one here.now publish before it
/// runs (the connector's `ask` mode). The run **blocks** on the executor until
/// the app answers with a matching decision, so the UI must surface this as a
/// standing prompt, not a transient one. The reply goes back through
/// [AgentsRelayController.sendApprovalDecision], correlated by [approvalId].
class AgentsRelayApprovalRequest extends AgentsRelayInbound {
  const AgentsRelayApprovalRequest({
    required this.approvalId,
    required this.action,
    required this.path,
    required this.name,
    required this.fileCount,
    required this.totalBytes,
    required this.baseUrl,
    required this.public,
    this.replay = false,
    this.mid,
    this.decision,
    this.decisionReason,
    this.sessionKey,
  });

  /// The thread whose run is waiting on this decision, when the host says
  /// (`session_key`, additive). A view for another thread leaves the prompt
  /// to the view that owns it; null (an older host) means "the thread on this
  /// socket", as before (review F9).
  final String? sessionKey;

  /// True when the request came back from the host's transcript. A replayed
  /// request with a [decision] is information, never a prompt, and no
  /// `approval_decision` is sent for it (docs/WIRE_CONTRACT.md, "Persisted
  /// subagent / file / approval events"). One without a decision is a host
  /// still waiting — only possible while the run is in flight.
  final bool replay;
  final int? mid;

  /// `approved` / `denied` once the host knows the outcome; null while open.
  final String? decision;

  /// `user` / `timeout` / `stopped`; null while open.
  final String? decisionReason;

  bool get isDecided => decision != null && decision!.isNotEmpty;
  bool get isApproved => decision == 'approved';

  /// Builds an approval request from a decoded `approval_request` payload, or
  /// null when the id is missing (nothing to correlate a decision to). Dropped,
  /// never thrown, so a malformed frame cannot break the socket read loop.
  static AgentsRelayApprovalRequest? fromPayload(Map<String, dynamic> payload) {
    final id = payload['approval_id'];
    if (id is! String || id.isEmpty) return null;
    final rawName = payload['name'];
    final rawPath = payload['path'];
    return AgentsRelayApprovalRequest(
      approvalId: id,
      action: '${payload['action'] ?? 'publish'}',
      path: rawPath is String ? rawPath : '',
      name: rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : (rawPath is String ? rawPath : ''),
      fileCount: AgentsRelayTool._asInt(payload['file_count']) ?? 0,
      totalBytes: AgentsRelayTool._asInt(payload['total_bytes']) ?? 0,
      baseUrl: '${payload['base_url'] ?? 'here.now'}',
      public: payload['public'] != false,
      replay: payload['replay'] == true,
      mid: AgentsRelayTool._asInt(payload['mid']),
      decision:
          payload['decision'] is String &&
              (payload['decision'] as String).isNotEmpty
          ? payload['decision'] as String
          : null,
      decisionReason: payload['decision_reason'] is String
          ? payload['decision_reason'] as String
          : null,
      sessionKey:
          payload['session_key'] is String &&
              (payload['session_key'] as String).isNotEmpty
          ? payload['session_key'] as String
          : null,
    );
  }

  /// Correlates the decision back to this request.
  final String approvalId;

  /// What is being approved (today always `herenow_publish`).
  final String action;

  /// The workspace path going out, and a friendly name for it.
  final String path;
  final String name;

  /// How much is going out: file count and total byte size.
  final int fileCount;
  final int totalBytes;

  /// The here.now host the site will live under.
  final String baseUrl;

  /// True when the site will be publicly viewable by anyone with the link
  /// (always true on the anonymous free tier).
  final bool public;
}

/// The model asked for secrets by name (`request_secrets`) and the run is
/// BLOCKED on the executor until the app answers with a `secrets` frame
/// (docs/WIRE_CONTRACT.md, "Secrets"). The UI shows one field per name over
/// the thread [sessionKey] names; the answer goes back through
/// `SecretsService` (`setMany(..., requestId:)` or `answerUnchanged`), which
/// sends the WHOLE set with this [requestId].
class AgentsRelaySecretRequest extends AgentsRelayInbound {
  const AgentsRelaySecretRequest({
    required this.requestId,
    required this.names,
    this.purpose = '',
    this.sessionKey,
  });

  /// Correlates the `secrets` answer back to this request.
  final String requestId;

  /// Environment-variable style names, in the order the model asked.
  final List<String> names;

  /// The model's one-line reason, shown in the card.
  final String purpose;

  /// The thread whose run waits; null on an older host means this socket's.
  final String? sessionKey;

  /// Builds a request from a decoded `secret_request` payload, or null when
  /// nothing can be correlated or asked. Dropped, never thrown.
  static AgentsRelaySecretRequest? fromPayload(Map<String, dynamic> payload) {
    final id = payload['request_id'];
    if (id is! String || id.isEmpty) return null;
    final rawNames = payload['names'];
    if (rawNames is! List) return null;
    final names = <String>[
      for (final n in rawNames)
        if (n is String && n.isNotEmpty) n,
    ];
    if (names.isEmpty) return null;
    final purpose = payload['purpose'];
    final sessionKey = payload['session_key'];
    return AgentsRelaySecretRequest(
      requestId: id,
      names: List<String>.unmodifiable(names),
      purpose: purpose is String ? purpose : '',
      sessionKey: sessionKey is String && sessionKey.isNotEmpty
          ? sessionKey
          : null,
    );
  }
}

/// Read-only surface the UI depends on, so widget tests can drive a fake
/// without a socket or a real pairing ceremony.
/// How many turn rows a full replay asks for first (docs/WIRE_CONTRACT.md,
/// "Replay paging"): enough for a screenful and a scroll, small enough to
/// paint a long thread at once. Older pages follow while the host has more.
const int kReplayPageSize = 200;

abstract interface class AgentsRelayController {
  /// Current lifecycle state; rebuild the UI when it changes.
  ValueListenable<AgentsRelayState> get state;

  /// Opened frames from the executor (deltas, tools, done, error).
  Stream<AgentsRelayInbound> get inbound;

  /// Connects, joins [pairingCode]'s channel, and runs the joiner ceremony
  /// against [hostUrl]. Throws (and moves to [AgentsRelayPhase.error]) on any
  /// pairing failure.
  Future<void> connect({required Uri hostUrl, required String pairingCode});

  /// Reconnects to an already-paired host with NO code, running the mutual
  /// signed-nonce reconnect handshake against the host and resuming the sealed
  /// channel from the stored channel key. Throws (and moves to
  /// [AgentsRelayPhase.error]) if the handshake fails (e.g. an imposter host).
  Future<void> reconnect({
    required Uri hostUrl,
    required AgentsStoredPairing pairing,
  });

  /// The trust established by the last successful [connect] / [reconnect], for
  /// the caller to persist. Null until paired.
  AgentsStoredPairing? get establishedTrust;

  /// Hands the executor the account token over the sealed channel.
  Future<void> provisionAccount(AccountSession session);

  /// Seals and sends a task prompt. [sessionKey] selects the thread on the
  /// executor side: one agent, many threads (§4). The executor resumes the
  /// append-only session that key routes to.
  ///
  /// [modelId], [providerSlug] and [reasoningEffort] name the model the task
  /// runs on, chosen per send in the composer's mode picker. Each is optional:
  /// an empty or null value is left off the frame, so the host keeps its own
  /// default. A non-empty [providerSlug] pins the model to one provider; an
  /// empty one lets the host route.
  ///
  /// [debug] rides only when the developer's "capture model context" toggle is
  /// on. It asks the executor to echo back the raw context it sent to the model
  /// as a `debug_context` event; left false the frame carries no `debug` key, so
  /// an old host and a normal send both behave exactly as before.
  ///
  /// [regenerate] says this task REPLACES the last answer instead of asking a
  /// new question — the Retry button. The host then drops the turn being
  /// retried before it stores this prompt, so the conversation holds the
  /// question once and the newest answer rather than one copy per attempt.
  ///
  /// [taskId] names THIS SEND. Every distinct send mints a fresh one — each
  /// tool-loop pass, each regenerate, each continue — because the host dedupes
  /// strictly: a second frame carrying an id it has already taken is answered
  /// `duplicate` and is NOT run, so two passes sharing an id would leave the
  /// second one silently undone, which is the very failure this exists to fix.
  /// The id is reused for ONE reason only: re-sending a send that was never
  /// acknowledged. That is what makes a blind re-send after a reconnect safe.
  ///
  /// The host answers every task that carries one with a `task_ack`
  /// ([AgentsRelayTaskAck]), so "no ack" means "the frame never arrived" and
  /// nothing else. Left off the frame when null, so a host too old to know the
  /// key behaves exactly as before.
  Future<void> sendTask(
    String prompt, {
    String sessionKey,
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    bool debug,
    bool regenerate,
    String? taskId,
  });

  /// Creates the room on the host so a later [sendRoomTask] can find it (§16.1).
  /// [members] is `[{agent_id, handle}]` in room order.
  ///
  /// [agentToAgent] is the room's "coworkers may reply to each other" policy.
  /// True is what a room has always done, so the key rides ONLY when it is
  /// false: an old host that does not know the key keeps behaving exactly as
  /// before.
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members, {
    bool agentToAgent,
  });

  /// Flips [roomId]'s `agent_to_agent` policy on the host (§16.1).
  Future<void> setRoomAgentToAgent(String roomId, bool enabled);

  /// Seals and sends a group-room task (§16.1): the host looks [roomId]'s
  /// members up and drives them, streaming `room_turn` / `room_done` back.
  Future<void> sendRoomTask(String roomId, String message);

  /// Tells the host to forget [roomId] — drop it and its transcript (§16.1).
  Future<void> deleteRoom(String roomId);

  /// Renames [roomId] on the host (§16.1).
  Future<void> renameRoom(String roomId, String name);

  /// Registers a coworker the app created on the host's roster, so its name
  /// outlives this install (bead cowork-817; `agent_create`, WIRE_CONTRACT
  /// "Coworker names").
  Future<void> createAgent(String agentId, String name);

  /// Renames a coworker on the host's roster (bead cowork-817; `agent_rename`).
  Future<void> renameAgent(String agentId, String name);

  /// Asks the host for every coworker name it keeps (`agent_list` request;
  /// the answer arrives on [inbound] as [AgentsRelayAgentList]).
  Future<void> requestAgentList();

  /// Adds a member to [roomId] on the host (§16.1).
  Future<void> addRoomMember(String roomId, String agentId, String handle);

  /// Removes a member from [roomId] on the host (§16.1).
  Future<void> removeRoomMember(String roomId, String agentId);

  /// Asks the host to replay [roomId]'s stored transcript; the host answers with
  /// a `room_history` event (§16.1).
  Future<void> requestRoomHistory(String roomId);

  /// Asks the executor to abort the run in [sessionKey] — the controller side of
  /// the two-tier kill switch (§7.1).
  ///
  /// The stop **names its target**, and the thread key is the name the app has:
  /// it chose it when it sent the task, and it knows it before the first event of
  /// the run comes back. A stop that named nothing would have to mean "abort
  /// whatever is running", which loses an invisible race — the run the user meant
  /// can finish while the frame is in flight, and the next task in that thread
  /// would be the one that died.
  ///
  /// The UI must not treat this as "stopped": it is a request. The run is only
  /// over when a `done` or `error` event arrives.
  Future<void> requestStop({String sessionKey});

  /// Ask the executor to re-stream [sessionKey]'s whole stored transcript (the
  /// server is the truth). Use it when the client has no local transcript for the
  /// thread — a fresh install, or a reconnect after the app was cleared.
  ///
  /// The events come back marked as replay: `user` / `delta` / `tool` in stored
  /// order, then a `done` with reason `replay`. The UI renders them as history —
  /// it must NOT show a running spinner or a Stop phase, and must not add a
  /// "done" card for the closing `done`. An unknown thread replays as an empty
  /// stream (just the `done`), so it is always safe to ask.
  ///
  /// The stream opens with a `run_state` ([AgentsRelayRunState]) saying whether
  /// a run for the thread is in flight on the host right now.
  ///
  /// [afterId] is the replay cursor: the highest `mid` the app has already
  /// stored for this thread. Only messages with `mid > afterId` come back. The
  /// default `0` replays the whole history (a fresh install). The frame carries
  /// `after_id` only when it is greater than zero, so a full replay looks
  /// exactly as it did before to an old host.
  ///
  /// Sent automatically on (re)connect for the session keys a replay-sessions
  /// provider reports (see [AgentsRelayClient]'s constructor); call this directly
  /// for an on-demand re-hydrate.
  Future<void> requestReplay({
    String sessionKey,
    int afterId,
    int beforeId,
    int limit,
  });

  /// Tell the host the app rendered the live `done` of [runId] (§ run
  /// detachment). The host marks the run seen, so a later replay does not flag
  /// it `while_away` and it can skip a push notification.
  ///
  /// Best-effort: a lost ack only costs a redundant "Answer ready" badge, so the
  /// caller may ignore a failure.
  Future<void> sendRunAck(String runId);

  /// Ask the executor to start streaming the sandbox browser's screen over the
  /// sealed channel (§9.1), so the user can watch and take control (e.g. to log
  /// in). Status comes back as [AgentsRelayBrowserView]; pixels as
  /// [AgentsRelayBrowserData].
  /// Opens the screen view. [sessionKey] names the thread whose box to look
  /// in: with one container per coworker, a start without it makes the
  /// executor guess, and it guesses the primary environment — almost never
  /// the box the browser is in (bead cowork-5eo6).
  Future<void> startBrowserView({String? sessionKey});

  /// Ask the executor to stop the live browser view and tear the stream down.
  Future<void> stopBrowserView();

  /// Forward raw RFB client bytes (the viewer's handshake and every pointer/key
  /// event) to the sandbox browser (§9.1).
  Future<void> sendBrowserData(Uint8List bytes);

  /// Answer a [AgentsRelayApprovalRequest]: approve or deny one here.now
  /// publish, correlated by [approvalId]. The run is blocked until this arrives;
  /// a denial (or no answer within the executor's timeout) does not publish.
  Future<void> sendApprovalDecision({
    required String approvalId,
    required bool approved,
  });

  /// Hand the host the user's WHOLE secret set (docs/WIRE_CONTRACT.md,
  /// "Secrets"): after a provision, after every change, and as the answer to
  /// a [AgentsRelaySecretRequest] (then with its [requestId]). The host
  /// replaces what it holds; a name missing here is gone on the host too.
  Future<void> sendSecrets({
    required Map<String, String> values,
    required int revision,
    String? requestId,
  });

  /// Tears the client down.
  Future<void> dispose();
}

/// The real transport. Also an [ExecutorTransport]: [provisionAccount] shapes
/// the payload through [ExecutorProvisioning], which calls back into
/// [sendAuthentication] to seal and send it over this WebSocket.
class AgentsRelayDocuments extends AgentsRelayInbound {
  const AgentsRelayDocuments(this.payload);
  final Map<String, dynamic> payload;
}

abstract interface class AgentsDocumentsControl {
  Future<void> requestDocuments(String sessionKey, {String? id});
}

/// Asks the host what a coworker runs on and what it has spent
/// (docs/WIRE_CONTRACT.md, "Agent status"). Answered with one
/// [AgentsRelayAgentStatus] on `inbound`.
abstract interface class AgentsAgentStatusControl {
  Future<void> requestAgentStatus(String sessionKey);

  /// The host's answers, and the push it sends when a run of that coworker
  /// ends. Its own stream, not `inbound`: [AgentsRelayInbound] is sealed and
  /// every exhaustive switch over it would have to grow a case for a frame
  /// that only the control panel reads.
  Stream<AgentsRelayAgentStatus> get agentStatus;
}

class AgentsRelayClient
    implements
        AgentsRelayController,
        ExecutorTransport,
        AgentsAutomationControl,
        AgentsDocumentsControl,
        AgentsAgentStatusControl,
        AgentsSkillsControl,
        McpProbeControl {
  AgentsRelayClient({
    required String deviceId,
    required SimpleKeyPair signingKeyPair,
    RelaySocketConnector connector = defaultRelaySocketConnector,
    AgentsApprovedDevices? approvedDevices,
    int keyVersion = 1,
    int Function()? nowMs,
    Duration pairingTimeout = const Duration(seconds: 30),
    McpStore? mcpStore,
    HereNowStore? hereNowStore,
    Future<void> Function()? secretsForwarder,
    this.onTrustUpdated,
    Iterable<String> Function()? replaySessions,
    AccountSessionSource? sessionSource,
    Stream<AuthState>? authChanges,
    Future<AccountSession?> Function(String refreshToken)? sessionAdopter,
    SessionRefreshScheduler? scheduler,
    AgentsHostSessionMinter? hostSessionMinter,
  }) : _deviceId = deviceId,
       _signingKeyPair = signingKeyPair,
       _connector = connector,
       _approvedDevices = approvedDevices ?? AgentsApprovedDevices.empty(),
       _keyVersion = keyVersion,
       _nowMs = nowMs,
       _pairingTimeout = pairingTimeout,
       _mcpStore = mcpStore,
       _hereNowStore = hereNowStore,
       _secretsForwarder = secretsForwarder,
       _replaySessions = replaySessions,
       _sessionSource = sessionSource,
       _authChanges = authChanges,
       _sessionAdopter = sessionAdopter,
       _hostSessionMinter = hostSessionMinter,
       _scheduler = scheduler ?? SessionRefreshScheduler.instance;

  final String _deviceId;
  final Future<void> Function(AgentsStoredPairing trust)? onTrustUpdated;
  final SimpleKeyPair _signingKeyPair;
  final RelaySocketConnector _connector;
  final AgentsApprovedDevices _approvedDevices;

  /// The user's UI-configured MCP servers. When set, each task frame carries the
  /// non-empty forward payloads (`[{id, name, url, auth, access_token?, oauth?}]`)
  /// so the executor can stand up an authenticated per-session `MCPManager`
  /// (WS-D). Null (or an empty store) leaves `mcp_servers` off the frame, which
  /// keeps an old host happy and costs nothing when the user configured no
  /// connectors.
  final McpStore? _mcpStore;

  /// Where an `mcp_credentials` frame is applied. Swappable in tests so the
  /// frame can be asserted without the app-wide connector store.
  ///
  /// The frame is the return half of the forward payload: the host renews the
  /// OAuth tokens while the app is closed, and a provider that rotates refresh
  /// tokens kills the device's copy in the act. It is state, not something to
  /// render, so it never reaches the inbound stream.
  @visibleForTesting
  static Future<int> Function(Map<String, dynamic> payload) mcpCredentialsSink =
      McpService.applyRotatedCredentials;

  /// Where an `mcp_tools` frame is applied. Same seam as the credentials sink,
  /// for the same reason: the app cannot discover an MCP server's tools itself,
  /// the host reports them, and a test must be able to assert the frame without
  /// the app-wide store.
  static Future<int> Function(Map<String, dynamic> payload) mcpToolsSink =
      McpService.applyToolsFrame;

  /// The user's here.now publishing setting. When the connector is enabled, each
  /// task frame carries `{enabled, approval}` under `herenow`, so the executor
  /// registers the publish tool and applies the approval policy. Null (or a
  /// disabled store) leaves the key off the frame, so an old host and a user who
  /// never enabled it both keep working, and no publish tool is registered.
  final HereNowStore? _hereNowStore;

  /// Forwards the user's secret set after every provision
  /// (docs/WIRE_CONTRACT.md, "Secrets"): a host that restarted holds what the
  /// device holds. Null (tests, a bare client) forwards nothing; the app
  /// passes `SecretsService.instance.forwardToHost`.
  final Future<void> Function()? _secretsForwarder;

  /// Supplies the session keys whose transcript must be replayed after a
  /// (re)connect — the threads the caller has no local transcript for. Called
  /// once the channel is paired; the client sends one `replay` per key, at most
  /// once per connection. Null (the default) means the caller drives replay
  /// itself via [requestReplay] and nothing is sent automatically, so an old
  /// caller behaves exactly as before.
  final Iterable<String> Function()? _replaySessions;

  /// Session keys already auto-replayed on the current socket, so a provider that
  /// still lists a thread does not replay it twice. Cleared on each new connect
  /// or reconnect, because a fresh socket is a fresh transcript budget.
  final Set<String> _autoReplayed = <String>{};

  /// Completes once this connection has provisioned the account, or once
  /// [_provisionGateTimeout] has passed without one.
  ///
  /// A replay is the first thing a reattaching view asks for, and it used to
  /// arrive before the account token did — the host logs "expected
  /// account_authentication, got 'replay'" and answers a replay it cannot yet
  /// attribute. Holding the replay for the provision costs nothing (it is the
  /// same round trip either way) and puts the two frames in the order the host
  /// documents. The timeout is the escape hatch: a caller that never provisions
  /// (a test, an unauthenticated flow) still gets its transcript.
  Completer<void>? _provisionGate;

  /// How long a replay waits for the account provision before going anyway.
  static const Duration _provisionGateTimeout = Duration(seconds: 10);
  final int _keyVersion;
  final int Function()? _nowMs;
  final Duration _pairingTimeout;

  /// Token freshness (docs/WIRE_CONTRACT.md, bead cowork-c91). The host must
  /// never run a task on a stale account token, so this client keeps it fresh
  /// on its own, whatever view is mounted:
  ///
  ///  * every Supabase token refresh re-sends `account_authentication` at once
  ///    (also while a task runs — it is a control frame, the host swaps the
  ///    tokens in place);
  ///  * a host `reprovision_request` is answered with a fresh session;
  ///  * a host `account_session_rotated` is adopted and acked.
  ///
  /// [sessionSource] reads/refreshes the account session; null falls back to
  /// the live Supabase session when Supabase is initialised. [authChanges] is
  /// the auth event stream; null falls back to Supabase's. Both are injectable
  /// so a test drives them with no Supabase.
  final AccountSessionSource? _sessionSource;
  final Stream<AuthState>? _authChanges;
  StreamSubscription<AuthState>? _authSub;

  /// Adopts a refresh token the host rotated while no app was attached
  /// (`account_session_rotated`): exchanges it for a live session and makes it
  /// the app's own. Null falls back to Supabase `setSession`. Injectable so a
  /// test can assert the adoption with no Supabase.
  final Future<AccountSession?> Function(String refreshToken)? _sessionAdopter;

  /// [accessToken] is the rotated pair's access token. Handed it, gotrue
  /// restores the pair through `/user`: nothing is spent, and a pair the server
  /// rejects does not cost the app its own session. Without it — or once it has
  /// expired — gotrue falls back to `/token`, and there is the trap
  /// (bead cowork-2n1): gotrue-dart 2.27.1 clears the stored session and fires
  /// `signedOut(sessionExpired)` on ANY non-retryable `/token` failure, even
  /// when the app's own access token is still perfectly good. Adopting the
  /// host's rotated pair could therefore sign the user out of an app that was
  /// working — which is exactly what happened.
  Future<AccountSession?> Function(String)? _effectiveSessionAdopter({
    String? accessToken,
  }) {
    final adopter = _sessionAdopter;
    if (adopter != null) return adopter;
    if (!SupabaseService.isInitialized) return null;
    return (String refreshToken) async {
      final response = await SupabaseService.auth.setSession(
        refreshToken,
        accessToken: (accessToken == null || accessToken.isEmpty)
            ? null
            : accessToken,
      );
      final session = response.session;
      return session == null ? null : AccountSession.fromSupabase(session);
    };
  }

  /// The access token the host was last given, so an unchanged token is not
  /// re-sent and an older one never overwrites a newer one.
  String? _provisionedAccessToken;

  /// Mints a session of the host's own (`POST /v2/agents/host-session`) when
  /// the host asks with `host_session_request`. Null falls back to the real
  /// API when Supabase is initialised. Injectable so a test needs no network.
  final AgentsHostSessionMinter? _hostSessionMinter;

  /// The mint in flight, so two requests in a row cost one API call.
  Future<void>? _hostSessionInFlight;

  /// When a host session was last handed over. The host asks at most every
  /// 30 s; this keeps a burst of asks (a reconnect storm) from minting more.
  DateTime? _hostSessionSentAt;

  /// The shortest gap between two mints for this client.
  static const Duration _hostSessionMinInterval = Duration(seconds: 20);

  /// The app's token-refresh scheduler (bead cowork-2n1). This client tells it
  /// whether the host is attached and lends it [_reattachForScheduler], so a
  /// refresh while the host is away first lets the relay reattach and adopt a
  /// pair the host rotated, instead of spending a token that may be dead.
  final SessionRefreshScheduler _scheduler;

  late final Future<void> Function() _reattachForScheduler = _reattach;

  /// Reconnects with the stored trust (no code) and re-provisions the current
  /// session. No-op while paired, disposed, or never paired.
  Future<void> _reattach() async {
    if (_disposed || _state.value.isPaired) return;
    // A dial already in progress (connecting / pairing): do not race it.
    if (_socket != null) return;
    final trust = _establishedTrust;
    if (trust == null) return;
    await reconnect(hostUrl: trust.hostUrl, pairing: trust);
    final session = _effectiveSessionSource?.current();
    if (session != null && !_disposed) await provisionAccount(session);
  }

  void _publishAttachment(AgentsRelayPhase phase) {
    switch (phase) {
      case AgentsRelayPhase.paired:
        _scheduler.hostAttached = true;
        _scheduler.reconnectHost = _reattachForScheduler;
      case AgentsRelayPhase.closed:
      case AgentsRelayPhase.error:
        // Only a lost host counts as "away"; a first pairing that never
        // succeeded is no pairing at all.
        if (_establishedTrust != null) _scheduler.hostAttached = false;
      case AgentsRelayPhase.idle:
      case AgentsRelayPhase.connecting:
      case AgentsRelayPhase.pairing:
        break;
    }
  }

  AccountSessionSource? get _effectiveSessionSource {
    final source = _sessionSource;
    if (source != null) return source;
    return SupabaseService.isInitialized
        ? const SupabaseAccountSession()
        : null;
  }

  Stream<AuthState>? get _effectiveAuthChanges {
    final stream = _authChanges;
    if (stream != null) return stream;
    return SupabaseService.isInitialized
        ? SupabaseService.auth.onAuthStateChange
        : null;
  }

  final ValueNotifier<AgentsRelayState> _state =
      ValueNotifier<AgentsRelayState>(
        const AgentsRelayState(phase: AgentsRelayPhase.idle),
      );
  final StreamController<AgentsRelayInbound> _inbound =
      StreamController<AgentsRelayInbound>.broadcast();

  RelaySocket? _socket;
  StreamSubscription<dynamic>? _sub;
  AgentsPairing? _pairing;
  AgentsReconnect? _reconnect;
  AgentsControllerSession? _controllerSession;
  AgentsStoredPairing? _establishedTrust;

  /// The authenticated host device, set by BOTH the first pairing and a code-free
  /// reconnect. Reading it off `_pairing` alone was a bug: after a reconnect
  /// there is no pairing session, so provisioning threw "Cannot provision before
  /// pairing completes" and every auto-reconnect died before serving a task.
  String? _peerDeviceId;
  Completer<void>? _pairingDone;

  /// Serialises inbound pairing steps so awaited transitions never overlap.
  Future<void> _pairingQueue = Future<void>.value();
  AgentsFrameSealer? _sealer;
  AgentsFrameOpener? _opener;
  bool _disposed = false;

  @override
  ValueListenable<AgentsRelayState> get state => _state;

  @override
  Stream<AgentsRelayInbound> get inbound => _inbound.stream;

  final StreamController<AgentsRelayAgentStatus> _agentStatus =
      StreamController<AgentsRelayAgentStatus>.broadcast();

  @override
  Stream<AgentsRelayAgentStatus> get agentStatus => _agentStatus.stream;

  @override
  AgentsStoredPairing? get establishedTrust => _establishedTrust;

  /// The channel id is everything before the last '-' in the pairing code.
  static String channelIdOf(String pairingCode) {
    final dash = pairingCode.lastIndexOf('-');
    if (dash <= 0 || dash >= pairingCode.length - 1) {
      throw const FormatException('Malformed pairing code');
    }
    return pairingCode.substring(0, dash);
  }

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {
    if (_disposed) throw StateError('AgentsRelayClient is disposed');
    if (_socket != null) throw StateError('Already connected');

    final String channelId;
    _controllerSession = null;
    _reconnect = null;
    try {
      channelId = channelIdOf(pairingCode);
    } on FormatException catch (e) {
      _fail('Invalid pairing code');
      throw StateError(e.message);
    }

    _set(const AgentsRelayState(phase: AgentsRelayPhase.connecting));

    final RelaySocket socket;
    try {
      socket = await _connector(hostUrl);
    } catch (e) {
      _fail('Could not reach host: $e');
      rethrow;
    }
    _socket = socket;
    // A fresh socket is a fresh transcript budget: let auto-replay fire again.
    _autoReplayed.clear();
    _provisionGate = Completer<void>();
    if (kDebugMode) {
      debugPrint('[agents-relay] socket connected to $hostUrl');
    }

    // 1. Build the joiner BEFORE listening, so the first inbound envelope
    //    (the host's commit) can never race an unset pairing session.
    _pairing = await AgentsPairing.joiner(
      deviceId: _deviceId,
      deviceKeyPair: _signingKeyPair,
      pairingCode: pairingCode,
      approvedDevices: _approvedDevices,
      nowMs: _nowMs,
    );

    final done = Completer<void>();
    _pairingDone = done;
    _sub = socket.incoming.listen(
      _onData,
      onError: (Object e, StackTrace _) => _failPairing(e),
      onDone: _onSocketDone,
      cancelOnError: false,
    );

    // 2. Join the channel as the controller. The host initiator drives the
    //    ceremony from here; _handlePairing reacts to each envelope it sends.
    socket.send(
      jsonEncode(<String, dynamic>{
        'type': 'join',
        'channel': channelId,
        'role': 'controller',
      }),
    );
    _set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.pairing,
        detail: 'Pairing with host…',
      ),
    );

    try {
      await done.future.timeout(_pairingTimeout);
    } catch (e) {
      _fail(_pairingErrorText(e));
      await _closeSocket();
      rethrow;
    }

    // 3. Paired: repoint the frame codec at the fresh channel key (§14).
    final pairing = _pairing!;
    final channelKey = pairing.channelKey;
    _sealer = AgentsFrameSealer.withChannelKey(
      channelKey: channelKey,
      keyVersion: _keyVersion,
      deviceId: _deviceId,
      signingKeyPair: _signingKeyPair,
    );
    _opener = AgentsFrameOpener.withChannelKey(
      channelKey: channelKey,
      keyVersion: _keyVersion,
      approvedDevices: pairing.approvedDevices,
    );
    // Capture the trust the caller persists so the next launch reconnects with
    // no code: the host's device key + the established channel key.
    final peerDeviceId = pairing.peerDeviceId;
    _peerDeviceId = peerDeviceId;
    final peerPublicKey = peerDeviceId == null
        ? null
        : pairing.approvedDevices.lookup(peerDeviceId);
    if (peerDeviceId != null && peerPublicKey != null) {
      _establishedTrust = AgentsStoredPairing(
        hostUrl: hostUrl,
        channelId: channelId,
        channelKey: channelKey,
        peerDeviceId: peerDeviceId,
        peerPublicKey: peerPublicKey,
      );
    }
    if (hostUrl.path == '/v2/relay/ws' && _establishedTrust != null) {
      final controller = AgentsControllerSession(
        _deviceId,
        _signingKeyPair,
        _establishedTrust!,
      );
      _controllerSession = controller;
      final resumed = Completer<void>();
      _pairingDone = resumed;
      socket.send(jsonEncode(await controller.resume()));
      try {
        await resumed.future.timeout(_pairingTimeout);
      } catch (error) {
        _fail(_pairingErrorText(error));
        await _closeSocket();
        rethrow;
      }
      _sealer = AgentsFrameSealer.withChannelKey(
        channelKey: controller.trafficKey!,
        keyVersion: _keyVersion,
        deviceId: _deviceId,
        signingKeyPair: _signingKeyPair,
      );
      _opener = AgentsFrameOpener.withChannelKey(
        channelKey: controller.trafficKey!,
        keyVersion: _keyVersion,
        approvedDevices: pairing.approvedDevices,
      );
    }
    _set(
      AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        sas: pairing.sas,
        peerDeviceId: pairing.peerDeviceId,
        detail: 'Paired',
      ),
    );
    // Now paired: re-hydrate any thread the caller has no local transcript for.
    _maybeAutoReplay();
  }

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required AgentsStoredPairing pairing,
  }) async {
    if (_disposed) throw StateError('AgentsRelayClient is disposed');
    if (_socket != null) throw StateError('Already connected');

    _set(const AgentsRelayState(phase: AgentsRelayPhase.connecting));

    final RelaySocket socket;
    try {
      socket = await _connector(await _reconnectDialUrl(hostUrl, pairing));
    } catch (e) {
      _fail('Could not reach host: $e');
      rethrow;
    }
    _socket = socket;
    // A fresh socket is a fresh transcript budget: let auto-replay fire again.
    _autoReplayed.clear();
    _provisionGate = Completer<void>();
    if (kDebugMode) {
      debugPrint('[agents-relay] reconnecting to $hostUrl (no code)');
    }

    // Build the reconnect joiner BEFORE listening so the host's reconnect-hello
    // can never race an unset session.
    _controllerSession = hostUrl.path == '/v2/relay/ws'
        ? AgentsControllerSession(_deviceId, _signingKeyPair, pairing)
        : null;
    _reconnect = _controllerSession != null
        ? null
        : AgentsReconnect.joiner(
            deviceId: _deviceId,
            deviceKeyPair: _signingKeyPair,
            peerDeviceId: pairing.peerDeviceId,
            peerPublicKey: pairing.peerPublicKey,
            channelId: pairing.channelId,
          );

    final done = Completer<void>();
    _pairingDone = done;
    _sub = socket.incoming.listen(
      _onData,
      onError: (Object e, StackTrace _) => _failPairing(e),
      onDone: _onSocketDone,
      cancelOnError: false,
    );

    final controllerSession = _controllerSession;
    if (controllerSession != null) {
      socket.send(jsonEncode(await controllerSession.resume()));
    } else {
      socket.send(
        jsonEncode(<String, dynamic>{
          'type': 'join',
          'channel': pairing.channelId,
          'role': 'controller',
        }),
      );
    }
    _set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.pairing,
        detail: 'Reconnecting…',
      ),
    );

    try {
      await done.future.timeout(_pairingTimeout);
    } catch (e) {
      _fail(_pairingErrorText(e));
      await _closeSocket();
      rethrow;
    }

    // Every cloud controller has a fresh traffic key and independent replay
    // guard. The encrypted account pairing is only a recovery capability.
    final trafficKey = _controllerSession?.trafficKey ?? pairing.channelKey;
    final approved = AgentsApprovedDevices.empty()
      ..approve(pairing.peerDeviceId, pairing.peerPublicKey);
    _sealer = AgentsFrameSealer.withChannelKey(
      channelKey: trafficKey,
      keyVersion: _keyVersion,
      deviceId: _deviceId,
      signingKeyPair: _signingKeyPair,
    );
    _opener = AgentsFrameOpener.withChannelKey(
      channelKey: trafficKey,
      keyVersion: _keyVersion,
      approvedDevices: approved,
    );
    _establishedTrust = pairing;
    _peerDeviceId = pairing.peerDeviceId;
    _set(
      AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: pairing.peerDeviceId,
        detail: 'Reconnected',
      ),
    );
    // Now reconnected: re-hydrate any thread with no local transcript.
    _maybeAutoReplay();
  }

  @override
  Future<void> provisionAccount(AccountSession session) {
    // Works after a first pairing AND after a code-free reconnect.
    final peerDeviceId = _peerDeviceId;
    if (peerDeviceId == null || !_state.value.isPaired) {
      throw StateError('Cannot provision before pairing completes');
    }
    // Route the token through ExecutorProvisioning, which shapes the payload
    // and calls back into sendAuthentication over this sealed transport.
    _provisionedAccessToken = session.accessToken;
    // From the first provision on, keep the host's token fresh on our own.
    _startAuthWatch();
    final sent = ExecutorProvisioning(
      this,
    ).provision(ExecutorHandle(deviceId: peerDeviceId, label: 'host'), session);
    // Let a waiting replay through either way: a provision that failed is not
    // a reason to leave the user without a transcript.
    // The caller receives `sent`'s error. Consume it on this separate cleanup
    // future too, so a socket closing during login cannot report it unhandled.
    unawaited(sent.whenComplete(_openProvisionGate).catchError((Object _) {}));
    // The secret set rides right behind the token, every time: the host
    // replaces its copy with ours. Best-effort; a failure is retried by the
    // next provision or the next change on the settings page.
    final forward = _secretsForwarder;
    if (forward != null) {
      unawaited(sent.then((_) => forward()).catchError((Object _) {}));
    }
    return sent;
  }

  // --- token freshness (docs/WIRE_CONTRACT.md, cowork-c91) --------------------

  void _startAuthWatch() {
    if (_authSub != null || _disposed) return;
    final stream = _effectiveAuthChanges;
    if (stream == null) return;
    _authSub = stream.listen(_onAuthChange, onError: (Object _) {});
  }

  void _onAuthChange(AuthState state) {
    final event = state.event;
    if (event != AuthChangeEvent.tokenRefreshed &&
        event != AuthChangeEvent.signedIn) {
      return;
    }
    final session = state.session;
    if (session == null || session.accessToken.isEmpty) return;
    unawaited(_reprovision(AccountSession.fromSupabase(session)));
  }

  /// Send [session] to the host unless it is the token the host already holds.
  /// Best-effort: a send that fails (socket gone) is retried by the next
  /// refresh, the next request, or the next reconnect's provision.
  Future<void> _reprovision(AccountSession session) async {
    if (_disposed || !_state.value.isPaired) return;
    if (session.accessToken == _provisionedAccessToken) return;
    try {
      await provisionAccount(session);
    } catch (_) {
      // Nothing to surface: the host asks again, or the next refresh lands.
    }
  }

  /// The host cannot use its token (expired, or its own refresh failed) and
  /// asks for a fresh one. Refresh first when the token is known to be expired.
  Future<void> _answerReprovisionRequest(Map<String, dynamic> payload) async {
    final source = _effectiveSessionSource;
    if (source == null) return;
    final reason = '${payload['reason'] ?? ''}';
    AccountSession? session;
    if (reason == 'token_expired' || reason == 'refresh_failed') {
      try {
        session = await source.refresh();
      } catch (_) {
        session = null;
      }
    }
    session ??= source.current();
    if (session == null) return;
    // A request is an explicit ask: answer even with the same token, so the
    // host gets a definite frame instead of silence.
    _provisionedAccessToken = null;
    await _reprovision(session);
  }

  /// The host refreshed on its own while no app was attached. Supabase rotates
  /// the refresh token on every refresh, so the app's stored copy is dead: adopt
  /// the host's pair, then ack with an `account_authentication`. Idempotent —
  /// when the app already holds a newer session it keeps its own and still acks,
  /// so the host stops re-sending.
  Future<void> _adoptRotatedSession(Map<String, dynamic> payload) async {
    final refresh = payload['refresh_token'];
    if (refresh is! String || refresh.isEmpty) return;
    final access = payload['access_token'];
    final rotatedExpiresAt = AgentsRelayTool._asInt(payload['expires_at']);
    final current = _effectiveSessionSource?.current();
    AccountSession? adopted;
    final appIsNewer =
        current != null &&
        current.expiresAt != null &&
        rotatedExpiresAt != null &&
        current.expiresAt! > rotatedExpiresAt &&
        current.refreshToken != refresh;
    if (appIsNewer) {
      adopted = current;
    } else {
      final adopter = _effectiveSessionAdopter(
        accessToken: access is String ? access : null,
      );
      if (adopter != null) {
        try {
          adopted = await adopter(refresh);
        } catch (_) {
          adopted = null;
        }
      }
      // No adopter, or the exchange failed: the host's pair is still the only
      // live one, so ack with it as-is rather than leave the host waiting.
      adopted ??= AccountSession(
        accessToken: access is String ? access : (current?.accessToken ?? ''),
        refreshToken: refresh,
        userId: current?.userId ?? '',
        expiresAt: rotatedExpiresAt,
      );
    }
    // No token, or no idea whose token it is (no current session and no
    // adopter): stay silent rather than ack with an empty `user_id`, which the
    // host would read as a change of user (docs/WIRE_CONTRACT.md,
    // "account_session_rotated"; review F5).
    if (adopted.accessToken.isEmpty || adopted.userId.isEmpty) return;
    _provisionedAccessToken = null; // the ack must go out even if unchanged
    await _reprovision(adopted);
  }

  /// The host asked for an account session of its own
  /// (`host_session_request`). Mint one through the API with this app's own
  /// session and hand it over. Best-effort: on failure the host keeps what it
  /// has and asks again later, so there is nothing to show the user.
  Future<void> _answerHostSessionRequest() {
    final inFlight = _hostSessionInFlight;
    if (inFlight != null) return inFlight;
    final sentAt = _hostSessionSentAt;
    if (sentAt != null &&
        DateTime.now().difference(sentAt) < _hostSessionMinInterval) {
      return Future<void>.value();
    }
    final future = _mintAndSendHostSession().whenComplete(() {
      _hostSessionInFlight = null;
    });
    _hostSessionInFlight = future;
    return future;
  }

  Future<void> _mintAndSendHostSession() async {
    if (_disposed || !_state.value.isPaired) return;
    final peerDeviceId = _peerDeviceId;
    final source = _effectiveSessionSource;
    final minter = _effectiveHostSessionMinter;
    if (peerDeviceId == null || source == null || minter == null) return;
    AccountSession? session;
    try {
      // Refreshes only when the access token is about to lapse.
      session = await source.refresh();
    } catch (_) {
      session = null;
    }
    session ??= source.current();
    if (session == null || session.accessToken.isEmpty) return;
    AgentsHostSession? grant;
    try {
      grant = await minter(session);
    } catch (_) {
      grant = null;
    }
    if (grant == null || _disposed || !_state.value.isPaired) {
      if (kDebugMode) debugPrint('[agents-relay] host session not minted');
      return;
    }
    try {
      await ExecutorProvisioning(this).provisionHostSession(
        ExecutorHandle(deviceId: peerDeviceId, label: 'host'),
        grant,
      );
      _hostSessionSentAt = DateTime.now();
      if (kDebugMode) debugPrint('[agents-relay] host session handed over');
    } catch (_) {
      // The socket went away; the host asks again on the next connect.
    }
  }

  AgentsHostSessionMinter? get _effectiveHostSessionMinter {
    final minter = _hostSessionMinter;
    if (minter != null) return minter;
    return SupabaseService.isInitialized ? mintAgentsHostSession : null;
  }

  /// The URL a reconnect dials. For the cloud relay it carries the heal
  /// channel of this pairing, so the socket can claim a host that is parked
  /// because its account session died (agents_heal_channel.dart). The marker
  /// is stripped before the socket opens; the relay never sees it in a URL.
  static Future<Uri> _reconnectDialUrl(
    Uri hostUrl,
    AgentsStoredPairing pairing,
  ) async {
    final address = AgentsCloudRelayAddress.tryParse(hostUrl);
    if (address == null ||
        address.pairingChannel != null ||
        address.targetDeviceId == null) {
      return hostUrl;
    }
    try {
      final heal = await deriveAgentsHealChannel(
        pairing.channelKey,
        pairing.channelId,
      );
      return AgentsCloudRelayAddress(
        base: address.base,
        targetDeviceId: address.targetDeviceId,
        healChannel: heal,
      ).toUri();
    } catch (_) {
      return hostUrl;
    }
  }

  @override
  Future<void> sendAuthentication(
    ExecutorHandle target,
    Map<String, dynamic> payload,
  ) => _sendFramePayload(payload);

  @override
  Future<void> sendTask(
    String prompt, {
    String sessionKey = 'default',
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    bool debug = false,
    bool regenerate = false,
    String? taskId,
  }) async {
    // Auth first, then the work — the same gate as a replay and an agent list,
    // and for a worse reason. Right after a reconnect this frame could overtake
    // its own `account_authentication`, and a host that is not provisioned for
    // the current controller session used to drop a `task` on the floor: no
    // run, no log, no error frame. The prompt was simply gone.
    await _awaitProvisionGate();
    if (_disposed) return;
    // The user's UI-configured MCP servers, resolved with their live bearers at
    // launch. Empty (or no store) leaves the key off the frame, so an old host
    // and a user with no connectors both keep working unchanged.
    final mcpServers = _mcpStore == null
        ? const <Map<String, dynamic>>[]
        : await _mcpStore.forwardPayloads();
    // The here.now connector setting, when the user enabled it. Null leaves the
    // `herenow` key off the frame, so the executor registers no publish tool.
    final herenow = _hereNowStore == null
        ? null
        : await _hereNowStore.forwardPayload();
    await _sendFramePayload(<String, dynamic>{
      'type': 'task',
      'prompt': prompt,
      'session_key': sessionKey,
      // The app's id for this send. It rides only when the caller has one, so
      // an old host sees the frame it has always seen.
      if (taskId != null && taskId.isNotEmpty) 'task_id': taskId,
      // Each model field rides along only when the composer set it, so an
      // old host and an unconfigured send both keep the host's own default.
      if (modelId != null && modelId.isNotEmpty) 'model': modelId,
      if (providerSlug != null && providerSlug.isNotEmpty)
        'provider': providerSlug,
      if (reasoningEffort != null && reasoningEffort.isNotEmpty)
        'reasoning_effort': reasoningEffort,
      if (mcpServers.isNotEmpty) 'mcp_servers': mcpServers,
      // Null (disabled connector) drops the key via the null-aware element.
      'herenow': ?herenow,
      // Only a debug send carries the flag, so an old host and a normal send
      // both keep the frame exactly as it was.
      if (debug) 'debug': true,
      // Same rule: a retry says so, everything else leaves the key off.
      if (regenerate) 'regenerate': true,
    });
  }

  @override
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members, {
    bool agentToAgent = true,
  }) => _sendFramePayload(<String, dynamic>{
    'type': 'room_create',
    'room_id': roomId,
    'name': name,
    'members': members,
    // Only a room that turned the policy OFF says so, so an old host sees the
    // frame it has always seen.
    if (!agentToAgent) 'agent_to_agent': false,
  });

  @override
  Future<void> setRoomAgentToAgent(String roomId, bool enabled) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'room_set_agent_to_agent',
        'room_id': roomId,
        'enabled': enabled,
      });

  @override
  Future<void> sendRoomTask(String roomId, String message) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'room_task',
        'room_id': roomId,
        'message': message,
      });

  @override
  Future<void> deleteRoom(String roomId) => _sendFramePayload(<String, dynamic>{
    'type': 'room_delete',
    'room_id': roomId,
  });

  @override
  Future<void> renameRoom(String roomId, String name) => _sendFramePayload(
    <String, dynamic>{'type': 'room_rename', 'room_id': roomId, 'name': name},
  );

  @override
  Future<void> createAgent(String agentId, String name) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'agent_create',
        'agent_id': agentId,
        'name': name,
      });

  @override
  Future<void> renameAgent(String agentId, String name) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'agent_rename',
        'agent_id': agentId,
        'name': name,
      });

  @override
  Future<void> requestAgentList() async {
    // Auth first, then the names — the same gate as a replay: sent on pair,
    // this used to reach the host before the account token ("expected
    // account_authentication, got 'agent_list'") and was dropped, and nothing
    // asked again until the next pairing.
    await _awaitProvisionGate();
    if (_disposed) return;
    return _sendFramePayload(<String, dynamic>{'type': 'agent_list'});
  }

  @override
  Future<void> addRoomMember(String roomId, String agentId, String handle) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'room_add_member',
        'room_id': roomId,
        'agent_id': agentId,
        'handle': handle,
      });

  @override
  Future<void> removeRoomMember(String roomId, String agentId) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'room_remove_member',
        'room_id': roomId,
        'agent_id': agentId,
      });

  @override
  Future<void> requestRoomHistory(String roomId) => _sendFramePayload(
    <String, dynamic>{'type': 'room_history_request', 'room_id': roomId},
  );

  @override
  Future<void> requestStop({String sessionKey = 'default'}) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'stop',
        // The executor matches this against the session key of the run it is
        // working on. A bare `{"type":"stop"}` — what this used to send — named
        // no run at all, so nothing could act on it.
        'session_key': sessionKey,
      });

  /// Let any replay waiting on the account provision proceed. Idempotent.
  void _openProvisionGate() {
    final gate = _provisionGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// Waits for the account provision of this connection, or for
  /// [_provisionGateTimeout] — see [_provisionGate]. Returns at once when
  /// there is no gate or it is already open.
  Future<void> _awaitProvisionGate() async {
    final gate = _provisionGate;
    if (gate == null || gate.isCompleted) return;
    try {
      await gate.future.timeout(_provisionGateTimeout);
    } on TimeoutException {
      // Nobody provisioned. Send anyway; that is the old behaviour.
    }
  }

  @override
  Future<void> requestReplay({
    String sessionKey = 'default',
    int afterId = 0,
    int beforeId = 0,
    int limit = 0,
  }) async {
    // Auth first, then replay — see [_provisionGate].
    await _awaitProvisionGate();
    if (_disposed) return;
    // Replay paging (docs/WIRE_CONTRACT.md, Bead cowork-axx): a full replay
    // asks for the newest page only, so a long thread paints at once; the
    // loader then fetches the older pages with `beforeId`. A delta replay
    // (`afterId` > 0) is never paged. An old host ignores both keys.
    final int effectiveLimit = limit > 0
        ? limit
        : (afterId == 0 ? kReplayPageSize : 0);
    return _sendFramePayload(<String, dynamic>{
      'type': 'replay',
      'session_key': sessionKey,
      // A cursor of zero means "the whole history", which is what a frame
      // without the key already means to the executor. Sending it only when
      // it advances keeps a full replay byte-identical to the old frame.
      if (afterId > 0) 'after_id': afterId,
      if (beforeId > 0) 'before_id': beforeId,
      if (effectiveLimit > 0) 'limit': effectiveLimit,
    });
  }

  @override
  Future<void> sendRunAck(String runId) =>
      // A sealed control frame, sent the same way as a stop: no running phase,
      // nothing to await — the host just marks the run seen.
      _sendFramePayload(<String, dynamic>{'type': 'run_ack', 'run_id': runId});

  /// Send one `replay` per session key the provider reports, at most once per
  /// socket. Fire-and-forget: a failed replay must never break the just-paired
  /// channel, so each send swallows its error. A null provider is a no-op, so a
  /// caller that drives replay itself sees no automatic frames.
  void _maybeAutoReplay() {
    final provider = _replaySessions;
    if (provider == null) return;
    for (final key in provider()) {
      if (key.isEmpty || _autoReplayed.contains(key)) continue;
      _autoReplayed.add(key);
      unawaited(requestReplay(sessionKey: key).catchError((Object _) {}));
    }
  }

  @override
  Future<void> startBrowserView({String? sessionKey}) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'browser_start',
        if (sessionKey != null && sessionKey.isNotEmpty)
          'session_key': sessionKey,
      });

  @override
  Future<void> stopBrowserView() =>
      _sendFramePayload(<String, dynamic>{'type': 'browser_stop'});

  @override
  Future<void> sendBrowserData(Uint8List bytes) => _sendFramePayload(
    <String, dynamic>{'type': 'browser_data', 'data': base64.encode(bytes)},
  );

  @override
  Future<void> sendApprovalDecision({
    required String approvalId,
    required bool approved,
  }) =>
      // A sealed control frame, sent the same way as a stop: the executor
      // correlates it by `approval_id` and resolves the blocked publish.
      _sendFramePayload(<String, dynamic>{
        'type': 'approval_decision',
        'approval_id': approvalId,
        'approved': approved,
      });

  @override
  Future<void> sendAutomationControl({
    required String id,
    required String action,
  }) =>
      // A sealed control frame like a stop (docs/WIRE_CONTRACT.md,
      // "Automations"): no terminal, the host answers with the event.
      _sendFramePayload(<String, dynamic>{
        'type': 'automation_control',
        'id': id,
        'action': action,
      });

  @override
  Future<void> requestAutomationList({String? sessionKey}) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'automation_list',
        if (sessionKey != null && sessionKey.isNotEmpty)
          'session_key': sessionKey,
      });

  @override
  Future<void> sendSkillControl({
    required String name,
    required String action,
  }) =>
      // Answered with a fresh `skills_list` on the same request stream
      // (docs/WIRE_CONTRACT.md, "Skills").
      _sendFramePayload(<String, dynamic>{
        'type': 'skill_control',
        'name': name,
        'action': action,
      });

  @override
  Future<void> requestSkillsList() =>
      _sendFramePayload(<String, dynamic>{'type': 'skills_list'});

  @override
  Future<void> probeMcpServers(List<Map<String, dynamic>> servers) =>
      // Answered with one terminal `mcp_tools` frame, like a skills list
      // (docs/WIRE_CONTRACT.md, "mcp_probe").
      _sendFramePayload(<String, dynamic>{
        'type': 'mcp_probe',
        'mcp_servers': servers,
      });

  @override
  Future<void> requestAgentStatus(String sessionKey) =>
      // Answered with one terminal `agent_status` frame, like a skills list
      // (docs/WIRE_CONTRACT.md, "Agent status").
      _sendFramePayload(<String, dynamic>{
        'type': 'agent_status',
        'session_key': sessionKey,
      });

  @override
  Future<void> requestDocuments(String sessionKey, {String? id}) =>
      _sendFramePayload(<String, dynamic>{
        'type': id == null ? 'documents_list' : 'document_read',
        'session_key': sessionKey,
        'id': ?id,
      });

  @override
  Future<void> sendSecrets({
    required Map<String, String> values,
    required int revision,
    String? requestId,
  }) =>
      // The whole set, sealed like every other frame; the host replaces its
      // copy. Never logged: this is the one frame that carries the values.
      _sendFramePayload(<String, dynamic>{
        'type': 'secrets',
        'entries': <Map<String, String>>[
          for (final name in values.keys.toList()..sort())
            <String, String>{'name': name, 'value': values[name]!},
        ],
        'revision': revision,
        if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
      });

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (_controllerSession?.authenticated == true && _state.value.isPaired) {
      try {
        await _sendFramePayload({'type': 'controller_close'});
      } catch (_) {
        // A vanished connection is closed already.
      }
    }
    _disposed = true;
    if (identical(_scheduler.reconnectHost, _reattachForScheduler)) {
      // Our hooks, not a successor client's: withdraw them.
      _scheduler.reconnectHost = null;
      _scheduler.hostAttached = null;
    }
    await _authSub?.cancel();
    _authSub = null;
    await _sub?.cancel();
    await _socket?.close();
    _socket = null;
    if (!_inbound.isClosed) await _inbound.close();
    if (!_agentStatus.isClosed) await _agentStatus.close();
    _state.dispose();
  }

  // --- internals -------------------------------------------------------------

  void _onData(dynamic raw) {
    final Map<String, dynamic> env;
    try {
      final decoded = jsonDecode(
        raw is String ? raw : utf8.decode(raw as List<int>),
      );
      if (decoded is! Map<String, dynamic>) return;
      env = decoded;
    } catch (_) {
      return; // A malformed frame from the relay is dropped, never fatal.
    }

    final type = env['type'];
    final controller = _controllerSession;
    if (controller != null) {
      if (type == 'controller_frame') {
        if (controller.authenticated &&
            env['connection'] == controller.connection) {
          unawaited(_handleFrame(env));
        }
      } else if (type == 'controller_challenge' || type == 'controller_ready') {
        _pairingQueue = _pairingQueue
            .then((_) async {
              if (type == 'controller_challenge') {
                final proof = await controller.challenge(env);
                if (proof != null) _socket?.send(jsonEncode(proof));
              } else if (await controller.ready(env)) {
                final done = _pairingDone;
                if (done != null && !done.isCompleted) done.complete();
              }
            })
            .catchError(_failPairing);
      }
      return;
    }
    if (type == 'frame') {
      unawaited(_handleFrame(env));
      return;
    }
    if (type == 'pairing' && !(_state.value.isPaired)) {
      // Serialise pairing steps. The host sends confirm-c and device-c
      // back-to-back; handling them concurrently would run onPeerDeviceKey
      // (device-c) before the awaited onConfirmC (confirm-c) has transitioned
      // the state to `confirmed`, throwing wrongState. Chain each step after
      // the previous one completes.
      _pairingQueue = _pairingQueue
          .then(
            (_) => _reconnect != null
                ? _handleReconnect(env)
                : _handlePairing(env),
          )
          .catchError(_failPairing);
    }
  }

  Future<void> _handleReconnect(Map<String, dynamic> env) async {
    final reconnect = _reconnect;
    if (reconnect == null) return;
    final step = env['step'];
    final data = env['data'];
    if (step is! String || data is! Map) return;
    final msg = data.cast<String, dynamic>();
    if (kDebugMode) debugPrint('[agents-relay] recv reconnect step=$step');

    switch (step) {
      case 'reconnect-hello':
        _sendPairing('reconnect-response', await reconnect.onHello(msg));
      case 'reconnect-confirm':
        await reconnect.onConfirm(msg);
        if (reconnect.authenticated) {
          final done = _pairingDone;
          if (done != null && !done.isCompleted) done.complete();
        }
      default:
        break;
    }
  }

  Future<void> _handlePairing(Map<String, dynamic> env) async {
    final pairing = _pairing;
    if (pairing == null) return;
    final step = env['step'];
    final data = env['data'];
    if (step is! String || data is! Map) return;
    final msg = data.cast<String, dynamic>();
    if (kDebugMode) debugPrint('[agents-relay] recv pairing step=$step');

    switch (step) {
      case 'commit':
        pairing.onCommit(msg);
        _sendPairing('pubkey', pairing.createPubkey());
      case 'reveal':
        _sendPairing('confirm-d', await pairing.onReveal(msg));
      case 'confirm-c':
        await pairing.onConfirmC(msg);
        // Reveal our own device key (device-d). The host reveals device-c.
        _sendPairing('device-d', await pairing.createDeviceKey());
        _maybeCompletePairing();
      case 'device-c':
        await pairing.onPeerDeviceKey(msg);
        _maybeCompletePairing();
      default:
        // Unknown pairing step: ignore rather than abort.
        break;
    }
  }

  void _maybeCompletePairing() {
    if (_pairing?.state == AgentsPairingState.completed) {
      final done = _pairingDone;
      if (done != null && !done.isCompleted) done.complete();
    }
  }

  void _sendPairing(String step, Map<String, dynamic> data) {
    if (kDebugMode) debugPrint('[agents-relay] send pairing step=$step');
    _socket?.send(
      jsonEncode(<String, dynamic>{
        'type': 'pairing',
        'step': step,
        'data': data,
      }),
    );
  }

  Future<void> _handleFrame(Map<String, dynamic> env) async {
    final opener = _opener;
    if (opener == null) return;
    final wire = env['frame'];
    if (wire is! String) return;

    final AgentsFrame frame;
    try {
      frame = _frameFromWire(wire);
    } catch (_) {
      return; // Malformed / not a frame — drop.
    }

    final Uint8List plaintext;
    try {
      plaintext = await opener.open(frame);
    } on AgentsFrameRejectedException {
      return; // Hostile or replayed frame — drop silently, never render.
    }

    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic>) return;
      payload = decoded;
    } catch (_) {
      return;
    }
    _dispatch(payload);
  }

  void _dispatch(Map<String, dynamic> payload) {
    if (_inbound.isClosed) return;
    // A replay stream re-sends stored turns marked ``replay`` so the UI renders
    // them as history, not as a live run. The flag rides every replayed event.
    final replay = payload['replay'] == true;
    // The replay cursor. Every replayed event carries it; a live event may.
    final mid = AgentsRelayTool._asInt(payload['mid']);
    switch (payload['type']) {
      case 'host_route':
        final trust = _establishedTrust;
        final value = payload['url'];
        final url = value is String ? Uri.tryParse(value) : null;
        // This is inside a verified host frame, never an API routing hint.
        if (trust != null &&
            url != null &&
            url.scheme == 'wss' &&
            url.path == '/v2/relay/ws' &&
            (url.queryParameters['cw_device']?.isNotEmpty ?? false)) {
          final migrated = AgentsStoredPairing(
            hostUrl: url,
            channelId: trust.channelId,
            channelKey: trust.channelKey,
            peerDeviceId: trust.peerDeviceId,
            peerPublicKey: trust.peerPublicKey,
          );
          _establishedTrust = migrated;
          final sink = onTrustUpdated;
          if (sink != null) unawaited(sink(migrated).catchError((Object _) {}));
        }
      case 'delta':
        final text =
            payload['text'] ?? payload['delta'] ?? payload['content'] ?? '';
        _inbound.add(
          AgentsRelayDelta(
            '$text',
            replay: replay,
            mid: mid,
            sentAt: epochSecondsToDateTime(payload['created_at']),
          ),
        );
      case 'user':
        // Only a replay carries the user's own turn back (the live client wrote
        // it locally). Surfaced so a reconnected/reinstalled client rebuilds both
        // sides of the thread.
        final text = payload['text'] ?? payload['content'] ?? '';
        _inbound.add(
          AgentsRelayUser(
            '$text',
            replay: replay,
            mid: mid,
            sentAt: epochSecondsToDateTime(payload['created_at']),
          ),
        );
      case 'reasoning':
        final text = payload['text'] ?? payload['reasoning'] ?? '';
        _inbound.add(
          AgentsRelayReasoning(
            '$text',
            replay: replay,
            mid: mid,
            sentAt: epochSecondsToDateTime(payload['created_at']),
          ),
        );
      case 'task_ack':
        // The host's answer to one `task` frame. Nothing is rendered from it
        // directly: it either clears the app's record of an unacknowledged
        // send, or it tells the thread the send failed and why.
        final ack = AgentsRelayTaskAck.fromPayload(payload);
        if (ack != null) _inbound.add(ack);
      case 'heartbeat':
        // Proof of life. Nothing is rendered from it: it only stops the app
        // from reading a long prefill or a long command as a dead host.
        final elapsed = payload['elapsed'];
        _inbound.add(
          AgentsRelayHeartbeat(
            runId: payload['run_id'] is String
                ? payload['run_id'] as String
                : null,
            sessionKey: payload['session_key'] is String
                ? payload['session_key'] as String
                : null,
            seq: AgentsRelayTool._asInt(payload['seq']) ?? 0,
            elapsedSeconds: elapsed is num ? elapsed.toDouble() : null,
          ),
        );
      case 'tool':
        _inbound.add(AgentsRelayTool.fromPayload(payload));
      case 'file':
        _inbound.add(_fileFromPayload(payload));
      case 'browser_data':
        final data = payload['data'];
        if (data is String && data.isNotEmpty) {
          try {
            _inbound.add(AgentsRelayBrowserData(base64.decode(data)));
          } on FormatException {
            // A corrupt chunk is dropped, not fatal — the stream continues.
          }
        }
      case 'browser_view':
        _inbound.add(
          AgentsRelayBrowserView(
            status: '${payload['status'] ?? 'error'}',
            message: '${payload['message'] ?? ''}',
            password: payload['password'] as String?,
            vncAvailable: payload['vnc_available'] == true,
            reason: payload['reason'] is String
                ? payload['reason'] as String
                : '',
          ),
        );
      case 'approval_request':
        final request = AgentsRelayApprovalRequest.fromPayload(payload);
        if (request != null) _inbound.add(request);
      case 'secret_request':
        // The model asked for keys by name; the run waits on the answer.
        final request = AgentsRelaySecretRequest.fromPayload(payload);
        if (request != null) _inbound.add(request);
      case 'automation':
        final automation = AgentsRelayAutomation.fromPayload(payload);
        if (automation != null) _inbound.add(automation);
      case 'automation_list':
        _inbound.add(AgentsRelayAutomationList.fromPayload(payload));
      case 'documents':
        _inbound.add(AgentsRelayDocuments(payload));
      case 'skills_list':
        _inbound.add(AgentsRelaySkillsList.fromPayload(payload));
      case 'agent_status':
        if (!_agentStatus.isClosed) {
          _agentStatus.add(AgentsRelayAgentStatus.fromPayload(payload));
        }
      case 'agent_list':
        _inbound.add(AgentsRelayAgentList.fromPayload(payload));
      case 'run_state':
        final runState = AgentsRelayRunState.fromPayload(payload);
        if (runState != null) _inbound.add(runState);
      case 'done':
        final iterations = payload['iterations'];
        final finalAnswer = payload['final_answer'];
        final reason = payload['reason'];
        final tokens = payload['tokens_spent'] ?? payload['tokensSpent'];
        final runId = payload['run_id'];
        _inbound.add(
          AgentsRelayDone(
            finalAnswer: finalAnswer is String ? finalAnswer : null,
            sessionKey: payload['session_key'] is String
                ? payload['session_key'] as String
                : null,
            hostNotified: payload['host_notified'] == true,
            reason: reason is String ? reason : null,
            iterations: iterations is int
                ? iterations
                : (iterations is num ? iterations.toInt() : null),
            tokensSpent: tokens is int
                ? tokens
                : (tokens is num ? tokens.toInt() : null),
            replay: replay,
            runId: runId is String && runId.isNotEmpty ? runId : null,
            whileAway: payload['while_away'] == true,
            startedAt: epochSecondsToDateTime(payload['started_at']),
            finishedAt: epochSecondsToDateTime(payload['finished_at']),
            firstMid: AgentsRelayTool._asInt(payload['first_mid']),
            lastMid: AgentsRelayTool._asInt(payload['last_mid']),
            hasMore: payload['has_more'] == true,
            oldestMid: AgentsRelayTool._asInt(payload['oldest_mid']),
            pageBeforeId: AgentsRelayTool._asInt(payload['before_id']),
          ),
        );
      case 'reprovision_request':
        // The host wants a fresh account token. Answered here, never surfaced:
        // there is nothing for the user to see or decide.
        unawaited(_answerReprovisionRequest(payload));
      case 'account_session_rotated':
        // The host rotated the session while the app was away: adopt and ack.
        unawaited(_adoptRotatedSession(payload));
      case 'host_session_request':
        // The host wants a session of its own. Answered here, never surfaced.
        unawaited(_answerHostSessionRequest());
      case 'mcp_tools':
        // What the host's connectors answered with. Not surfaced either: the
        // list simply stops claiming a working server has no tools.
        unawaited(mcpToolsSink(payload));
      case 'mcp_credentials':
        // Not rendered and not surfaced: the user did nothing and has nothing
        // to decide. It only has to land in the keychain and the mirror before
        // the next task forwards a refresh token the provider has already
        // killed.
        unawaited(mcpCredentialsSink(payload));
      case 'error':
        _inbound.add(
          AgentsRelayRunError('${payload['message'] ?? 'Unknown error'}'),
        );
      case 'debug_context':
        final sessionKey = payload['session_key'];
        _inbound.add(
          AgentsRelayDebugContext(
            sessionKey: sessionKey is String ? sessionKey : '',
            round: AgentsRelayTool._asInt(payload['round']),
            payload: payload,
          ),
        );
      case 'subagent':
        final sub = _subagentFromPayload(payload);
        if (sub != null) _inbound.add(sub);
      case 'room_turn':
        final turn = _roomTurnFromPayload(payload);
        if (turn != null) _inbound.add(turn);
      case 'room_history':
        final hist = _roomHistoryFromPayload(payload);
        if (hist != null) _inbound.add(hist);
      case 'room_done':
        final roomId = payload['room_id'];
        final reason = payload['reason'];
        if (roomId is String && reason is String) {
          _inbound.add(
            AgentsRelayRoomDone(
              roomId: roomId,
              reason: reason,
              messagesSent: AgentsRelayTool._asInt(payload['messages_sent']),
              rounds: AgentsRelayTool._asInt(payload['rounds']),
            ),
          );
        }
      default:
        break;
    }
  }

  /// Turns a `subagent` frame into a [AgentsRelaySubagent], or null when the
  /// wrapped event is not a `subagent_state` (a `subagent_output` delta carries
  /// no lifecycle transition to show). Malformed frames are dropped, not thrown,
  /// so a bad child event never breaks the socket read loop.
  static AgentsRelaySubagent? _subagentFromPayload(
    Map<String, dynamic> payload,
  ) {
    final event = payload['event'];
    if (event is! Map) return null;
    if (event['type'] != 'subagent_state') return null;
    final id = event['subagent_id'];
    final state = event['state'];
    if (id is! String || state is! String) return null;
    final rawTitle = event['title'];
    final rawResult = event['result'];
    final rawError = event['error'];
    final rawTokens = event['tokens_spent'] ?? event['tokensSpent'];
    return AgentsRelaySubagent(
      subagentId: id,
      title: rawTitle is String ? rawTitle : '',
      state: state,
      result: rawResult is String ? rawResult : null,
      error: rawError is String ? rawError : null,
      tokensSpent: rawTokens is int
          ? rawTokens
          : (rawTokens is num ? rawTokens.toInt() : null),
      replay: payload['replay'] == true,
      mid: AgentsRelayTool._asInt(payload['mid']),
    );
  }

  /// Turns a `room_turn` frame into a [AgentsRelayRoomTurn], or null when a
  /// field is missing or the wrong type. Dropped, never thrown.
  static AgentsRelayRoomTurn? _roomTurnFromPayload(
    Map<String, dynamic> payload,
  ) {
    final roomId = payload['room_id'];
    final agentId = payload['agent_id'];
    final handle = payload['handle'];
    final text = payload['text'];
    final round = AgentsRelayTool._asInt(payload['round']);
    if (roomId is! String ||
        agentId is! String ||
        handle is! String ||
        round == null) {
      return null;
    }
    return AgentsRelayRoomTurn(
      roomId: roomId,
      round: round,
      agentId: agentId,
      handle: handle,
      text: text is String ? text : '',
    );
  }

  /// Turns a `room_history` frame into a [AgentsRelayRoomHistory], or null when
  /// malformed. Each turn is parsed like a live `room_turn`; a bad turn in the
  /// list is skipped, not fatal.
  static AgentsRelayRoomHistory? _roomHistoryFromPayload(
    Map<String, dynamic> payload,
  ) {
    final roomId = payload['room_id'];
    final rawTurns = payload['turns'];
    if (roomId is! String || rawTurns is! List) return null;
    final turns = <AgentsRelayRoomTurn>[];
    for (final raw in rawTurns) {
      if (raw is! Map) continue;
      final round = AgentsRelayTool._asInt(raw['round']);
      final agentId = raw['agent_id'];
      final handle = raw['handle'];
      final text = raw['text'];
      if (round == null || agentId is! String || handle is! String) continue;
      turns.add(
        AgentsRelayRoomTurn(
          roomId: roomId,
          round: round,
          agentId: agentId,
          handle: handle,
          text: text is String ? text : '',
        ),
      );
    }
    return AgentsRelayRoomHistory(roomId: roomId, turns: turns);
  }

  /// Turns a `file` payload into a [AgentsRelayFile], decoding the base64 body
  /// exactly once and never keeping the encoded copy. A body that does not
  /// decode, is empty, or contradicts the declared size comes back as an error
  /// card instead of throwing into the socket read loop.
  static AgentsRelayFile _fileFromPayload(Map<String, dynamic> payload) {
    final replay = payload['replay'] == true;
    final mid = AgentsRelayTool._asInt(payload['mid']);
    final rawName = payload['name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : 'unnamed file';
    final rawMime = payload['mime_type'] ?? payload['mimeType'];
    final mimeType = rawMime is String && rawMime.isNotEmpty
        ? rawMime
        : 'application/octet-stream';
    final rawSize = payload['size'];
    final declaredSize = rawSize is int
        ? rawSize
        : (rawSize is num ? rawSize.toInt() : null);
    final data = payload['data'];
    if (data is! String || data.isEmpty) {
      return AgentsRelayFile(
        replay: replay,
        mid: mid,
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error: 'The file arrived without a body.',
      );
    }
    Uint8List bytes;
    try {
      bytes = base64.decode(data);
    } on FormatException {
      return AgentsRelayFile(
        replay: replay,
        mid: mid,
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error: 'The file body is not valid base64.',
      );
    }
    if (bytes.isEmpty) {
      return AgentsRelayFile(
        replay: replay,
        mid: mid,
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error: 'The file is empty.',
      );
    }
    if (declaredSize != null && declaredSize != bytes.length) {
      return AgentsRelayFile(
        replay: replay,
        mid: mid,
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error:
            'The file body does not match the declared size '
            '($declaredSize bytes declared, ${bytes.length} received).',
      );
    }
    return AgentsRelayFile(
      replay: replay,
      mid: mid,
      name: name,
      mimeType: mimeType,
      declaredSize: declaredSize,
      bytes: bytes,
      document: payload['document'] is Map
          ? Map<String, dynamic>.from(payload['document'] as Map)
          : null,
    );
  }

  // Outbound frames are strictly FIFO. `seal` takes its `seq` synchronously
  // but the send happens after an await, so two in-flight sends could reach
  // the wire out of order; the opener enforces strictly increasing seq and
  // would reject the loser (for browser_data that is a hole in the RFB stream
  // and the executor tears the view down). Chaining every send through one
  // future keeps seal+send in call order. A failed send does not poison the
  // chain; its caller still sees the error.
  Future<void> _sendChain = Future<void>.value();

  Future<void> _sendFramePayload(Map<String, dynamic> payload) {
    final next = _sendChain.then((_) => _sendFramePayloadNow(payload));
    _sendChain = next.catchError((Object _) {});
    return next;
  }

  /// Test seam: awaited before each seal so a test can delay or fail one send
  /// and prove the FIFO chain. Null in production.
  @visibleForTesting
  static Future<void> Function(Map<String, dynamic> payload)? debugBeforeSeal;

  Future<void> _sendFramePayloadNow(Map<String, dynamic> payload) async {
    final sealer = _sealer;
    final socket = _socket;
    if (sealer == null || socket == null || !_state.value.isPaired) {
      throw StateError('Not paired');
    }
    final hook = debugBeforeSeal;
    if (hook != null) {
      await hook(payload);
    }
    final frame = await sealer.seal(utf8.encode(jsonEncode(payload)));
    socket.send(
      jsonEncode(<String, dynamic>{
        'type': _controllerSession == null ? 'frame' : 'controller_frame',
        'frame': _frameToWire(frame),
      }),
    );
  }

  void _onSocketDone() {
    if (kDebugMode) {
      debugPrint(
        '[agents-relay] socket closed (paired=${_state.value.isPaired})',
      );
    }
    // The socket is gone: let go of it, or `reconnect` keeps refusing with
    // "Already connected" and the scheduler's `reconnectHost` hook (bead
    // cowork-2n1) can never re-attach after a host drop (review F4).
    unawaited(_sub?.cancel());
    _sub = null;
    _socket = null;
    final done = _pairingDone;
    if (done != null && !done.isCompleted) {
      done.completeError(
        StateError('Host closed the connection during pairing'),
      );
      return;
    }
    if (_state.value.isPaired) {
      _set(
        const AgentsRelayState(
          phase: AgentsRelayPhase.closed,
          detail: 'Disconnected',
        ),
      );
    }
  }

  void _failPairing(Object error) {
    if (kDebugMode) debugPrint('[agents-relay] PAIRING FAILED: $error');
    final done = _pairingDone;
    if (done != null && !done.isCompleted) done.completeError(error);
  }

  void _fail(String detail) {
    _set(AgentsRelayState(phase: AgentsRelayPhase.error, detail: detail));
  }

  Future<void> _closeSocket() async {
    await _sub?.cancel();
    _sub = null;
    await _socket?.close();
    _socket = null;
  }

  void _set(AgentsRelayState next) {
    if (_disposed) return;
    _state.value = next;
    _publishAttachment(next.phase);
  }

  static String _pairingErrorText(Object error) {
    if (error is TimeoutException) return 'Pairing timed out';
    if (error is AgentsPairingException) {
      return 'Pairing failed (${error.rejection.name})';
    }
    return 'Pairing failed';
  }

  /// A sealed frame as it rides the relay: base64 of the frame's JSON text.
  static String _frameToWire(AgentsFrame frame) =>
      base64.encode(utf8.encode(frame.toJsonString()));

  static AgentsFrame _frameFromWire(String wire) =>
      AgentsFrame.fromJsonString(utf8.decode(base64.decode(wire)));
}
