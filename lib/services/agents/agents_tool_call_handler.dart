// The Agents side of `services/tool_call_handler.dart` — THE FOLD.
//
// Upstream chuk_chat runs a full client-side tool loop (discovery, execution,
// fact-check, retry, continuation passes) against its own ToolExecutor. In
// Agents the HOST runs every tool; the client must never dispatch one.
// `ToolCallHandler()` returns this handler when `kFeatureAgents` is on and
// upstream's real loop when it is off. The chat UI talks to both through the
// same `ToolCallHandler` interface, so no call site branches on the flag.
//
// `processAssistantResponse` ALWAYS returns a final answer with
// `shouldContinue == false`, so `startStreamPass` runs exactly once per turn
// and the tool loop, fact-check, retry and continuation passes are
// structurally unreachable. It fills `toolCalls` / `producedBlocks` from
// AgentsRunLedger, so MessageBubble's tool timeline, activity header and
// artifact cards light up from real host data with no edit to the chat UI.

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_enforcer.dart';
import 'package:chuk_chat/services/tool_executor.dart';

/// The Agents fold: one pass per turn, no client-side tool dispatch.
///
/// Implements (does not extend) [ToolCallHandler]: upstream's constructor
/// registers the built-in tools and MCP listeners, and none of that may run
/// in an Agents build.
class AgentsToolCallHandler implements ToolCallHandler {
  AgentsToolCallHandler._internal();

  static final AgentsToolCallHandler instance =
      AgentsToolCallHandler._internal();

  final ToolExecutor _toolExecutor = ToolExecutor();

  /// The stub drops the client tool LOOP, not the executor's registry:
  /// `pages/tool_calling_settings_page.dart` reads this to list the tools and
  /// their on/off state, and nothing here dispatches a tool.
  @override
  ToolExecutor get toolExecutor => _toolExecutor;

  @override
  ToolLoopSession createSession({
    required String initialUserMessage,
    required List<Map<String, dynamic>> history,
    required String accessToken,
    String? discoveryContextKey,
    String? baseSystemPrompt,
    String? modelId,
    bool toolCallingEnabled = true,
    bool discoveryMode = true,
    bool skipIdentity = false,
    bool nativeToolCalling = false,
  }) {
    return ToolLoopSession(
      latestUserMessage: initialUserMessage,
      history: history.map((e) => Map<String, dynamic>.from(e)).toList(),
      accessToken: accessToken,
      // Never consulted: no tool is dispatched on this side. The session type
      // is upstream's, and upstream's loop owns an enforcer.
      enforcer: ToolEnforcer(),
      toolCallingEnabled: toolCallingEnabled,
      discoveryMode: discoveryMode,
      baseSystemPrompt: baseSystemPrompt,
      discoveryContextKey: discoveryContextKey,
      modelId: modelId,
      skipIdentity: skipIdentity,
      nativeToolCalling: nativeToolCalling,
    );
  }

  /// The host owns the system prompt.
  @override
  Future<String> buildInitialSystemPrompt(ToolLoopSession session) async => '';

  /// The host owns the tools. An empty list means the request carries no
  /// `tools[]` array, so no provider can stream native tool calls back.
  @override
  List<Map<String, dynamic>> nativeToolDefinitions(ToolLoopSession session) =>
      const <Map<String, dynamic>>[];

  /// ALWAYS a final answer: `shouldContinue` is never true.
  ///
  /// This is the fold. The turn's stream is already over by the time the
  /// caller gets here (`onComplete`), so everything the host did during it is
  /// sitting in [AgentsRunLedger] under this chat's session key. Taking it and
  /// handing it back as `toolCalls` / `producedBlocks` is what lights up the
  /// renderer — the caller writes `toolCalls` onto the message and appends
  /// `producedBlocks` to its content blocks.
  ///
  /// [nativeToolCalls] is always empty: the Agents transport never emits a
  /// `ToolCallsEvent`, so no provider tool call can reach the client. It is
  /// accepted and ignored to keep the upstream signature.
  @override
  Future<ToolLoopResult> processAssistantResponse({
    required ToolLoopSession session,
    required String content,
    required String reasoning,
    ToolTurnSignals? turnSignals,
    void Function(List<ToolCall>)? onToolCallsUpdated,
    List<NativeToolCall> nativeToolCalls = const <NativeToolCall>[],
  }) async {
    // `discoveryContextKey` is the chat id every caller passes, and an Agents
    // chat id IS the executor's session key. The link's current thread is the
    // fallback for a caller that had none.
    final sessionKey = (session.discoveryContextKey?.isNotEmpty ?? false)
        ? session.discoveryContextKey!
        : AgentsRelayLink.instance.sessionKey.value;
    final run = AgentsRunLedger.instance.take(sessionKey);

    // Anything the ledger recorded is appended to whatever the session already
    // carried, so a caller that pre-seeded the session keeps its rows.
    if (run != null) {
      session.toolCalls.addAll(run.toolCalls);
      session.producedBlocks.addAll(run.blocks);
    }
    // Nothing may be left spinning after the turn is over.
    finalizeStaleToolCalls(session.toolCalls);

    if (session.toolCalls.isNotEmpty) {
      onToolCallsUpdated?.call(List<ToolCall>.unmodifiable(session.toolCalls));
    }

    // The host's own `final_answer` wins over the streamed deltas when it sent
    // one; an empty one never overwrites a real reply.
    final hostAnswer = run?.finalAnswer;
    final resolvedContent = (hostAnswer != null && hostAnswer.trim().isNotEmpty)
        ? hostAnswer
        : content;

    // Both the model's thinking and (in the full-log view) the tool narration
    // ride the same reasoning channel, so the streamed buffer is a superset of
    // the ledger's copy. The ledger is the fallback for a turn whose buffer was
    // lost — a reconnect mid-run, a background completion.
    final ledgerReasoning = run?.modelReasoning ?? '';
    final resolvedReasoning = reasoning.length >= ledgerReasoning.length
        ? reasoning
        : ledgerReasoning;

    return ToolLoopResult.finalAnswer(
      content: resolvedContent,
      reasoning: resolvedReasoning,
      toolCalls: List<ToolCall>.of(session.toolCalls),
      producedBlocks: List<ContentBlock>.of(session.producedBlocks),
    );
  }
}
