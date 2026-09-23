// The Agents side of `services/websocket_chat_service.dart` — THE TRANSPORT
// ADAPTER. Upstream chuk_chat talks to a hosted API over the multiplexed
// /v2/ws socket; Agents talks to the paired local Python host through
// AgentsRelayController. `WebSocketChatService.sendStreamingChat` hands the
// request here when `kFeatureAgents` is on and keeps upstream's path when it
// is off, so no call site branches on the flag.
//
// It must NEVER emit ToolCallsEvent: that is the invariant that keeps the
// client-side tool loop dead. Every host tool is RENDERED (through the run
// ledger), never executed here.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';

/// Service for handling streaming chat responses.
///
/// Same static signature as upstream's `WebSocketChatService.sendStreamingChat`,
/// which forwards here in an Agents build. It sends one task over the paired
/// relay and folds the host's event stream into `ChatStreamEvent`s.
///
/// ## What is ignored, and why
///
/// `history`, `systemPrompt`, `maxTokens`, `temperature` and `tools` are
/// dropped on the floor. The host owns the session, the prompt and the tools —
/// it is the product (see docs/PRODUCT_PHILOSOPHY.md), the client is a window.
/// Sending the client's idea of the history would fight the executor's own
/// append-only session for the same thread.
///
/// ## The mapping
///
/// | inbound (live only) | out | ledger |
/// |---|---|---|
/// | `heartbeat` | `HeartbeatEvent` | ceiling restarted, no output claimed |
/// | `delta` | `ContentEvent` | — |
/// | `reasoning` | `ReasoningEvent` | model reasoning |
/// | `tool` | verbose-only narration on the reasoning channel | open + close |
/// | `subagent` | — | a `subagent` tool line |
/// | `file` | — | blob write, then a `sandboxArtifact` block |
/// | `approval_request` | — | a completed `ask_user` line |
/// | `error` | `ErrorEvent` then `DoneEvent` | finish |
/// | `done` | `MetaEvent` → `UsageEvent` → `DoneEvent` | finish (the thread view sends the `run_ack`) |
/// | `run_state`, `debug_context` | — | stashed |
/// | `room_*`, `browser_*` | — | owned elsewhere |
/// | anything with `replay: true`, and every `user` | — | replay loader only |
///
/// `regenerate` is the one send-side flag Agents adds to chuk_chat's surface:
/// it marks a Retry, so the host replaces the last turn instead of appending a
/// second copy of the same question.
class AgentsChatTransport {
  /// Sessions whose run the USER asked to stop, with the moment they asked.
  ///
  /// A stream subscription is cancelled for many reasons that have nothing to
  /// do with the user: leaving the thread, the chat page being disposed by a
  /// rebuild, the app going to the background, a hot restart, a reinstall, or
  /// the streaming manager replacing one stream with the next. Inferring a
  /// stop from any of those killed live runs on the executor — run
  /// `d1d4ede1`, `reason: interrupted`, no answer, with nobody having pressed
  /// anything (bead cowork-gnr8). The host's own design says the opposite:
  /// "controller disconnected; runs keep going, results are held in the
  /// store". So the `stop` frame goes out on THIS declared intent and on
  /// nothing else.
  static final Map<String, DateTime> _stopIntents = <String, DateTime>{};

  /// How long a declared stop stays valid. Long enough for the cancel it
  /// belongs to, short enough that it can never arm an unrelated later one.
  static const Duration _stopIntentWindow = Duration(seconds: 5);

  /// Declares that the user asked to stop [sessionKey]'s run. Called by the
  /// composer's stop target (through the streaming handler) BEFORE the stream
  /// is cancelled; [withdrawStopIntent] takes it back when the same cancel
  /// turns out to be a page teardown.
  static void declareStopIntent(String sessionKey) {
    if (sessionKey.isEmpty) return;
    _stopIntents[sessionKey] = DateTime.now();
  }

  /// Takes back a declared stop: this cancel was the page going away, not the
  /// user. The run keeps going on the host and the thread picks it up again.
  static void withdrawStopIntent([String? sessionKey]) {
    if (sessionKey == null) {
      _stopIntents.clear();
      return;
    }
    _stopIntents.remove(sessionKey);
  }

  /// Consumes the declared intent for [sessionKey], if it is still fresh.
  static bool _takeStopIntent(String sessionKey) {
    final at = _stopIntents.remove(sessionKey);
    if (at == null) return false;
    return DateTime.now().difference(at) <= _stopIntentWindow;
  }

  /// True while the user's stop for [sessionKey] is still on record. Test seam.
  @visibleForTesting
  static bool hasStopIntent(String sessionKey) =>
      _stopIntents.containsKey(sessionKey);

  /// Sends a streaming chat request and yields chunks as they arrive.
  static Stream<ChatStreamEvent> sendStreamingChat({
    required String accessToken,
    required String message,
    required String modelId,
    required String providerSlug,
    List<Map<String, dynamic>>? history,
    String? systemPrompt,
    int maxTokens = 512,
    double temperature = 0.7,
    List<String>? images,
    String? reasoningEffort,
    String? chatId,
    List<Map<String, dynamic>>? tools,
    bool regenerate = false,
    bool modelSelectionCaptured = false,
  }) {
    final link = AgentsRelayLink.instance;
    final ledger = AgentsRunLedger.instance;
    final sessionKey = (chatId != null && chatId.isNotEmpty)
        ? chatId
        : link.sessionKey.value;
    final verbose = VerboseService.instance.enabled;
    // The name of THIS SEND on the wire, minted once here rather than where
    // the frame is sealed: the re-send after a reconnect has to carry the
    // byte-identical string, which is what lets the host answer `duplicate`
    // instead of running the same question twice.
    //
    // Fresh per call, deliberately. A tool-loop pass, a regenerate and a
    // continue each come through here again and each is a real send the host
    // must run. The host dedupes strictly — a repeated id is answered
    // `duplicate` and never runs — so sharing one id across passes would leave
    // pass two silently undone, which is the failure this whole mechanism
    // exists to remove.
    final String wireTaskId = mintTaskId();
    final selectedRoute = modelSelectionCaptured
        ? Future.value(
            ChatModelSelection(modelId: modelId, providerSlug: providerSlug),
          )
        : ChatModelSelectionService.instance.resolveForSend(
            sessionKey,
            modelId: modelId,
            providerSlug: providerSlug,
          );

    if (images != null && images.isNotEmpty) {
      // No image channel on `sendTask` yet: the frame carries a prompt, not
      // attachments. Dropped loudly rather than silently mangled.
      if (kDebugMode) {
        debugPrint(
          '[agents-adapter] dropping ${images.length} image(s): the relay has '
          'no image channel yet',
        );
      }
    }

    final out = StreamController<ChatStreamEvent>();
    StreamSubscription<AgentsRelayInbound>? sub;

    /// Serialises the handlers. A file event writes bytes to the blob store
    /// before its block is appended; without this chain a `done` arriving right
    /// behind it could be folded while that write is still in flight, and the
    /// artifact would be missing from the finished turn.
    Future<void> chain = Future<void>.value();

    /// True once the run reached its own terminal event. It is what tells
    /// [StreamController.onCancel] — which Dart also fires after a normal
    /// close — apart from a real user cancel.
    var terminated = false;
    var stopRequested = false;

    void emit(ChatStreamEvent event) {
      if (!out.isClosed) out.add(event);
    }

    void closeOut() {
      if (!out.isClosed) unawaited(out.close());
    }

    /// Ends the run: `done` on the wire, ledger closed, stream closed.
    void endRun({
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
      if (terminated) return;
      terminated = true;
      // A terminal is the strongest possible proof the task arrived: the host
      // ran it. Nothing is left to re-send, whether or not an ack ever came.
      unawaited(
        AgentsPendingTasks.clear(
          sessionKey,
          wireTaskId,
        ).catchError((Object _) {}),
      );
      ledger.finish(
        sessionKey,
        finalAnswer: finalAnswer,
        reason: reason,
        iterations: iterations,
        tokensSpent: tokensSpent,
        runId: runId,
        startedAt: startedAt,
        finishedAt: finishedAt,
        firstMid: firstMid,
        lastMid: lastMid,
      );
      // Token delivery is provisional: the host's terminal answer is the
      // complete canonical response, even after missing/filtered tail deltas.
      if (finalAnswer != null) emit(FinalContentEvent(finalAnswer));
      emit(DoneEvent());
      closeOut();
    }

    Future<void> handle(AgentsRelayInbound event) async {
      if (terminated) return;
      // The replay loader owns history. A replayed frame must never enter a
      // live run's stream: it would append yesterday's answer to today's.
      if (_isReplay(event)) return;

      switch (event) {
        case AgentsRelayHeartbeat():
          // The host says the run is alive. It is not output: the ceiling
          // starts again, but a run whose only frames were heartbeats still
          // counts as having produced nothing. Passed on so the streaming
          // manager can log the gap it is closing and the header can stop
          // saying "Connecting".
          //
          // It also proves the task ARRIVED, which matters for a host that
          // sends heartbeats but is too old to send a `task_ack`: without this
          // the record would sit there and the task would go out again on the
          // next pairing, on top of a run that is working perfectly.
          ledger.heartbeat(sessionKey);
          unawaited(
            AgentsPendingTasks.clear(
              sessionKey,
              wireTaskId,
            ).catchError((Object _) {}),
          );
          emit(
            HeartbeatEvent(
              seq: event.seq,
              elapsedSeconds: event.elapsedSeconds,
            ),
          );

        case AgentsRelayTaskAck():
          // The host said what it did with the task frame. Only `rejected`
          // produces anything for the reader.
          if (event.taskId != wireTaskId) {
            // Another send's ack rode this thread's stream — an earlier pass,
            // or a task the thread view re-sent after a reconnect. Clear its
            // record so it is not sent again, and leave this turn alone.
            if (event.isHeld) {
              unawaited(
                AgentsPendingTasks.clear(
                  sessionKey,
                  event.taskId,
                ).catchError((Object _) {}),
              );
            }
            return;
          }
          if (event.isHeld) {
            // `accepted` and `duplicate` are the same thing to the app: the
            // host has it. `duplicate` deliberately paints NOTHING — the
            // answer is coming from the first attempt, and a second bubble
            // would be this fix creating the duplicate it exists to prevent.
            ledger.taskAcknowledged(
              sessionKey,
              taskId: event.taskId,
              runId: event.runId,
            );
            unawaited(
              AgentsPendingTasks.clear(
                sessionKey,
                event.taskId,
              ).catchError((Object _) {}),
            );
            return;
          }
          // Rejected: there is no run and there never will be one for this
          // attempt. The spinner goes now, and the bubble says the send
          // failed with the host's own reason.
          terminated = true;
          ledger.taskRejected(sessionKey, reason: event.reason);
          unawaited(
            AgentsPendingTasks.clear(
              sessionKey,
              event.taskId,
            ).catchError((Object _) {}),
          );
          if (event.isRetryable) {
            // `not_provisioned` is the one rejection the app can act on: the
            // host is up and simply does not have this session's token yet.
            // The prompt goes to the outbox, which the next pairing flushes
            // once the `account_authentication` is through.
            unawaited(
              _queueAndMark(
                message,
                sessionKey,
                selectedRoute,
                reasoningEffort: reasoningEffort,
              ),
            );
          }
          emit(
            ErrorEvent(
              _taskRejectionText(event.reason),
              code: StreamErrorCodes.connectionLost,
            ),
          );
          emit(const DoneEvent());
          closeOut();

        case AgentsRelayDelta(:final text):
          // A token is proof the run is alive: it restarts the ceiling that
          // would otherwise declare it lost. It is also proof the task
          // arrived, so nothing is left to re-send for this thread.
          ledger.touch(sessionKey);
          unawaited(
            AgentsPendingTasks.clear(
              sessionKey,
              wireTaskId,
            ).catchError((Object _) {}),
          );
          if (text.isNotEmpty) emit(ContentEvent(text));

        case AgentsRelayReasoning(:final text):
          if (text.isNotEmpty) {
            ledger.reasoning(sessionKey, text);
            emit(ReasoningEvent(text));
          }

        case AgentsRelayTool():
          // agents's relay emits ONE tool event per completed command, so this
          // is an open and a close in one step. A host that grows real start
          // events lands here with `status == 'running'` and only opens.
          final started =
              event.status == 'running' ||
              event.status == 'started' ||
              event.status == 'pending';
          if (verbose) {
            final args = event.arguments;
            emit(
              ReasoningEvent(
                '▸ ${event.name}${args != null && args.isNotEmpty ? ': $args' : ''}\n',
              ),
            );
          }
          if (started) {
            ledger.openTool(sessionKey, event.name, arguments: event.arguments);
          } else {
            // One mapping for live and replay (bead cowork-b45): the ledger
            // draws this frame exactly as the replay loader will.
            ledger.recordTool(sessionKey, event);
            if (verbose) emit(ReasoningEvent(_toolOutcomeLine(event)));
          }

        case AgentsRelaySubagent():
          ledger.subagent(
            sessionKey,
            subagentId: event.subagentId,
            title: event.title,
            state: event.state,
            result: event.result,
            error: event.error,
          );

        case AgentsRelayFile():
          await ledger.file(sessionKey, event);

        case AgentsRelayAutomation():
          // One transcript line per automation id (docs/WIRE_CONTRACT.md,
          // "Automations"); the strip and the page read the source.
          ledger.automation(sessionKey, event);

        case AgentsRelayAutomationList():
        case AgentsRelayDocuments():
        case AgentsRelaySkillsList():
        case AgentsRelayAgentList():
          break;

        case AgentsRelayApprovalRequest():
          ledger.approval(sessionKey, event);

        case AgentsRelaySecretRequest():
          // Answered by the thread view's card (docs/WIRE_CONTRACT.md,
          // "Secrets"); nothing for the transcript. Values never pass here.
          break;

        case AgentsRelayRunError(:final message):
          terminated = true;
          ledger.finish(sessionKey, reason: 'error');
          emit(ErrorEvent(message, code: StreamErrorCodes.streamFailure));
          emit(DoneEvent());
          closeOut();

        case AgentsRelayDone():
          final runId = event.runId;
          if (event.reason == 'duplicate') {
            // The host already had this exact question in flight and refused to
            // ask it a second time (its own `(session_key, prompt)` guard). This
            // `done` therefore ends THIS attempt, not the turn: the answer is
            // still coming, on the run the host named, and the `run_state` that
            // arrived just before this adopted it in the ledger. Finalising an
            // empty bubble here would hide a working run behind a blank answer.
            //
            // Why it happens at all: the streaming handler retries a whole pass
            // on a reconnectable stream error, which re-sends the task. Before
            // the host refused them, three copies of one question ran at once
            // and were billed three times (2026-09-13, 05:12 / 05:13 / 05:14).
            terminated = true;
            // Nothing is left to re-send: the host has the question.
            unawaited(
              AgentsPendingTasks.clear(
                sessionKey,
                wireTaskId,
              ).catchError((Object _) {}),
            );
            ledger.adoptRunning(
              sessionKey,
              runId: runId,
              prompt: message,
              startedAt: event.startedAt,
            );
            // No `FinalContentEvent`: there is no answer yet. The stream just
            // closes, and the thread keeps its typing indicator on the run the
            // ledger now owns.
            emit(DoneEvent());
            closeOut();
            return;
          }
          // A live turn is written to the local transcript by the UI, not by a
          // replay, so the replay cursor still points BELOW it. Left alone, the
          // next reconnect asks from there, the host honours the cursor, and
          // the replay loader appends the host's copy of this same turn under
          // the local one — the question and the answer show up twice (bead
          // cowork-bkw). Forgetting the cursor makes that next replay a full
          // one, which REPLACES the thread instead of appending to it. It costs
          // one full replay per reconnect and is always right.
          // A host that reports the run's last row lets the cursor move past
          // it instead: the next replay is then a delta and the local turn
          // stays as drawn.
          final lastMid = event.lastMid;
          if (lastMid != null) {
            AgentsReplayLoader.instance.advanceCursor(sessionKey, lastMid);
          } else {
            AgentsReplayLoader.instance.invalidateCursor(sessionKey);
          }
          endRun(
            finalAnswer: event.finalAnswer,
            reason: event.reason,
            iterations: event.iterations,
            tokensSpent: event.tokensSpent,
            runId: runId,
            startedAt: event.startedAt,
            finishedAt: event.finishedAt,
            firstMid: event.firstMid,
            lastMid: event.lastMid,
          );
        // The `run_ack` is the thread view's (its `_onInbound`, WS-7): it
        // sees every live terminal for the thread, including a run adopted
        // after a reconnect that never streamed through here, and it dedups
        // by run id. Acking here as well sent two frames per run (review F14).

        case AgentsRelayDebugContext():
          ledger.debugContext(
            sessionKey,
            Map<String, dynamic>.from(event.payload),
          );

        case AgentsRelayRunState():
        case AgentsRelayUser():
        case AgentsRelayRoomTurn():
        case AgentsRelayRoomDone():
        case AgentsRelayRoomHistory():
        case AgentsRelayBrowserData():
        case AgentsRelayBrowserView():
          // Owned elsewhere: run state and user turns by the replay loader,
          // rooms by the room view, browser frames by the browser page.
          break;
      }
    }

    /// The MetaEvent / UsageEvent pair a `done` produces, emitted before the
    /// DoneEvent so `StreamingManager.getLatestMeta` has them at completion.
    void emitDoneMeta(AgentsRelayDone done) {
      emit(
        MetaEvent(<String, dynamic>{
          if (done.reason != null) 'stop_reason': done.reason,
          if (done.iterations != null) 'iterations': done.iterations,
        }),
      );
      final tokens = done.tokensSpent;
      if (tokens != null) {
        emit(UsageEvent(<String, dynamic>{'total_tokens': tokens}));
      }
    }

    out.onListen = () {
      ledger.begin(sessionKey);
      sub = link.inbound.listen(
        (event) {
          if (event is AgentsRelayDone && !_isReplay(event)) {
            chain = chain.then((_) async {
              if (terminated) return;
              emitDoneMeta(event);
              await handle(event);
            });
            return;
          }
          chain = chain.then((_) => handle(event));
        },
        onError: (Object error, StackTrace _) {
          chain = chain.then((_) async {
            if (terminated) return;
            terminated = true;
            ledger.finish(sessionKey, reason: 'error');
            // `connectionLost`, not `streamFailure`: what raised here is the
            // SOCKET under the stream, not the run. The run belongs to the
            // host process and survives the drop, so the turn must not be
            // offered as something to "continue" — the reconnect's replay is
            // what brings its content back. `streamFailure` stays for a run
            // the host itself reported as dead (`AgentsRelayRunError`).
            emit(ErrorEvent('$error', code: StreamErrorCodes.connectionLost));
            emit(DoneEvent());
            closeOut();
          });
        },
        cancelOnError: false,
      );

      final controller = link.controller.value;
      if (controller == null) {
        terminated = true;
        ledger.finish(sessionKey, reason: 'error');
        // The prompt is not lost because the socket is down: it waits in the
        // outbox and goes out on the next pairing (bead cowork-i7sd). The row
        // on screen is marked so the user can see it and ask for it again.
        unawaited(
          _queueAndMark(
            message,
            sessionKey,
            selectedRoute,
            reasoningEffort: reasoningEffort,
          ),
        );
        emit(
          const ErrorEvent(
            'Your host is not reachable. The message is queued and goes out '
            'as soon as it is back.',
            code: StreamErrorCodes.connectionLost,
          ),
        );
        emit(const DoneEvent());
        closeOut();
        return;
      }

      chain = chain.then((_) async {
        try {
          final route = await selectedRoute;
          // Recorded BEFORE the frame goes out, never after. A fire-and-forget
          // `send()` on a half-open socket reports success for a frame nobody
          // will read, so "the send returned" is not evidence of anything: the
          // record has to exist by the time the frame could be lost. It is
          // cleared by the host's `task_ack`, or by the run's first real
          // output; anything still recorded on the next pairing is re-sent.
          //
          // Started, not awaited. Every read and write of the store goes
          // through one serialiser, so this write is already ahead of the
          // clear that any later ack will queue — the ordering that matters
          // is guaranteed without holding the send behind a disk round trip.
          // Awaiting it would also put two more turns of the event loop
          // between the listen and the frame, and the handler chain that
          // folds the host's events runs behind the same future.
          unawaited(
            AgentsPendingTasks.record(
              sessionKey: sessionKey,
              taskId: wireTaskId,
              prompt: message,
              modelId: route.modelId,
              providerSlug: route.providerSlug,
              reasoningEffort: reasoningEffort,
            ).catchError((Object _) => _unrecorded(sessionKey, wireTaskId)),
          );
          ledger.taskSent(sessionKey, wireTaskId);
          await controller.sendTask(
            message,
            sessionKey: sessionKey,
            modelId: route.modelId,
            providerSlug: route.providerSlug,
            reasoningEffort: reasoningEffort,
            // Names this send, so a re-send after a reconnect is the same
            // task to the host and the host's answer says which one it means.
            taskId: wireTaskId,
            // Ask the executor to echo the raw model context only in the full
            // log view; the quiet default leaves the frame unchanged.
            debug: verbose,
            // A retry replaces the last answer instead of asking again, so the
            // host drops the turn being retried before it stores this prompt.
            // Without it the stored conversation grows one copy of the question
            // per attempt: the transcript shows it four times after four
            // retries, and the model is handed a history in which the user
            // asked the same thing four times (bead cowork-bkw).
            regenerate: regenerate,
          );
        } catch (error) {
          if (terminated) return;
          terminated = true;
          ledger.finish(sessionKey, reason: 'error');
          // The socket said no, so nothing is in flight and there is nothing to
          // wait for an ack on. The prompt moves to the outbox instead, which
          // is the queue for what never went out at all.
          unawaited(
            AgentsPendingTasks.clear(
              sessionKey,
              wireTaskId,
            ).catchError((Object _) {}),
          );
          // Same as the no-controller case: a socket that refused the frame
          // has not lost the prompt, it has only delayed it.
          unawaited(
            _queueAndMark(
              message,
              sessionKey,
              selectedRoute,
              reasoningEffort: reasoningEffort,
            ),
          );
          emit(
            ErrorEvent(
              'Your host did not take the message ($error). It is queued and '
              'goes out as soon as it is back.',
              code: StreamErrorCodes.connectionLost,
            ),
          );
          emit(const DoneEvent());
          closeOut();
        }
      });
    };

    out.onCancel = () async {
      await sub?.cancel();
      sub = null;
      if (terminated || stopRequested) return;
      // One microtask before the decision, and no timer: a cancel that comes
      // from a page teardown is followed, in the SAME synchronous block, by
      // the streaming handler's dispose — which withdraws the intent. A
      // microtask therefore always runs after that withdrawal, and deciding
      // any earlier would send the stop the teardown never asked for.
      await Future<void>.microtask(() {});
      // Not the user: the run keeps going on the host, and the thread picks it
      // up again from the ledger and the replay when the reader comes back.
      if (!_takeStopIntent(sessionKey)) return;
      stopRequested = true;
      final controller = link.controller.value;
      if (controller == null) return;
      // The thread stops animating even if the terminal this causes never
      // reaches the app (the subscription above is already gone).
      ledger.stopRequested(sessionKey);
      try {
        await controller.requestStop(sessionKey: sessionKey);
      } catch (error) {
        if (kDebugMode) debugPrint('[agents-adapter] stop failed: $error');
      }
    };

    return out.stream;
  }

  /// True for anything the replay loader owns: a replayed frame of any kind,
  /// and every `user` turn (which only ever exists in a replay).
  static bool _isReplay(AgentsRelayInbound event) => switch (event) {
    AgentsRelayUser() => true,
    AgentsRelayDelta(:final replay) => replay,
    AgentsRelayReasoning(:final replay) => replay,
    AgentsRelayTool(:final replay) => replay,
    AgentsRelaySubagent(:final replay) => replay,
    AgentsRelayFile(:final replay) => replay,
    AgentsRelayApprovalRequest(:final replay) => replay,
    AgentsRelayAutomation(:final replay) => replay,
    AgentsRelayDone(:final isReplay) => isReplay,
    _ => false,
  };

  /// " ✓ exit 0" / " ✗ exit 2" / " ✗ timed out" — the one-line outcome the
  /// verbose view narrates on the reasoning channel.
  static String _toolOutcomeLine(AgentsRelayTool tool) {
    if (tool.timedOut) return ' ✗ timed out\n';
    final exit = tool.exitCode;
    if (tool.failed) {
      return exit != null ? ' ✗ exit $exit\n' : ' ✗ failed\n';
    }
    return exit != null ? ' ✓ exit $exit\n' : ' ✓ done\n';
  }
}

/// The value a failed [AgentsPendingTasks.record] falls back to.
///
/// A store that cannot be written is not a reason to lose the send: the frame
/// still goes out, the host still answers, and only the reconnect re-send is
/// unavailable for this one message. The record itself is never read, so its
/// contents do not matter — it exists because `catchError` on a
/// `Future<PendingTask>` has to produce one.
PendingTask _unrecorded(String sessionKey, String taskId) => PendingTask(
  taskId: taskId,
  sessionKey: sessionKey,
  prompt: '',
  sentAt: DateTime.now().toUtc(),
);

/// Mints the id that names ONE send on the wire.
///
/// Unique per install without any coordination, and short: the wire contract
/// caps `task_id` at 64 characters. The counter is there because two sends in
/// the same microsecond are possible on a fast machine, and two sends sharing
/// an id would make the host call the second one a duplicate of the first and
/// never run it.
String mintTaskId() {
  _taskSeq = (_taskSeq + 1) & 0xffffff;
  return 't${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${_taskSeq.toRadixString(36)}';
}

int _taskSeq = 0;

/// One plain sentence for a `task_ack` rejection.
///
/// The reasons are fixed slugs from the host, never user content, so they can
/// be mapped without escaping. An unknown slug falls back to a sentence that
/// still tells the reader the true thing: it did not arrive.
String _taskRejectionText(String? reason) => switch (reason) {
  'not_provisioned' =>
    'Your host is not signed in for this conversation yet. The message is '
        'queued and goes out as soon as it is.',
  'queue_full' =>
    'Your host is too busy to take the message right now. Send it again in a '
        'moment.',
  'malformed' => 'Your host could not read the message. Nothing ran.',
  _ => 'Your host did not take the message. Nothing ran.',
};

/// Puts a prompt the socket would not take into the per-thread outbox.
///
/// Never throws and never blocks the caller: the stream has already told the
/// reader what happened, and a queue that cannot be written is not a reason to
/// lose the turn twice.
Future<OutboxTask?> _queueForLater(
  String message,
  String sessionKey,
  Future<ChatModelSelection> selectedRoute, {
  String? reasoningEffort,
}) async {
  try {
    ChatModelSelection? route;
    try {
      route = await selectedRoute;
    } catch (_) {
      // No route resolved: the prompt still queues, and the flush sends it
      // with whatever the thread's model is by then.
    }
    return await AgentsTaskOutbox.enqueue(
      sessionKey: sessionKey,
      prompt: message,
      modelId: route?.modelId,
      providerSlug: route?.providerSlug,
      reasoningEffort: reasoningEffort,
    );
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[agents-outbox] could not queue the prompt: $error');
    }
    return null;
  }
}

/// Queues the prompt, then marks the bubble it came from.
///
/// The mark is `failed`, not `pending`, and that is deliberate: the imported
/// bubble offers **Retry** only for `failed`
/// (`widgets/message_bubble/chrome.dart`, imported — not ours to change), and
/// a queued prompt is exactly the case where the user must be able to ask
/// again. The `queueId` is the outbox entry's own id, so the flush can find
/// the row later and take the mark off.
Future<void> _queueAndMark(
  String message,
  String sessionKey,
  Future<ChatModelSelection> selectedRoute, {
  String? reasoningEffort,
}) async {
  final OutboxTask? task = await _queueForLater(
    message,
    sessionKey,
    selectedRoute,
    reasoningEffort: reasoningEffort,
  );
  if (task == null) return;
  await AgentsQueuedMarks.markQueued(
    sessionKey: sessionKey,
    prompt: message,
    queueId: task.localId,
  );
}
