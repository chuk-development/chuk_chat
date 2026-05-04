import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/tool_enforcer.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:chuk_chat/services/tool_registry.dart';
import 'package:chuk_chat/tool_handlers/platform_tools.dart' as platform_tools;
import 'package:chuk_chat/tool_handlers/notes_tools.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:chuk_chat/utils/tool_sanitizer.dart';

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
  final List<ToolCall> toolCalls = [];
  int emptyFinalRecoveryAttempts = 0;
  int malformedToolProtocolRecoveryAttempts = 0;
  int truncatedCompletionRecoveryAttempts = 0;
  int deferredActionRecoveryAttempts = 0;
  int nonFinalTurnRecoveryAttempts = 0;
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
  });

  factory ToolLoopResult.continueWith({
    required ToolLoopStep nextStep,
    String? interimContent,
    bool interimBeforeToolCalls = false,
    List<ToolCall> toolCalls = const [],
    List<RoundSegment> interleavedSegments = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: true,
      nextStep: nextStep,
      interimContent: interimContent,
      interimBeforeToolCalls: interimBeforeToolCalls,
      toolCalls: toolCalls,
      interleavedSegments: interleavedSegments,
    );
  }

  factory ToolLoopResult.finalAnswer({
    required String content,
    required String reasoning,
    List<ToolCall> toolCalls = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: false,
      finalContent: content,
      finalReasoning: reasoning,
      toolCalls: toolCalls,
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
    unawaited(_toolExecutor.loadPreferences());
    unawaited(platform_tools.initPlatformServices());
  }

  static final ToolCallHandler _instance = ToolCallHandler._internal();
  factory ToolCallHandler() => _instance;

  final ToolExecutor _toolExecutor = ToolExecutor();
  static const int _maxEmptyFinalRecoveryAttempts = 3;
  static const int _maxMalformedToolProtocolRecoveryAttempts = 2;
  static const int _maxTruncatedCompletionRecoveryAttempts = 2;
  static const int _maxDeferredActionRecoveryAttempts = 2;
  static const int _maxNonFinalTurnRecoveryAttempts = 1;
  static const int _maxDiscoveryContexts = 200;
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

    if (toolCallingEnabled && discoveryMode) {
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

      final isNonFinalSignaledTurn =
          (turnSignals != null) &&
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
              skipIdentity: session.skipIdentity,
              modelId: session.modelId,
            ),
          ),
          interimContent: '',
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      return ToolLoopResult.finalAnswer(
        content: displayContent,
        reasoning: effectiveReasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    final declaredTools = _toolExecutor.allTools
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
    for (final call in enforceResult.validCalls) {
      final uiCall = uiCallsById[call.callId]!;

      String rawResult;
      bool isError;
      try {
        final executionResult = await _toolExecutor.execute(
          call.name,
          call.arguments,
          accessToken: session.accessToken,
        );
        rawResult = executionResult.output;
        isError = executionResult.isError;
      } catch (error) {
        rawResult = 'Error executing ${call.name}: $error';
        isError = true;
      }

      if (call.name == 'find_tools' && !isError) {
        _updateDiscoveredTools(session, rawResult);
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

  Future<String> _buildSystemPrompt({
    required String? baseSystemPrompt,
    required bool isToolResult,
    required bool discoveryMode,
    required List<Map<String, dynamic>> discoveredTools,
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

    final tools = _toolExecutor.allTools.map((t) => t.toJson()).toList();
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
          webCrawlToolDef: webCrawlToolDef,
          projectToolDef: projectToolDef,
          artifactToolDef: artifactToolDef,
          artifactSchemaToolDef: artifactSchemaToolDef,
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
    final startsWithIntent = RegExp(
      r"^(ok[,\s]+|sure[,\s]+|alright[,\s]+)?"
      r"(first[,\s]+)?"
      r"(i\s*(?:will|'ll)|let me|i(?:’|')m going to|i need to|i should)\b",
    ).hasMatch(normalized);
    final startsWithIntentIntl = RegExp(
      r'^(ich\s+(?:suche|werde)|'
      r'je\s+vais|'
      r'voy\s+a|'
      r'vado\s+a|'
      r'eu\s+vou|'
      r'wij\s+gaan|'
      r'we\s+will)\b',
    ).hasMatch(normalized);
    if (!startsWithIntent && !startsWithIntentIntl) {
      return false;
    }

    final hasDeferredActionVerb = RegExp(
      r'\b(search|check|look up|lookup|verify|find|fetch|browse|compare|research|pull|'
      r'suche|recherchiere|chercher|rechercher|buscar|investigar|procurar|onderzoek)\b',
    ).hasMatch(normalized);
    if (!hasDeferredActionVerb) {
      return false;
    }

    final hasAnswerLikeStructure =
        normalized.contains('\n') || normalized.contains('```');

    return !hasAnswerLikeStructure;
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
    if (stored == null || stored.discoveredToolNames.isEmpty) {
      return;
    }

    stored.lastUsedAt = DateTime.now();
    session.discoveredToolNames.addAll(stored.discoveredToolNames);
    _refreshDiscoveredToolDefinitions(session);
  }

  void _storeDiscoveryContext(ToolLoopSession session) {
    final contextKey = session.discoveryContextKey?.trim();
    if (contextKey == null || contextKey.isEmpty) {
      return;
    }
    if (session.discoveredToolNames.isEmpty) {
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

class _DiscoveryContextState {
  _DiscoveryContextState();

  DateTime lastUsedAt = DateTime.now();
  final Set<String> discoveredToolNames = <String>{};
}
