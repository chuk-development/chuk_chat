// COWORK STUB. Upstream: chuk_chat/lib/services/websocket_chat_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay — this is THE TRANSPORT ADAPTER. Upstream talks to
// a hosted API over the multiplexed /v2/ws socket; CoWork talks to the paired
// local Python host through CoworkRelayController.
//
// It must NEVER emit ToolCallsEvent: that is the invariant that keeps the
// client-side tool loop dead. Every host tool is RENDERED (through the run
// ledger), never executed here.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cowork/models/chat_stream_event.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_replay_loader.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/settings/verbose_service.dart';

/// Service for handling streaming chat responses.
///
/// Same path, class and static signature as upstream, so every imported call
/// site binds unchanged. The body is CoWork's: it sends one task over the
/// paired relay and folds the host's event stream into `ChatStreamEvent`s.
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
/// `regenerate` is the one send-side flag CoWork adds to chuk_chat's surface:
/// it marks a Retry, so the host replaces the last turn instead of appending a
/// second copy of the same question.
class WebSocketChatService {
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
  }) {
    final link = CoworkRelayLink.instance;
    final ledger = CoworkRunLedger.instance;
    final sessionKey =
        (chatId != null && chatId.isNotEmpty) ? chatId : link.sessionKey.value;
    final verbose = VerboseService.instance.enabled;

    if (images != null && images.isNotEmpty) {
      // No image channel on `sendTask` yet: the frame carries a prompt, not
      // attachments. Dropped loudly rather than silently mangled.
      if (kDebugMode) {
        debugPrint(
          '[cowork-adapter] dropping ${images.length} image(s): the relay has '
          'no image channel yet',
        );
      }
    }

    final out = StreamController<ChatStreamEvent>();
    StreamSubscription<CoworkRelayInbound>? sub;

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
      emit(DoneEvent());
      closeOut();
    }

    Future<void> handle(CoworkRelayInbound event) async {
      if (terminated) return;
      // The replay loader owns history. A replayed frame must never enter a
      // live run's stream: it would append yesterday's answer to today's.
      if (_isReplay(event)) return;

      switch (event) {
        case CoworkRelayDelta(:final text):
          if (text.isNotEmpty) emit(ContentEvent(text));

        case CoworkRelayReasoning(:final text):
          if (text.isNotEmpty) {
            ledger.reasoning(sessionKey, text);
            emit(ReasoningEvent(text));
          }

        case CoworkRelayTool():
          // cowork's relay emits ONE tool event per completed command, so this
          // is an open and a close in one step. A host that grows real start
          // events lands here with `status == 'running'` and only opens.
          final started = event.status == 'running' ||
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

        case CoworkRelaySubagent():
          ledger.subagent(
            sessionKey,
            subagentId: event.subagentId,
            title: event.title,
            state: event.state,
            result: event.result,
            error: event.error,
          );

        case CoworkRelayFile():
          await ledger.file(sessionKey, event);

        case CoworkRelayAutomation():
          // One transcript line per automation id (docs/WIRE_CONTRACT.md,
          // "Automations"); the strip and the page read the source.
          ledger.automation(sessionKey, event);

        case CoworkRelayAutomationList():
        case CoworkRelaySkillsList():
        case CoworkRelayAgentList():
          break;

        case CoworkRelayApprovalRequest():
          ledger.approval(sessionKey, event);

        case CoworkRelaySecretRequest():
          // Answered by the thread view's card (docs/WIRE_CONTRACT.md,
          // "Secrets"); nothing for the transcript. Values never pass here.
          break;

        case CoworkRelayRunError(:final message):
          terminated = true;
          ledger.finish(sessionKey, reason: 'error');
          emit(ErrorEvent(message, code: StreamErrorCodes.streamFailure));
          emit(DoneEvent());
          closeOut();

        case CoworkRelayDone():
          final runId = event.runId;
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
            CoworkReplayLoader.instance.advanceCursor(sessionKey, lastMid);
          } else {
            CoworkReplayLoader.instance.invalidateCursor(sessionKey);
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

        case CoworkRelayDebugContext():
          ledger.debugContext(
            sessionKey,
            Map<String, dynamic>.from(event.payload),
          );

        case CoworkRelayRunState():
        case CoworkRelayUser():
        case CoworkRelayRoomTurn():
        case CoworkRelayRoomDone():
        case CoworkRelayRoomHistory():
        case CoworkRelayBrowserData():
        case CoworkRelayBrowserView():
          // Owned elsewhere: run state and user turns by the replay loader,
          // rooms by the room view, browser frames by the browser page.
          break;
      }
    }

    /// The MetaEvent / UsageEvent pair a `done` produces, emitted before the
    /// DoneEvent so `StreamingManager.getLatestMeta` has them at completion.
    void emitDoneMeta(CoworkRelayDone done) {
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
          if (event is CoworkRelayDone && !_isReplay(event)) {
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
            emit(
              ErrorEvent('$error', code: StreamErrorCodes.streamFailure),
            );
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
        emit(
          const ErrorEvent(
            'Not connected to your CoWork host.',
            code: StreamErrorCodes.connectionLost,
          ),
        );
        emit(const DoneEvent());
        closeOut();
        return;
      }

      chain = chain.then((_) async {
        try {
          await controller.sendTask(
            message,
            sessionKey: sessionKey,
            modelId: modelId,
            providerSlug: providerSlug,
            reasoningEffort: reasoningEffort,
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
          emit(
            ErrorEvent('$error', code: StreamErrorCodes.connectionLost),
          );
          emit(const DoneEvent());
          closeOut();
        }
      });
    };

    out.onCancel = () async {
      await sub?.cancel();
      sub = null;
      // Dart fires onCancel after a normal close too, so only a cancel that
      // arrives while the run is still open is a real Stop.
      if (terminated || stopRequested) return;
      stopRequested = true;
      final controller = link.controller.value;
      if (controller == null) return;
      try {
        await controller.requestStop(sessionKey: sessionKey);
      } catch (error) {
        if (kDebugMode) debugPrint('[cowork-adapter] stop failed: $error');
      }
    };

    return out.stream;
  }

  /// True for anything the replay loader owns: a replayed frame of any kind,
  /// and every `user` turn (which only ever exists in a replay).
  static bool _isReplay(CoworkRelayInbound event) => switch (event) {
        CoworkRelayUser() => true,
        CoworkRelayDelta(:final replay) => replay,
        CoworkRelayReasoning(:final replay) => replay,
        CoworkRelayTool(:final replay) => replay,
        CoworkRelaySubagent(:final replay) => replay,
        CoworkRelayFile(:final replay) => replay,
        CoworkRelayApprovalRequest(:final replay) => replay,
        CoworkRelayAutomation(:final replay) => replay,
        CoworkRelayDone(:final isReplay) => isReplay,
        _ => false,
      };

  /// " ✓ exit 0" / " ✗ exit 2" / " ✗ timed out" — the one-line outcome the
  /// verbose view narrates on the reasoning channel.
  static String _toolOutcomeLine(CoworkRelayTool tool) {
    if (tool.timedOut) return ' ✗ timed out\n';
    final exit = tool.exitCode;
    if (tool.failed) {
      return exit != null ? ' ✗ exit $exit\n' : ' ✗ failed\n';
    }
    return exit != null ? ' ✓ exit $exit\n' : ' ✓ done\n';
  }
}
