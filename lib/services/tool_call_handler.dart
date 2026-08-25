import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/tool_enforcer.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_sync_service.dart';
import 'package:chuk_chat/services/mcp/mcp_tool_bridge.dart';
import 'package:chuk_chat/services/tool_registry.dart';
import 'package:chuk_chat/tool_handlers/platform_tools.dart' as platform_tools;
import 'package:chuk_chat/tool_handlers/notes_tools.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:chuk_chat/utils/tool_sanitizer.dart';

/// Tools that only read. A round made up entirely of these can run its
/// calls at the same time — none of them changes state, so the order
/// they finish in does not matter.
const Set<String> _readOnlyToolNames = <String>{
  'web_search',
  'web_crawl',
  'search_places',
  'search_restaurants',
  'geocode',
  'get_route',
  'weather',
  'search_chats',
  'get_time',
  'calculate',
  'crypto_data',
  'find_tools',
  'view_chat_images',
};


class ToolLoopSession {
  ToolLoopSession({
    required this.latestUserMessage,
    required this.history,
    required this.accessToken,
    required this.enforcer,
    required this.toolCallingEnabled,
    required this.discoveryMode,
    required this.allowMarkdownToolCalls,
    this.baseSystemPrompt,
    this.discoveryContextKey,
    this.modelId,
    this.skipIdentity = false,
  });

  String latestUserMessage;
  final List<Map<String, dynamic>> history;
  final String accessToken;
  final ToolEnforcer enforcer;
  final bool toolCallingEnabled;
  final bool discoveryMode;
  final bool allowMarkdownToolCalls;
  final String? baseSystemPrompt;
  final String? discoveryContextKey;

  /// Currently-selected model id. When set, the per-model system prompt
  /// configuration (if any) is merged into the final system prompt.
  final String? modelId;

  /// When true, the identity section (Soul/User/Memory) is not injected
  /// into the system prompt. Used for assistants with memory disabled.
  final bool skipIdentity;

  final List<Map<String, dynamic>> discoveredTools = [];
  final Set<String> discoveredToolNames = {};

  /// Skills activated via the `skill` tool, oldest first. Their bodies are
  /// injected under `## ACTIVE SKILL` on every system prompt rebuild for the
  /// rest of the conversation. Ordered (not a Set) so eviction can drop the
  /// least-recently activated one.
  final List<String> activeSkillNames = [];

  final List<ToolCall> toolCalls = [];

  /// Content blocks produced as side-effects of tool calls in this loop
  /// (e.g. `send_file_to_user` emits a `sandboxArtifact` block). These are
  /// surfaced to the streaming handler via `ToolLoopResult.producedBlocks`,
  /// which slices the new items off this list each round.
  final List<ContentBlock> producedBlocks = [];

  int emptyFinalRecoveryAttempts = 0;
  int malformedToolProtocolRecoveryAttempts = 0;
  int truncatedCompletionRecoveryAttempts = 0;
  int deferredActionRecoveryAttempts = 0;
  int nonFinalTurnRecoveryAttempts = 0;
  int factCheckRecoveryAttempts = 0;

  /// The tool-grounded candidate answer captured just before a fact-check
  /// ([VERIFY]) pass, plus its reasoning. The verify pass keeps this as the
  /// final answer unless it emits an explicit `[CORRECTED]` replacement — so a
  /// model that merely acknowledges the check (instead of re-emitting the
  /// answer) can never blank out a valid grounded answer. Consumed (set back to
  /// null) when the fact-check resolves.
  String? factCheckCandidate;
  String factCheckCandidateReasoning = '';
}

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

/// One segment in the model's interleaved output for a single round.
///
/// When the model emits text, then a tool_call, then more text, then
/// another tool_call (and so on), the renderer needs the original order
/// to display intro/outro text around each tool. A segment is either
/// a text chunk or a single tool call.
class RoundSegment {
  const RoundSegment._({this.text, this.toolCall});

  factory RoundSegment.text(String text) => RoundSegment._(text: text);
  factory RoundSegment.toolCall(ToolCall tc) => RoundSegment._(toolCall: tc);

  final String? text;
  final ToolCall? toolCall;

  bool get isText => text != null;
  bool get isToolCall => toolCall != null;
}

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

  /// Ordered list of text/tool segments produced this round. Empty when the
  /// round was not interleaved (no text between tool calls). When non-empty,
  /// renderers should prefer this over [interimContent] + [toolCalls] to
  /// preserve the model's original ordering.
  final List<RoundSegment> interleavedSegments;

  /// New content blocks produced as side-effects of tool calls during this
  /// round (e.g. `send_file_to_user` -> `sandboxArtifact`). Streaming
  /// handlers should append these to the assistant message's content blocks
  /// so the user sees the artifact inline.
  final List<ContentBlock> producedBlocks;
}

/// Provider/tool-loop hints extracted from stream metadata.
///
/// When available, this enables Anthropic/OpenAI-style control flow:
/// - `tool_use` / `tool_calls` => continue tool loop.
/// - `end_turn` / `stop` => finalize answer.
/// - `max_tokens` / `length` => request continuation pass.
///
/// If the backend does not provide these fields, fall back to local parsing.
class ToolTurnSignals {
  const ToolTurnSignals._({this.stopReason, this.finishReason, this.rawMeta});

  final String? stopReason;
  final String? finishReason;
  final Map<String, dynamic>? rawMeta;

  static const Set<String> _toolUseReasons = <String>{
    'tool_use',
    'tool_calls',
    'function_call',
    'function_calls',
  };

  static const Set<String> _finalReasons = <String>{
    'stop',
    'end_turn',
    'stop_sequence',
    'eos',
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
    if (meta == null || meta.isEmpty) {
      return const ToolTurnSignals._();
    }

    final finishReason = _firstLowercasedString(meta, const [
      ['finish_reason'],
      ['response', 'finish_reason'],
      ['provider', 'finish_reason'],
      ['choice', 'finish_reason'],
      ['choices', 0, 'finish_reason'],
    ]);
    final stopReason = _firstLowercasedString(meta, const [
      ['stop_reason'],
      ['response', 'stop_reason'],
      ['provider', 'stop_reason'],
      ['choice', 'stop_reason'],
      ['choices', 0, 'stop_reason'],
    ]);

    return ToolTurnSignals._(
      stopReason: stopReason,
      finishReason: finishReason,
      rawMeta: Map<String, dynamic>.from(meta),
    );
  }

  static String? _firstLowercasedString(
    Map<String, dynamic> root,
    List<List<Object>> paths,
  ) {
    for (final path in paths) {
      final value = _readPath(root, path);
      if (value is! String) continue;
      final normalized = value.trim().toLowerCase();
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return null;
  }

  static Object? _readPath(Object? current, List<Object> path) {
    Object? cursor = current;
    for (final segment in path) {
      if (cursor is Map) {
        cursor = cursor[segment];
        continue;
      }
      if (cursor is List && segment is int) {
        if (segment < 0 || segment >= cursor.length) {
          return null;
        }
        cursor = cursor[segment];
        continue;
      }
      return null;
    }
    return cursor;
  }
}

class ToolCallHandler {
  ToolCallHandler._internal() {
    registerBuiltinTools(_toolExecutor);
    // Connected MCP servers add their tools to the same executor, and keep
    // adding and removing them as the reader connects and disconnects.
    watchMcpConnections(_toolExecutor);
    unawaited(
      McpService.load().then((_) {
        syncMcpTools(_toolExecutor);
        // Pull connectors synced from other devices. A no-op until the reader
        // is signed in with an encryption key; the chat-sync tick retries.
        return McpSyncService.pullAndReconcile();
      }),
    );
    unawaited(_toolExecutor.loadPreferences());
    unawaited(platform_tools.initPlatformServices());
    if (kFeatureSkills) {
      // Fire-and-forget: until it lands only built-ins are in the catalog,
      // which costs a capability, never correctness. Signed-out or key-less
      // starts resolve to an empty list rather than throwing.
      unawaited(SkillRegistry.refreshUserSkills());
    }
  }

  static final ToolCallHandler _instance = ToolCallHandler._internal();
  factory ToolCallHandler() => _instance;

  final ToolExecutor _toolExecutor = ToolExecutor();
  static const int _maxEmptyFinalRecoveryAttempts = 3;
  static const int _maxMalformedToolProtocolRecoveryAttempts = 2;
  static const int _maxTruncatedCompletionRecoveryAttempts = 2;
  static const int _maxDeferredActionRecoveryAttempts = 2;
  static const int _maxNonFinalTurnRecoveryAttempts = 1;

  /// One-shot self-verification pass before a tool-grounded answer is shown.
  static const int _maxFactCheckRecoveryAttempts = 1;

  /// Tools whose results carry no verifiable real-world facts. When EVERY
  /// tool call in a turn falls in this set, the fact-check pass is skipped —
  /// there is nothing to verify against sources (a coin flip, a generated
  /// image, a UUID). Information-retrieval tools (web_search, web_crawl,
  /// data lookups, …) are intentionally absent so they trigger the pass.
  static const Set<String> _nonFactualToolNames = {
    'find_tools',
    'notes',
    'ask_user',
    'flip_coin',
    'roll_dice',
    'random_number',
    'countdown',
    'password_generator',
    'uuid_generator',
    'generate_qr',
    'calculate',
    'generate_image',
    'fetch_image',
    // `skill` returns an acknowledgement, not facts. Without this entry a
    // turn whose only tool call was `skill()` would trigger a full [VERIFY]
    // round-trip that fact-checks an ack against nothing.
    'skill',
    // CoWork laptop-native tools return local machine state (command output,
    // file contents, directory listings), not verifiable real-world facts.
    // Without these entries every turn that touches the local machine would
    // fire a spurious [VERIFY] fact-check round against nothing.
    'run_command',
    'read_file',
    'write_file',
    'list_directory',
  };

  static const int _maxDiscoveryContexts = 200;

  /// Ceiling on skills active in one chat. Every active skill's body is
  /// re-injected into the system prompt each round, and the tool protocol is
  /// invisible to `_calculateTokenLimits`, so this bounds the worst case.
  /// Activating a fourth skill evicts the least-recently activated one.
  static const int _maxActiveSkillsPerChat = 3;
  final Map<String, _DiscoveryContextState> _discoveryContextStates =
      <String, _DiscoveryContextState>{};

  ToolExecutor get toolExecutor => _toolExecutor;

  ToolLoopSession createSession({
    required String initialUserMessage,
    required List<Map<String, dynamic>> history,
    required String accessToken,
    String? discoveryContextKey,
    String? baseSystemPrompt,
    String? modelId,
    bool toolCallingEnabled = true,
    bool discoveryMode = true,
    bool allowMarkdownToolCalls = true,
    bool skipIdentity = false,
  }) {
    // Pin the chat id on the executor for the duration of this send. The
    // `discoveryContextKey` carries the active chat id from the send
    // logic — treat it as authoritative for tool invocations so
    // artifact_manager / typst_compile never race static-state
    // propagation on the first turn of a newly-created chat.
    _toolExecutor.currentChatId = discoveryContextKey;
    final enforcer = ToolEnforcer(maxIterations: 24)..resetIteration();

    // Tell the enforcer which tools bypass discovery.
    final bypass = <String>{};
    if (WorkspaceStorageService.selectedWorkspaceId != null) {
      bypass.add('update_project');
    }
    if (kFeatureArtifacts) {
      bypass.add('artifact_manager');
    }
    if (bypass.isNotEmpty) {
      enforcer.alwaysAllowedTools = bypass;
    }

    final session = ToolLoopSession(
      latestUserMessage: initialUserMessage,
      history: _cloneHistory(history),
      accessToken: accessToken,
      enforcer: enforcer,
      toolCallingEnabled: toolCallingEnabled,
      discoveryMode: discoveryMode,
      allowMarkdownToolCalls: allowMarkdownToolCalls,
      baseSystemPrompt: baseSystemPrompt,
      discoveryContextKey: discoveryContextKey,
      modelId: modelId,
      skipIdentity: skipIdentity,
    );

    // Not gated on discoveryMode: skills must survive across user turns even
    // when tool discovery is switched off, and the restore is a no-op when
    // there is nothing stored.
    if (toolCallingEnabled) {
      _restoreDiscoveryContext(session);
    }

    return session;
  }

  Future<String> buildInitialSystemPrompt(ToolLoopSession session) async {
    if (!session.toolCallingEnabled) {
      // Even when tools are disabled the per-model prompt should still apply,
      // so route through the merge helper rather than returning the raw base.
      final base = session.baseSystemPrompt?.trim() ?? '';
      final merged = await _applyPerModelPrompt(
        base: base,
        modelId: session.modelId,
      );
      return merged ?? base;
    }

    return _buildSystemPrompt(
      baseSystemPrompt: session.baseSystemPrompt,
      isToolResult: false,
      discoveryMode: session.discoveryMode,
      discoveredTools: session.discoveredTools,
      activeSkillNames: session.activeSkillNames,
      skipIdentity: session.skipIdentity,
      modelId: session.modelId,
    );
  }

  Future<ToolLoopResult> processAssistantResponse({
    required ToolLoopSession session,
    required String content,
    required String reasoning,
    ToolTurnSignals? turnSignals,
    void Function(List<ToolCall>)? onToolCallsUpdated,
  }) async {
    final enforcer = session.enforcer;
    // Some providers (e.g. Fireworks + Kimi) emit the entire assistant
    // response — including <tool_call> blocks — inside `reasoning_content`
    // while leaving the `content` stream empty. Rescue those tool calls by
    // splitting the reasoning text at the first <tool_call> boundary and
    // treating the remainder as real content.
    var effectiveContent = content;
    var effectiveReasoning = reasoning;

    // Some providers (Kimi K2.5 on Fireworks) emit <thinking> blocks in the
    // content channel while the actual tool calls end up in the reasoning
    // channel.  Strip full <thinking>/<think> blocks (tags + inner text) to
    // determine whether the content is *effectively* empty for rescue purposes.
    final contentSansThinking = content
        .replaceAll(
          RegExp(r'<thinking>[\s\S]*?</thinking>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          '',
        )
        .trim();

    if (contentSansThinking.isEmpty && reasoning.contains('<tool_call>')) {
      final idx = reasoning.indexOf('<tool_call>');
      effectiveReasoning = reasoning.substring(0, idx).trim();
      effectiveContent = reasoning.substring(idx);
    } else {
      // Trailing-tool-call rescue: when reasoning ENDS with one or more
      // </tool_call> blocks (the model "intended" to invoke a tool but emitted
      // it into the reasoning channel after a normal answer), lift those
      // trailing blocks into content so the parser can dispatch them.
      // Only fires when the last non-whitespace content of reasoning is a
      // closing tool_call tag — strong signal of "meant to call this".
      final trimmedReasoning = effectiveReasoning.trimRight();
      if (trimmedReasoning.toLowerCase().endsWith('</tool_call>')) {
        final liftStart = _trailingToolCallBlockStart(trimmedReasoning);
        if (liftStart != null) {
          final lifted = trimmedReasoning.substring(liftStart);
          effectiveReasoning = trimmedReasoning.substring(0, liftStart).trim();
          effectiveContent = effectiveContent.isEmpty
              ? lifted
              : '${effectiveContent.trimRight()}\n$lifted';
        }
      }
    }

    final hallucinationCheck = enforcer.checkForHallucination(effectiveContent);
    // Strip literal `<thinking>` / `<think>` wrapper tags — some providers
    // emit them inline in the content stream, which then renders as visible
    // gibberish in the chat UI.
    final cleanedContent = _stripThinkingTags(
      hallucinationCheck.cleanedContent,
    ).trim();

    if (!session.toolCallingEnabled) {
      final displayContent = _stripToolCallBlocks(cleanedContent);
      return ToolLoopResult.finalAnswer(
        content: displayContent.isEmpty ? cleanedContent : displayContent,
        reasoning: effectiveReasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    final roundThinking = _extractRoundThinking(
      content: cleanedContent,
      reasoning: effectiveReasoning,
    );

    _appendRoundToHistory(
      session,
      assistantContent: cleanedContent,
      assistantReasoning: roundThinking,
    );

    final parsedCalls = parseToolCalls(
      cleanedContent,
      allowMarkdownToolCalls: session.allowMarkdownToolCalls,
    );
    if (parsedCalls.isEmpty) {
      final displayContent = _stripToolCallBlocks(cleanedContent);
      final markerInContent = hasToolCallStartMarker(cleanedContent);
      final markerInReasoning = hasToolCallStartMarker(effectiveReasoning);
      final hasToolProtocolMarker = markerInContent || markerInReasoning;
      final signaledToolUse = turnSignals?.indicatesToolUse ?? false;
      final signaledTruncated = turnSignals?.indicatesTruncated ?? false;

      final shouldRetryAfterMalformedToolProtocol =
          (signaledToolUse || hasToolProtocolMarker) &&
          session.malformedToolProtocolRecoveryAttempts <
              _maxMalformedToolProtocolRecoveryAttempts;

      if (shouldRetryAfterMalformedToolProtocol) {
        session.malformedToolProtocolRecoveryAttempts++;

        const retryMessage =
            'Tool Results:\n'
            '[INFO] The previous response indicated tool usage, but no valid '
            'tool call could be parsed.\n\n'
            'If tools are needed, emit a valid <tool_call> now. '
            'Otherwise, provide the final user-facing answer directly now.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _cloneHistory(session.history),
            systemPrompt: await _buildSystemPrompt(
              baseSystemPrompt: session.baseSystemPrompt,
              isToolResult: true,
              discoveryMode: session.discoveryMode,
              discoveredTools: session.discoveredTools,
              activeSkillNames: session.activeSkillNames,
              skipIdentity: session.skipIdentity,
              modelId: session.modelId,
            ),
          ),
          interimContent: '',
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      final shouldRetryAfterTruncatedCompletion =
          signaledTruncated &&
          session.truncatedCompletionRecoveryAttempts <
              _maxTruncatedCompletionRecoveryAttempts;

      if (shouldRetryAfterTruncatedCompletion) {
        session.truncatedCompletionRecoveryAttempts++;
        const retryMessage =
            'Tool Results:\n'
            '[INFO] The previous response was cut off by the token limit.\n\n'
            'Continue from where you stopped and complete the response for '
            'the user. Do not restart from the beginning.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _cloneHistory(session.history),
            systemPrompt: await _buildSystemPrompt(
              baseSystemPrompt: session.baseSystemPrompt,
              isToolResult: true,
              discoveryMode: session.discoveryMode,
              discoveredTools: session.discoveredTools,
              activeSkillNames: session.activeSkillNames,
              skipIdentity: session.skipIdentity,
              modelId: session.modelId,
            ),
          ),
          interimContent: displayContent,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      final shouldRetryAfterDeferredAction =
          _looksLikeDeferredActionWithoutToolCall(displayContent) &&
          session.deferredActionRecoveryAttempts <
              _maxDeferredActionRecoveryAttempts;

      if (shouldRetryAfterDeferredAction) {
        session.deferredActionRecoveryAttempts++;
        const retryMessage =
            'Tool Results:\n'
            '[INFO] Your previous response said you would perform an action '
            '(search/check/lookup), but no tool call was emitted.\n\n'
            'If external information is required, call the appropriate '
            'tool(s) now. Otherwise, provide the final answer directly now '
            'without saying you will do it later.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _cloneHistory(session.history),
            systemPrompt: await _buildSystemPrompt(
              baseSystemPrompt: session.baseSystemPrompt,
              isToolResult: true,
              discoveryMode: session.discoveryMode,
              discoveredTools: session.discoveredTools,
              activeSkillNames: session.activeSkillNames,
              skipIdentity: session.skipIdentity,
              modelId: session.modelId,
            ),
          ),
          // Preserve interim "I'm checking..." text in the UI while the loop
          // continues with the next tool round.
          interimContent: displayContent,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      // Only treat the turn as "non-final" when the provider actually emitted
      // a stop/finish reason that we recognize as non-final. Absent/unknown
      // signals (Fireworks + Kimi often omit a finish_reason entirely) must
      // NOT trigger a retry — otherwise the model gets asked to "continue"
      // after a complete answer and re-emits the same response, surfacing as
      // a duplicated/reformulated answer below the first one.
      final hasExplicitTurnSignal =
          (turnSignals?.stopReason?.isNotEmpty ?? false) ||
          (turnSignals?.finishReason?.isNotEmpty ?? false);
      final isNonFinalSignaledTurn =
          (turnSignals != null) &&
          hasExplicitTurnSignal &&
          !signaledToolUse &&
          !signaledTruncated &&
          !(turnSignals.indicatesFinalStop);
      final shouldRetryAfterNonFinalTurn =
          session.toolCalls.isNotEmpty &&
          displayContent.trim().isNotEmpty &&
          isNonFinalSignaledTurn &&
          session.nonFinalTurnRecoveryAttempts <
              _maxNonFinalTurnRecoveryAttempts;

      if (shouldRetryAfterNonFinalTurn) {
        session.nonFinalTurnRecoveryAttempts++;
        const retryMessage =
            'Tool Results:\n'
            '[INFO] The previous assistant turn appears non-final while the '
            'tool loop is active.\n\n'
            'Continue this response now. If additional tools are required, '
            'emit valid <tool_call> blocks. If no more tools are needed, '
            'provide the final user-facing answer now.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _cloneHistory(session.history),
            systemPrompt: await _buildSystemPrompt(
              baseSystemPrompt: session.baseSystemPrompt,
              isToolResult: true,
              discoveryMode: session.discoveryMode,
              discoveredTools: session.discoveredTools,
              activeSkillNames: session.activeSkillNames,
              skipIdentity: session.skipIdentity,
              modelId: session.modelId,
            ),
          ),
          interimContent: displayContent,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      final shouldRetryAfterEmptyResponse =
          displayContent.trim().isEmpty &&
          session.toolCalls.isNotEmpty &&
          // A pending fact-check candidate is a valid grounded answer — commit
          // it (resolution below) instead of re-prompting for an empty reply.
          session.factCheckCandidate == null &&
          session.emptyFinalRecoveryAttempts < _maxEmptyFinalRecoveryAttempts;

      if (shouldRetryAfterEmptyResponse) {
        session.emptyFinalRecoveryAttempts++;

        const retryMessage =
            'Tool Results:\n'
            '[INFO] The previous assistant response was empty.\n\n'
            'Continue from the latest tool results and provide the final '
            'answer to the user now. Do not repeat tool calls unless they '
            'are absolutely required.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _cloneHistory(session.history),
            systemPrompt: await _buildSystemPrompt(
              baseSystemPrompt: session.baseSystemPrompt,
              isToolResult: true,
              discoveryMode: session.discoveryMode,
              discoveredTools: session.discoveredTools,
              activeSkillNames: session.activeSkillNames,
              skipIdentity: session.skipIdentity,
              modelId: session.modelId,
            ),
          ),
          interimContent: '',
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      // FACT-CHECK PASS — universal self-verification before a tool-grounded
      // answer is committed. The model produced a candidate answer with no
      // further tool calls. Force ONE verification round: re-check every
      // factual claim against the tool results gathered this turn (entity
      // identity, date/number plausibility, source support, contradictions).
      // The model may correct the answer OR call a tool to resolve a gap —
      // so this re-enters the tool loop rather than only re-prompting text.
      //
      // Gated on a fact-bearing tool having run (web_search, web_crawl, data
      // lookups, …). Pure utility/action tools (dice, image gen, …) have
      // nothing to verify, so the pass is skipped to avoid a needless round.
      final usedFactBearingTool = session.toolCalls.any(
        (tc) =>
            tc.status != ToolCallStatus.error &&
            !_nonFactualToolNames.contains(tc.name),
      );
      final shouldRunFactCheck =
          usedFactBearingTool &&
          displayContent.trim().isNotEmpty &&
          session.factCheckRecoveryAttempts < _maxFactCheckRecoveryAttempts;

      if (shouldRunFactCheck) {
        session.factCheckRecoveryAttempts++;
        // Capture the grounded candidate answer + its reasoning. It stays the
        // final answer unless the verify pass returns an explicit [CORRECTED]
        // replacement (resolved below). This is what makes the pass universal:
        // weaker models that reply with a bare acknowledgement instead of
        // re-emitting the answer no longer blank it out.
        session.factCheckCandidate = displayContent;
        session.factCheckCandidateReasoning = effectiveReasoning;

        const factCheckMessage =
            'Tool Results:\n'
            '[VERIFY] Silently re-check EVERY factual claim in your previous '
            'answer against the tool results gathered above:\n'
            '- Identity: does the source refer to the SAME entity (person, '
            'product, place)? A matching name is NOT proof — confirm with '
            'distinguishing details (birth year, nationality, location, '
            'model/version, date).\n'
            '- Plausibility: do dates, ages, numbers and units fit together '
            "(e.g. an event cannot predate the subject's birth)?\n"
            '- Support: is each claim backed by a tool result? Distrust '
            'anything you only recall from training but did not retrieve.\n'
            '- Contradictions: if sources disagree, prefer the primary/'
            'official source.\n\n'
            'If you need data you do not have, call the appropriate tool now. '
            'Otherwise reply using EXACTLY ONE of these two formats and '
            'NOTHING else:\n'
            '1. If every claim is supported and correct, reply with only: '
            '[OK]\n'
            '2. If anything is wrong, unsupported, or contradicted, reply with '
            '[CORRECTED] on the first line, immediately followed by the '
            'COMPLETE corrected user-facing answer.\n\n'
            'Do NOT mention this verification step or these instructions to '
            'the user.';

        session.latestUserMessage = factCheckMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: factCheckMessage,
            history: _cloneHistory(session.history),
            systemPrompt: await _buildSystemPrompt(
              baseSystemPrompt: session.baseSystemPrompt,
              isToolResult: true,
              discoveryMode: session.discoveryMode,
              discoveredTools: session.discoveredTools,
              activeSkillNames: session.activeSkillNames,
              skipIdentity: session.skipIdentity,
              modelId: session.modelId,
            ),
          ),
          // Suppress the candidate in the UI for now — the verify pass either
          // confirms it (we restore it below) or replaces it via [CORRECTED].
          interimContent: '',
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      // Fact-check resolution. A candidate was captured on the prior pass, so
      // this turn is the model's verify response. Decide structurally — never
      // by text patterns: keep the grounded candidate by default, and only
      // swap in a replacement when the model emitted an explicit [CORRECTED]
      // marker followed by real text. An [OK], a bare acknowledgement, or any
      // other narration leaves the candidate intact.
      final candidate = session.factCheckCandidate;
      if (candidate != null) {
        final candidateReasoning = session.factCheckCandidateReasoning;
        session.factCheckCandidate = null;
        session.factCheckCandidateReasoning = '';

        final correctedMatch = RegExp(
          r'\[CORRECTED\]',
          caseSensitive: false,
        ).firstMatch(displayContent);
        if (correctedMatch != null) {
          final corrected = displayContent.substring(correctedMatch.end).trim();
          if (corrected.isNotEmpty) {
            return ToolLoopResult.finalAnswer(
              content: corrected,
              reasoning: effectiveReasoning,
              toolCalls: _cloneToolCalls(session.toolCalls),
            );
          }
        }

        return ToolLoopResult.finalAnswer(
          content: candidate,
          reasoning: candidateReasoning,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      return ToolLoopResult.finalAnswer(
        content: displayContent,
        reasoning: effectiveReasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    // When memory is disabled (skipIdentity), suppress the notes tool from
    // both the enforcer's declared list and the prompt's tools section so
    // the assistant cannot call it (no overwrite/delete of memory).
    final declaredTools = _toolExecutor.allTools
        .where((t) => !session.skipIdentity || t.name != 'notes')
        .map((t) => t.toJson())
        .toList();
    enforcer.setDeclaredTools(declaredTools);
    enforcer.discoveryMode = session.discoveryMode;
    enforcer.discoveredToolNames = session.discoveredToolNames;

    final enforceResult = enforcer.enforce(parsedCalls);

    if (enforceResult.iterationLimitReached) {
      return ToolLoopResult.finalAnswer(
        content:
            'Sorry, I hit the tool-call safety limit for this request. '
            'Please try again with a simpler prompt.',
        reasoning: effectiveReasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    for (final rejected in enforceResult.rejectedCalls) {
      session.toolCalls.add(
        ToolCall(
          name: rejected.name,
          arguments: rejected.arguments,
          result: 'Rejected: ${rejected.reason}',
          status: ToolCallStatus.error,
        ),
      );
    }

    if (enforceResult.rejectedCalls.isNotEmpty) {
      onToolCallsUpdated?.call(_cloneToolCalls(session.toolCalls));
    }

    if (!enforceResult.hasValidCalls) {
      final rejectionLines = enforceResult.rejectedCalls
          .map((r) => '[REJECTED] ${r.name}: ${r.reason}')
          .join('\n');

      final nextMessage =
          'Tool Results:\n'
          '$rejectionLines\n\n'
          'Please use only available tools and try again.';

      session.latestUserMessage = nextMessage;
      return ToolLoopResult.continueWith(
        nextStep: ToolLoopStep(
          message: nextMessage,
          history: _cloneHistory(session.history),
          systemPrompt: await _buildSystemPrompt(
            baseSystemPrompt: session.baseSystemPrompt,
            isToolResult: true,
            discoveryMode: session.discoveryMode,
            discoveredTools: session.discoveredTools,
            activeSkillNames: session.activeSkillNames,
            skipIdentity: session.skipIdentity,
            modelId: session.modelId,
          ),
        ),
        interimContent: _stripToolCallBlocks(cleanedContent),
        interimBeforeToolCalls: _hasInterimTextBeforeToolCalls(cleanedContent),
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    final uiCallsById = <String, ToolCall>{};
    for (int i = 0; i < enforceResult.validCalls.length; i++) {
      final call = enforceResult.validCalls[i];
      final uiCall = ToolCall(
        id: call.callId,
        name: call.name,
        arguments: call.arguments,
        status: ToolCallStatus.running,
        roundThinking: i == 0 ? roundThinking : null,
      );
      session.toolCalls.add(uiCall);
      uiCallsById[call.callId] = uiCall;
    }
    onToolCallsUpdated?.call(_cloneToolCalls(session.toolCalls));

    final modelResults = <ToolCallResult>[];
    // Snapshot the session.producedBlocks length BEFORE this round's tool
    // calls so we can slice off only the blocks added in this round and
    // return them via ToolLoopResult.producedBlocks.
    final producedBlocksBefore = session.producedBlocks.length;

    // A round that only looks things up starts all of its calls at once.
    // "When is it open" wants a web search and a places lookup, and running
    // those back to back doubles the wait for nothing. Results are still
    // collected in order below, so the model sees them exactly as before.
    // Anything that writes — notes, artifacts, the device — stays
    // sequential, because with those the order is part of the meaning.
    final inFlight = <String, Future<dynamic>>{};
    if (enforceResult.validCalls.length > 1 &&
        enforceResult.validCalls.every(
          (call) => _readOnlyToolNames.contains(call.name),
        )) {
      for (final call in enforceResult.validCalls) {
        inFlight[call.callId] = _toolExecutor.execute(
          call.name,
          call.arguments,
          accessToken: session.accessToken,
        );
      }
    }

    for (final call in enforceResult.validCalls) {
      final uiCall = uiCallsById[call.callId]!;

      String rawResult;
      bool isError;
      try {
        final executionResult =
            await (inFlight[call.callId] ??
                _toolExecutor.execute(
                  call.name,
                  call.arguments,
                  accessToken: session.accessToken,
                ));
        rawResult = executionResult.output;
        isError = executionResult.isError;
        if (executionResult.producedBlocks.isNotEmpty) {
          session.producedBlocks.addAll(executionResult.producedBlocks);
        }
      } catch (error) {
        rawResult = 'Error executing ${call.name}: $error';
        isError = true;
      }

      if (call.name == 'find_tools' && !isError) {
        _updateDiscoveredTools(session, rawResult);
      }
      if (call.name == 'skill' && !isError) {
        _updateActiveSkills(session, rawResult);
      }

      uiCall.result = rawResult;
      uiCall.completedAt = DateTime.now();
      uiCall.status = isError ? ToolCallStatus.error : ToolCallStatus.completed;
      onToolCallsUpdated?.call(_cloneToolCalls(session.toolCalls));

      modelResults.add(
        ToolCallResult(
          callId: call.callId,
          name: call.name,
          result: sanitizeResultForModel(rawResult),
          isError: isError,
        ),
      );
    }

    final resultMessage = enforcer.buildResultMessage(modelResults);
    session.latestUserMessage = resultMessage;

    final orderedUiCalls = enforceResult.validCalls
        .map((c) => uiCallsById[c.callId])
        .whereType<ToolCall>()
        .toList();
    final interleaved = _splitInterleavedSegments(
      cleanedContent,
      orderedUiCalls,
    );

    return ToolLoopResult.continueWith(
      nextStep: ToolLoopStep(
        message: resultMessage,
        history: _cloneHistory(session.history),
        systemPrompt: await _buildSystemPrompt(
          baseSystemPrompt: session.baseSystemPrompt,
          isToolResult: true,
          discoveryMode: session.discoveryMode,
          discoveredTools: session.discoveredTools,
          activeSkillNames: session.activeSkillNames,
          skipIdentity: session.skipIdentity,
          modelId: session.modelId,
        ),
      ),
      // Preserve all non-tool text from this pass (before/after tool blocks)
      // so assistant text is never lost across multi-pass tool loops.
      interimContent: _stripToolCallBlocks(cleanedContent),
      interimBeforeToolCalls: _hasInterimTextBeforeToolCalls(cleanedContent),
      toolCalls: _cloneToolCalls(session.toolCalls),
      interleavedSegments: interleaved,
      // Forward any side-effect blocks emitted by tools this round
      // (e.g. send_file_to_user -> sandboxArtifact).
      producedBlocks: session.producedBlocks.length > producedBlocksBefore
          ? List<ContentBlock>.unmodifiable(
              session.producedBlocks.sublist(producedBlocksBefore),
            )
          : const <ContentBlock>[],
    );
  }

  /// Walks [content] in source order and splits it into text chunks /
  /// individual tool calls based on the positions of `<tool_call>` blocks.
  ///
  /// Returns an empty list when interleaving cannot be reliably reconstructed
  /// (mismatched span/tool count, or a single span with no surrounding text)
  /// — callers fall back to the legacy bundled rendering in that case.
  List<RoundSegment> _splitInterleavedSegments(
    String content,
    List<ToolCall> uiCalls,
  ) {
    if (uiCalls.isEmpty) return const [];

    final spans = RegExp(
      r'<tool_call>[\s\S]*?</tool_call>',
      caseSensitive: false,
    ).allMatches(content).toList();

    // Mismatch (e.g. some tool calls were rejected, or the markdown form
    // was used) → fall back to legacy rendering.
    if (spans.length != uiCalls.length) return const [];

    final segments = <RoundSegment>[];
    var cursor = 0;
    for (var i = 0; i < spans.length; i++) {
      final span = spans[i];
      final between = content.substring(cursor, span.start).trim();
      if (between.isNotEmpty) {
        segments.add(RoundSegment.text(between));
      }
      segments.add(RoundSegment.toolCall(uiCalls[i]));
      cursor = span.end;
    }
    final tail = content.substring(cursor).trim();
    if (tail.isNotEmpty) {
      segments.add(RoundSegment.text(tail));
    }

    // Don't bother reporting an interleaved view when there was no genuine
    // interleaving — legacy rendering handles "all tools, then optional
    // tail text" cleanly.
    final hasInterleavedText = segments.any(
      (s) => s.isText && segments.indexOf(s) < segments.length - 1,
    );
    final hasMultipleToolGroups = _countToolGroups(segments) > 1;
    if (!hasInterleavedText && !hasMultipleToolGroups) return const [];

    return segments;
  }

  static int _countToolGroups(List<RoundSegment> segments) {
    var groups = 0;
    var inGroup = false;
    for (final s in segments) {
      if (s.isToolCall) {
        if (!inGroup) {
          groups += 1;
          inGroup = true;
        }
      } else {
        inGroup = false;
      }
    }
    return groups;
  }

  void _appendRoundToHistory(
    ToolLoopSession session, {
    required String assistantContent,
    String? assistantReasoning,
  }) {
    final userText = session.latestUserMessage.trim();
    if (userText.isNotEmpty) {
      session.history.add({'role': 'user', 'content': userText});
    }

    final reasoningText = assistantReasoning?.trim() ?? '';
    var assistantText = assistantContent.trim();
    if (reasoningText.isNotEmpty && assistantText.startsWith(reasoningText)) {
      assistantText = assistantText.substring(reasoningText.length).trim();
    }

    if (reasoningText.isEmpty && assistantText.isNotEmpty) {
      session.history.add({'role': 'assistant', 'content': assistantText});
      return;
    }

    if (reasoningText.isNotEmpty) {
      final withThinking = assistantText.isEmpty
          ? '<thinking>\n$reasoningText\n</thinking>'
          : '<thinking>\n$reasoningText\n</thinking>\n\n$assistantText';
      session.history.add({'role': 'assistant', 'content': withThinking});
    }
  }

  void _updateDiscoveredTools(ToolLoopSession session, String findToolsResult) {
    final matches = RegExp(
      r'^TOOL:\s*(\S+)',
      multiLine: true,
    ).allMatches(findToolsResult);
    final discoveredNames = matches
        .map((match) => match.group(1))
        .whereType<String>()
        .toSet();

    if (discoveredNames.isEmpty) return;

    var hasNewTool = false;
    for (final tool in _toolExecutor.allTools) {
      if (tool.name == 'find_tools') continue;
      if (!discoveredNames.contains(tool.name)) continue;
      if (session.discoveredToolNames.contains(tool.name)) continue;

      session.discoveredToolNames.add(tool.name);
      hasNewTool = true;
    }

    if (!hasNewTool) {
      return;
    }

    _refreshDiscoveredToolDefinitions(session);
    _storeDiscoveryContext(session);

    if (kDebugMode) {
      debugPrint(
        '[ToolDiscovery] Discovered: '
        '${session.discoveredToolNames.join(', ')}',
      );
    }
  }

  /// Records a skill activation from the `skill` tool's acknowledgement.
  ///
  /// Scrapes the `SKILL: <name>` first line, mirroring how
  /// [_updateDiscoveredTools] scrapes `TOOL: <name>` out of find_tools. The
  /// marker only appears on success, so an error acknowledgement is ignored
  /// without needing the executor to flag it.
  void _updateActiveSkills(ToolLoopSession session, String skillResult) {
    final match = RegExp(
      r'^SKILL:\s*(\S+)',
      multiLine: true,
    ).firstMatch(skillResult);
    final name = match?.group(1);
    if (name == null) return;

    final skill = SkillRegistry.byName(name);
    if (skill == null) return;

    // Re-activating an already-active skill moves it to most-recent rather
    // than duplicating it.
    session.activeSkillNames
      ..remove(skill.name)
      ..add(skill.name);
    while (session.activeSkillNames.length > _maxActiveSkillsPerChat) {
      session.activeSkillNames.removeAt(0);
    }

    // `allowed-tools` pre-approves tools: mark them discovered so their full
    // definitions land in the same prompt rebuild that carries the body.
    // Filtered against the enabled set — a skill must never resurrect a tool
    // the user switched off.
    final enabledToolNames = _toolExecutor.allTools
        .map((tool) => tool.name)
        .toSet();
    var hasNewTool = false;
    for (final toolName in skill.allowedTools) {
      if (toolName == 'find_tools') continue;
      if (!enabledToolNames.contains(toolName)) continue;
      if (session.discoveredToolNames.add(toolName)) {
        hasNewTool = true;
      }
    }
    if (hasNewTool) {
      _refreshDiscoveredToolDefinitions(session);
    }

    _storeDiscoveryContext(session);

    if (kDebugMode) {
      debugPrint('[Skills] Active: ${session.activeSkillNames.join(', ')}');
    }
  }

  Future<String> _buildSystemPrompt({
    required String? baseSystemPrompt,
    required bool isToolResult,
    required bool discoveryMode,
    required List<Map<String, dynamic>> discoveredTools,
    List<String> activeSkillNames = const [],
    bool skipIdentity = false,
    String? modelId,
  }) async {
    // Check if identity system is enabled before loading Soul/User/Memory.
    // When skipIdentity is true (assistant with memory disabled), skip entirely.
    final identityOn = !skipIdentity && await isIdentityEnabled();

    String? soulText;
    String? userInfoText;
    String? memoryText;
    Map<String, dynamic>? notesToolDef;

    if (identityOn) {
      final results = await Future.wait([
        loadSoulText(),
        loadUserInfoText(),
        loadMemoryText(),
      ]);
      soulText = results[0];
      userInfoText = results[1];
      memoryText = results[2];

      // Get the notes tool definition so it's always available.
      notesToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'notes')
          .map((t) => t.toJson())
          .firstOrNull;
    }

    // ask_user is always available regardless of identity toggle.
    final askUserToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'ask_user')
        .map((t) => t.toJson())
        .firstOrNull;

    // web_search and web_crawl are always available in discovery mode.
    // web_search handles image search too (type="images") so the AI can
    // reach for real photos without another tool registration.
    final webSearchToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'web_search')
        .map((t) => t.toJson())
        .firstOrNull;
    final webCrawlToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'web_crawl')
        .map((t) => t.toJson())
        .firstOrNull;
    // Places sits next to web search rather than behind discovery: a
    // question about a shop's hours wants both in the first response, and
    // a tool the model must discover first cannot be part of that.
    final searchPlacesToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'search_places')
        .map((t) => t.toJson())
        .firstOrNull;

    // search_chats is always available: the AI must be able to recover the
    // subject of a prior-conversation reference without a discovery round-trip.
    final searchChatsToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'search_chats')
        .map((t) => t.toJson())
        .firstOrNull;

    // update_project is always available when a workspace is active.
    Map<String, dynamic>? projectToolDef;
    if (WorkspaceStorageService.selectedWorkspaceId != null) {
      projectToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'update_project')
          .map((t) => t.toJson())
          .firstOrNull;
    }

    // artifact_manager is always available when the feature is enabled —
    // treat it like chart/map/email output, no discovery needed.
    // Chat scoping happens at execute time (tool_executor.dart).
    Map<String, dynamic>? artifactToolDef;
    Map<String, dynamic>? artifactSchemaToolDef;
    if (kFeatureArtifacts) {
      artifactToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'artifact_manager')
          .map((t) => t.toJson())
          .firstOrNull;
      artifactSchemaToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'artifact_schema')
          .map((t) => t.toJson())
          .firstOrNull;
    }

    // Skills. The `skill` tool only registers when kFeatureSkills is on, so
    // its presence is the single source of truth: flag off => no tool, no
    // catalog, no gating, and a byte-identical prompt.
    final skillsEnabled = _toolExecutor.allTools.any((t) => t.name == 'skill');
    Map<String, dynamic>? skillToolDef;
    List<Skill> skillCatalog = const [];
    List<Skill> activeSkills = const [];
    if (skillsEnabled) {
      skillToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'skill')
          .map((t) => t.toJson())
          .firstOrNull;
      skillCatalog = SkillRegistry.all;
      activeSkills = activeSkillNames
          .map(SkillRegistry.byName)
          .whereType<Skill>()
          .toList();
    }

    // When memory is disabled (skipIdentity), exclude the `notes` tool from
    // the prompt's tool list so the assistant can't invoke it to
    // overwrite/delete memory. Identity text injection is already gated above.
    final tools = _toolExecutor.allTools
        .where((t) => !skipIdentity || t.name != 'notes')
        .map((t) => t.toJson())
        .toList();
    final promptBuilder = ToolPromptBuilder(discoveryMode: discoveryMode);
    final toolProtocol = promptBuilder
        .buildToolProtocolSection(
          tools: tools,
          isToolResult: isToolResult,
          discoveredTools: discoveredTools,
          soulText: soulText,
          userInfoText: userInfoText,
          memoryText: memoryText,
          notesToolDef: notesToolDef,
          askUserToolDef: askUserToolDef,
          webSearchToolDef: webSearchToolDef,
          searchPlacesToolDef: searchPlacesToolDef,
          webCrawlToolDef: webCrawlToolDef,
          searchChatsToolDef: searchChatsToolDef,
          projectToolDef: projectToolDef,
          artifactToolDef: artifactToolDef,
          artifactSchemaToolDef: artifactSchemaToolDef,
          skillToolDef: skillToolDef,
          skillCatalog: skillCatalog,
          activeSkills: activeSkills,
          includeMapVisualOutput: _toolExecutor.mapVisualOutputEnabled,
          includeChartVisualOutput: _toolExecutor.chartVisualOutputEnabled,
        )
        .trim();

    final mergedBase = await _applyPerModelPrompt(
      base: baseSystemPrompt,
      modelId: modelId,
    );
    final base = mergedBase?.trim();
    if (base == null || base.isEmpty) return toolProtocol;

    return '$base\n\n$toolProtocol';
  }

  /// Merge the per-model prompt for [modelId] into [base] using the saved
  /// [ModelPromptMode]. Returns [base] unchanged when no per-model config
  /// exists or the model id is empty.
  Future<String?> _applyPerModelPrompt({
    required String? base,
    required String? modelId,
  }) async {
    final id = modelId?.trim();
    if (id == null || id.isEmpty) return base;
    try {
      final cfg = await PerModelSystemPromptService.get(id);
      if (cfg == null || !cfg.isActive) return base;
      final merged = mergeModelPrompt(
        base: base,
        modelPrompt: cfg.prompt,
        mode: cfg.mode,
      );
      if (kDebugMode) {
        debugPrint(
          '[PerModelPrompt] applied modelId=$id mode=${cfg.mode.name} '
          'baseLen=${base?.length ?? 0} mergedLen=${merged?.length ?? 0}',
        );
      }
      return merged;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] apply failed for $id: $error');
      }
      return base;
    }
  }

  String _stripToolCallBlocks(String content) {
    return stripToolCallBlocksForDisplay(content);
  }

  String _extractPreToolText(String content) {
    final toolStart = _indexOfFirstToolCallBlock(content);
    if (toolStart == -1) {
      return _stripToolCallBlocks(content);
    }

    final preText = content.substring(0, toolStart).trim();
    return preText;
  }

  String? _extractRoundThinking({
    required String content,
    required String reasoning,
  }) {
    final providerReasoning = _stripThinkingTags(reasoning).trim();
    if (providerReasoning.isNotEmpty) {
      return providerReasoning;
    }

    final preToolText = _stripThinkingTags(_extractPreToolText(content)).trim();
    if (preToolText.isEmpty) {
      return null;
    }

    return preToolText;
  }

  /// Some providers (Kimi on Fireworks, DeepSeek) wrap reasoning in
  /// `<thinking>…</thinking>` tags and stream it either inside
  /// `reasoning_content` or inline before the tool calls. Rendering
  /// those tags as literal text looks broken, so strip them.
  static String _stripThinkingTags(String text) {
    var out = text.replaceAll(
      RegExp(r'</?thinking>', caseSensitive: false),
      '',
    );
    out = out.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');
    return out;
  }

  /// Returns the start index of the contiguous run of tool-call blocks
  /// (`<tool_call>…</tool_call>`) that terminate `text` (separated only by
  /// whitespace), or null if `text` does not end in a tool-call block.
  /// Used to lift accidental tool calls out of the reasoning channel.
  @visibleForTesting
  static int? trailingToolCallBlockStart(String text) =>
      _trailingToolCallBlockStartImpl(text);

  int? _trailingToolCallBlockStart(String text) =>
      _trailingToolCallBlockStartImpl(text);

  static int? _trailingToolCallBlockStartImpl(String text) {
    final matches = RegExp(
      r'<tool_call>[\s\S]*?</tool_call>',
      caseSensitive: false,
    ).allMatches(text).toList();
    if (matches.isEmpty) return null;
    if (text.substring(matches.last.end).trim().isNotEmpty) return null;
    var start = matches.last.start;
    var prevStart = matches.last.start;
    for (var i = matches.length - 2; i >= 0; i--) {
      final m = matches[i];
      if (text.substring(m.end, prevStart).trim().isNotEmpty) break;
      start = m.start;
      prevStart = m.start;
    }
    return start;
  }

  int _indexOfFirstToolCallBlock(String content) {
    final xmlIndex = content.indexOf('<tool_call>');
    final markdownMatch = RegExp(
      r'```(?:tool_call|toolcall|tool-call)\s*[\s\S]*?```',
      caseSensitive: false,
    ).firstMatch(content);
    final markdownIndex = markdownMatch?.start ?? -1;

    if (xmlIndex == -1) return markdownIndex;
    if (markdownIndex == -1) return xmlIndex;
    return xmlIndex < markdownIndex ? xmlIndex : markdownIndex;
  }

  bool _hasInterimTextBeforeToolCalls(String content) {
    final firstToolCallIndex = _indexOfFirstToolCallBlock(content);
    if (firstToolCallIndex == -1) {
      return false;
    }

    final preToolText = content.substring(0, firstToolCallIndex).trim();
    if (preToolText.isEmpty) {
      return false;
    }

    final withoutThinkingBlocks = preToolText
        .replaceAll(
          RegExp(r'<thinking>[\s\S]*?</thinking>', caseSensitive: false),
          '',
        )
        .trim();

    return withoutThinkingBlocks.isNotEmpty;
  }

  /// Detects "I'll search/check/lookup..." style deferred-action text that
  /// often appears when a model intends to call tools but emits no call.
  @visibleForTesting
  static bool looksLikeDeferredActionWithoutToolCall(String content) =>
      _looksLikeDeferredActionWithoutToolCall(content);

  static bool _looksLikeDeferredActionWithoutToolCall(String content) {
    final text = content.trim();
    if (text.isEmpty || text.length > 280) {
      return false;
    }

    final normalized = text.toLowerCase();

    // Multi-line / fenced output is a real answer, not a promise of one.
    if (normalized.contains('\n') || normalized.contains('```')) {
      return false;
    }

    // "Let me summarize: Magellan left in 1519." — the answer is delivered in
    // the same breath as the announcement, so this is not a deferred action.
    // A bare trailing colon ("Let me search for X:") still counts as deferred.
    final colonIndex = normalized.indexOf(':');
    if (colonIndex >= 0 &&
        normalized.substring(colonIndex + 1).trim().isNotEmpty) {
      return false;
    }

    // The promise is often preceded by a filler sentence ("I have enough
    // information now. Let me write the summary."), so the last sentence is
    // checked as well as the whole text.
    return _isDeferredIntentSentence(normalized) ||
        _isDeferredIntentSentence(_lastSentence(normalized));
  }

  /// Last sentence of [normalized], or the whole string when it has only one.
  static String _lastSentence(String normalized) {
    final parts = normalized
        .split(RegExp(r'(?<=[.!?:])\s+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  static bool _isDeferredIntentSentence(String sentence) {
    final startsWithIntent = RegExp(
      r"^(ok[,\s]+|sure[,\s]+|alright[,\s]+|now[,\s]+)?"
      r"(first[,\s]+)?"
      r"(i\s*(?:will|'ll)|let me|i(?:’|')m going to|i need to|i should)\b",
    ).hasMatch(sentence);
    final startsWithIntentIntl = RegExp(
      r'^(jetzt\s+)?'
      r"(ich\s+(?:suche|werde|erstelle|schreibe|fasse|recherchiere)|"
      r'lass(?:en\s+sie)?\s+mich|'
      r'je\s+vais|'
      r'voy\s+a|'
      r'vado\s+a|'
      r'eu\s+vou|'
      r'wij\s+gaan|'
      r'we\s+will)\b',
    ).hasMatch(sentence);
    if (!startsWithIntent && !startsWithIntentIntl) {
      return false;
    }

    // Verbs that name work the model still owes the user — either a tool call
    // (search/check) or the answer itself (write/summarize).
    return RegExp(
      r'\b(search|check|look up|lookup|verify|find|fetch|browse|compare|research|pull|'
      r'write|create|draft|compile|prepare|put together|summari[sz]e|summary|'
      // de
      r'suche|recherchiere|erstelle[nr]?|schreibe[nr]?|verfasse[nr]?|'
      r'zusammenfass\w*|pr(?:ü|ue)fe[nr]?|nachschauen|nachsehen|'
      // fr
      r'chercher|rechercher|v(?:é|e)rifier|consulter|r(?:é|e)diger|r(?:é|e)sumer|'
      // es
      r'buscar|investigar|revisar|verificar|escribir|resumir|'
      // pt
      r'procurar|pesquisar|escrever|resumir|'
      // it
      r'cercare|verificare|controllare|scrivere|riassumere|'
      // nl
      r'onderzoek|zoeken|opzoeken|nakijken|schrijven|samenvatten)\b',
    ).hasMatch(sentence);
  }

  List<Map<String, dynamic>> _cloneHistory(List<Map<String, dynamic>> history) {
    return history.map((m) => Map<String, dynamic>.from(m)).toList();
  }

  List<ToolCall> _cloneToolCalls(List<ToolCall> calls) {
    return calls.map((c) => ToolCall.fromJson(c.toJson())).toList();
  }

  void _restoreDiscoveryContext(ToolLoopSession session) {
    final contextKey = session.discoveryContextKey?.trim();
    if (contextKey == null || contextKey.isEmpty) {
      return;
    }

    final stored = _discoveryContextStates[contextKey];
    // Check both collections: a skill with no `allowed-tools` — the common
    // case — leaves discoveredToolNames empty, and an early return on that
    // alone would silently drop the activation.
    if (stored == null ||
        (stored.discoveredToolNames.isEmpty &&
            stored.activeSkillNames.isEmpty)) {
      return;
    }

    stored.lastUsedAt = DateTime.now();
    session.discoveredToolNames.addAll(stored.discoveredToolNames);
    session.activeSkillNames
      ..clear()
      ..addAll(stored.activeSkillNames);
    _refreshDiscoveredToolDefinitions(session);
  }

  void _storeDiscoveryContext(ToolLoopSession session) {
    final contextKey = session.discoveryContextKey?.trim();
    if (contextKey == null || contextKey.isEmpty) {
      return;
    }
    if (session.discoveredToolNames.isEmpty &&
        session.activeSkillNames.isEmpty) {
      return;
    }

    final state = _discoveryContextStates.putIfAbsent(
      contextKey,
      _DiscoveryContextState.new,
    );
    state.lastUsedAt = DateTime.now();
    state.discoveredToolNames
      ..clear()
      ..addAll(session.discoveredToolNames);
    state.activeSkillNames
      ..clear()
      ..addAll(session.activeSkillNames);

    _pruneDiscoveryContextsIfNeeded();
  }

  void _refreshDiscoveredToolDefinitions(ToolLoopSession session) {
    final discoveredDefs = _toolExecutor.allTools
        .where(
          (tool) =>
              tool.name != 'find_tools' &&
              session.discoveredToolNames.contains(tool.name),
        )
        .map((tool) => tool.toJson())
        .toList();

    session.discoveredTools
      ..clear()
      ..addAll(discoveredDefs);
  }

  void _pruneDiscoveryContextsIfNeeded() {
    if (_discoveryContextStates.length <= _maxDiscoveryContexts) {
      return;
    }

    final ordered = _discoveryContextStates.entries.toList()
      ..sort((a, b) => a.value.lastUsedAt.compareTo(b.value.lastUsedAt));

    final removeCount = _discoveryContextStates.length - _maxDiscoveryContexts;
    for (int i = 0; i < removeCount; i++) {
      _discoveryContextStates.remove(ordered[i].key);
    }
  }
}

/// Per-chat context that survives across user turns (in memory only — it does
/// not survive an app restart, and neither does tool discovery).
///
/// Skills live here rather than in a parallel map on purpose: a skill's
/// `allowed-tools` marks tools as discovered, so the two are coupled. Two LRU
/// maps would evict independently and leave a skill active whose tools had
/// been forgotten.
class _DiscoveryContextState {
  _DiscoveryContextState();

  DateTime lastUsedAt = DateTime.now();
  final Set<String> discoveredToolNames = <String>{};
  final List<String> activeSkillNames = <String>[];
}
