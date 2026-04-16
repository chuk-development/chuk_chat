import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_config.dart';
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

  /// When true, the identity section (Soul/User/Memory) is not injected
  /// into the system prompt. Used for assistants with memory disabled.
  final bool skipIdentity;

  final List<Map<String, dynamic>> discoveredTools = [];
  final Set<String> discoveredToolNames = {};
  final List<ToolCall> toolCalls = [];
  int emptyFinalRecoveryAttempts = 0;
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

class ToolLoopResult {
  const ToolLoopResult._({
    required this.shouldContinue,
    this.nextStep,
    this.finalContent,
    this.finalReasoning,
    this.interimContent,
    this.interimBeforeToolCalls = false,
    this.toolCalls = const [],
  });

  factory ToolLoopResult.continueWith({
    required ToolLoopStep nextStep,
    String? interimContent,
    bool interimBeforeToolCalls = false,
    List<ToolCall> toolCalls = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: true,
      nextStep: nextStep,
      interimContent: interimContent,
      interimBeforeToolCalls: interimBeforeToolCalls,
      toolCalls: toolCalls,
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
    bool toolCallingEnabled = true,
    bool discoveryMode = true,
    bool allowMarkdownToolCalls = true,
    bool skipIdentity = false,
  }) {
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
      skipIdentity: skipIdentity,
    );

    if (toolCallingEnabled && discoveryMode) {
      _restoreDiscoveryContext(session);
    }

    return session;
  }

  Future<String> buildInitialSystemPrompt(ToolLoopSession session) async {
    if (!session.toolCallingEnabled) {
      return session.baseSystemPrompt?.trim() ?? '';
    }

    return _buildSystemPrompt(
      baseSystemPrompt: session.baseSystemPrompt,
      isToolResult: false,
      discoveryMode: session.discoveryMode,
      discoveredTools: session.discoveredTools,
      skipIdentity: session.skipIdentity,
    );
  }

  Future<ToolLoopResult> processAssistantResponse({
    required ToolLoopSession session,
    required String content,
    required String reasoning,
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
    final _contentSansThinking = content
        .replaceAll(
          RegExp(r'<thinking>[\s\S]*?</thinking>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          '',
        )
        .trim();

    if (_contentSansThinking.isEmpty && reasoning.contains('<tool_call>')) {
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
    final cleanedContent =
        _stripThinkingTags(hallucinationCheck.cleanedContent).trim();

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

    return ToolLoopResult.continueWith(
      nextStep: ToolLoopStep(
        message: resultMessage,
        history: _cloneHistory(session.history),
        systemPrompt: await _buildSystemPrompt(
          baseSystemPrompt: session.baseSystemPrompt,
          isToolResult: true,
          discoveryMode: session.discoveryMode,
          discoveredTools: session.discoveredTools,
        ),
      ),
      // Preserve all non-tool text from this pass (before/after tool blocks)
      // so assistant text is never lost across multi-pass tool loops.
      interimContent: _stripToolCallBlocks(cleanedContent),
      interimBeforeToolCalls: _hasInterimTextBeforeToolCalls(cleanedContent),
      toolCalls: _cloneToolCalls(session.toolCalls),
    );
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
    if (kFeatureArtifacts) {
      artifactToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'artifact_manager')
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
          includeMapVisualOutput: _toolExecutor.mapVisualOutputEnabled,
          includeChartVisualOutput: _toolExecutor.chartVisualOutputEnabled,
        )
        .trim();

    final base = baseSystemPrompt?.trim();
    if (base == null || base.isEmpty) return toolProtocol;

    return '$base\n\n$toolProtocol';
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
    out = out.replaceAll(
      RegExp(r'</?think>', caseSensitive: false),
      '',
    );
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
