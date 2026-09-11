// COWORK STUB. Upstream: chuk_chat/lib/services/tool_call_handler.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay — THE FOLD. Upstream runs a full client-side tool
// loop (discovery, execution, fact-check, retry, continuation passes) against
// its own ToolExecutor. In CoWork the HOST runs every tool; the client must
// never dispatch one.
//
// `processAssistantResponse` ALWAYS returns a final answer with
// `shouldContinue == false`, so `startStreamPass` runs exactly once per turn
// and the tool loop, fact-check, retry and continuation passes are
// structurally unreachable. It fills `toolCalls` / `producedBlocks` from
// CoworkRunLedger, so MessageBubble's tool timeline, activity header and
// artifact cards light up from real host data with no edit to any imported file.
//
// Divergence from upstream, deliberate: `ToolLoopSession.enforcer` is dropped
// (upstream's ToolEnforcer is part of the client tool loop and is not imported).
// No imported file reads it.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:cowork/models/chat_stream_event.dart';
import 'package:cowork/models/content_block.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';

/// One user turn's tool-loop state. In CoWork it only carries what the
/// renderer reads back ([toolCalls], [producedBlocks]).
class ToolLoopSession {
  ToolLoopSession({
    required this.latestUserMessage,
    required this.history,
    required this.accessToken,
    required this.toolCallingEnabled,
    required this.discoveryMode,
    this.baseSystemPrompt,
    this.discoveryContextKey,
    this.modelId,
    this.skipIdentity = false,
    this.nativeToolCalling = false,
  });

  String latestUserMessage;
  final List<Map<String, dynamic>> history;
  final String accessToken;
  final bool toolCallingEnabled;
  final bool discoveryMode;
  final String? baseSystemPrompt;
  final String? discoveryContextKey;
  final String? modelId;
  final bool skipIdentity;
  final bool nativeToolCalling;

  final List<Map<String, dynamic>> discoveredTools = [];
  final Set<String> discoveredToolNames = {};
  final List<String> activeSkillNames = [];

  /// Tool calls surfaced for this turn. P2b feeds this from the run ledger.
  final List<ToolCall> toolCalls = [];

  /// Content blocks produced as side-effects (e.g. a relayed file becomes a
  /// `sandboxArtifact` block). P2b feeds this from the run ledger.
  final List<ContentBlock> producedBlocks = [];

  int consecutiveSandboxInfraFailures = 0;
  int emptyFinalRecoveryAttempts = 0;
  int malformedToolProtocolRecoveryAttempts = 0;
  int truncatedCompletionRecoveryAttempts = 0;
  int deferredActionRecoveryAttempts = 0;
  int nonFinalTurnRecoveryAttempts = 0;
  int factCheckRecoveryAttempts = 0;

  String? factCheckCandidate;
  String factCheckCandidateReasoning = '';
}

/// One more pass over the model. Never produced in CoWork.
class ToolLoopStep {
  const ToolLoopStep({
    required this.message,
    required this.history,
    required this.systemPrompt,
  });

  final String message;
  final List<Map<String, dynamic>> history;
  final String? systemPrompt;
}

/// One segment in the model's interleaved output for a single round: either a
/// text chunk or a single tool call.
class RoundSegment {
  const RoundSegment._({this.text, this.toolCall});

  factory RoundSegment.text(String text) => RoundSegment._(text: text);
  factory RoundSegment.toolCall(ToolCall tc) => RoundSegment._(toolCall: tc);

  final String? text;
  final ToolCall? toolCall;

  bool get isText => text != null;
  bool get isToolCall => toolCall != null;
}

/// The outcome of one round. In CoWork only [ToolLoopResult.finalAnswer] is
/// ever produced.
class ToolLoopResult {
  const ToolLoopResult._({
    required this.shouldContinue,
    this.nextStep,
    this.finalContent,
    this.finalReasoning,
    this.interimContent,
    this.interimBeforeToolCalls = false,
    this.toolCalls = const [],
    this.interleavedSegments = const [],
    this.producedBlocks = const [],
  });

  factory ToolLoopResult.continueWith({
    required ToolLoopStep nextStep,
    String? interimContent,
    bool interimBeforeToolCalls = false,
    List<ToolCall> toolCalls = const [],
    List<RoundSegment> interleavedSegments = const [],
    List<ContentBlock> producedBlocks = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: true,
      nextStep: nextStep,
      interimContent: interimContent,
      interimBeforeToolCalls: interimBeforeToolCalls,
      toolCalls: toolCalls,
      interleavedSegments: interleavedSegments,
      producedBlocks: producedBlocks,
    );
  }

  factory ToolLoopResult.finalAnswer({
    required String content,
    required String reasoning,
    List<ToolCall> toolCalls = const [],
    List<ContentBlock> producedBlocks = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: false,
      finalContent: content,
      finalReasoning: reasoning,
      toolCalls: toolCalls,
      producedBlocks: producedBlocks,
    );
  }

  final bool shouldContinue;
  final ToolLoopStep? nextStep;
  final String? finalContent;
  final String? finalReasoning;
  final String? interimContent;
  final bool interimBeforeToolCalls;
  final List<ToolCall> toolCalls;
  final List<RoundSegment> interleavedSegments;
  final List<ContentBlock> producedBlocks;
}

/// Provider/tool-loop hints extracted from stream metadata.
class ToolTurnSignals {
  const ToolTurnSignals._({this.stopReason, this.finishReason, this.rawMeta});

  final String? stopReason;
  final String? finishReason;
  final Map<String, dynamic>? rawMeta;

  static const Set<String> _toolUseReasons = <String>{
    'tool_use',
    'tool_calls',
    'function_call',
  };

  static const Set<String> _finalReasons = <String>{
    'end_turn',
    'stop',
    'stop_sequence',
    'completed',
  };

  static const Set<String> _truncatedReasons = <String>{'max_tokens', 'length'};

  bool get indicatesToolUse =>
      _toolUseReasons.contains(stopReason) ||
      _toolUseReasons.contains(finishReason);

  bool get indicatesFinalStop =>
      _finalReasons.contains(stopReason) ||
      _finalReasons.contains(finishReason);

  bool get indicatesTruncated =>
      _truncatedReasons.contains(stopReason) ||
      _truncatedReasons.contains(finishReason);

  static ToolTurnSignals fromMeta(Map<String, dynamic>? meta) {
    if (meta == null) return const ToolTurnSignals._();
    final stop = meta['stop_reason'];
    final finish = meta['finish_reason'];
    return ToolTurnSignals._(
      stopReason: stop is String ? stop.toLowerCase() : null,
      finishReason: finish is String ? finish.toLowerCase() : null,
      rawMeta: meta,
    );
  }
}

/// The CoWork fold: one pass per turn, no client-side tool dispatch.
class ToolCallHandler {
  ToolCallHandler._internal();

  static final ToolCallHandler _instance = ToolCallHandler._internal();
  factory ToolCallHandler() => _instance;

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
  Future<String> buildInitialSystemPrompt(ToolLoopSession session) async => '';

  /// The host owns the tools. An empty list means the request carries no
  /// `tools[]` array, so no provider can stream native tool calls back.
  List<Map<String, dynamic>> nativeToolDefinitions(ToolLoopSession session) =>
      const <Map<String, dynamic>>[];

  /// ALWAYS a final answer: `shouldContinue` is never true.
  ///
  /// This is the fold. The turn's stream is already over by the time the
  /// caller gets here (`onComplete`), so everything the host did during it is
  /// sitting in [CoworkRunLedger] under this chat's session key. Taking it and
  /// handing it back as `toolCalls` / `producedBlocks` is what lights up the
  /// imported renderer — the caller writes `toolCalls` onto the message and
  /// appends `producedBlocks` to its content blocks.
  ///
  /// [nativeToolCalls] is always empty: the adapter never emits a
  /// `ToolCallsEvent`, so no provider tool call can reach the client. It is
  /// accepted and ignored to keep the upstream signature.
  Future<ToolLoopResult> processAssistantResponse({
    required ToolLoopSession session,
    required String content,
    required String reasoning,
    ToolTurnSignals? turnSignals,
    void Function(List<ToolCall>)? onToolCallsUpdated,
    List<NativeToolCall> nativeToolCalls = const <NativeToolCall>[],
  }) async {
    // `discoveryContextKey` is the chat id every imported caller passes, and a
    // CoWork chat id IS the executor's session key. The link's current thread
    // is the fallback for a caller that had none.
    final sessionKey = (session.discoveryContextKey?.isNotEmpty ?? false)
        ? session.discoveryContextKey!
        : CoworkRelayLink.instance.sessionKey.value;
    final run = CoworkRunLedger.instance.take(sessionKey);

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

  /// Kept because upstream exposes it as a static helper on this class.
  static int? trailingToolCallBlockStart(String text) => null;

  /// Kept because upstream exposes it as a static helper on this class.
  static bool looksLikeDeferredActionWithoutToolCall(String content) => false;
}
