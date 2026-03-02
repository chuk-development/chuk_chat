import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/tool_enforcer.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:chuk_chat/services/tool_registry.dart';
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
  });

  String latestUserMessage;
  final List<Map<String, dynamic>> history;
  final String accessToken;
  final ToolEnforcer enforcer;
  final bool toolCallingEnabled;
  final bool discoveryMode;
  final bool allowMarkdownToolCalls;
  final String? baseSystemPrompt;

  final List<Map<String, dynamic>> discoveredTools = [];
  final Set<String> discoveredToolNames = {};
  final List<ToolCall> toolCalls = [];
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
    this.toolCalls = const [],
  });

  factory ToolLoopResult.continueWith({
    required ToolLoopStep nextStep,
    String? interimContent,
    List<ToolCall> toolCalls = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: true,
      nextStep: nextStep,
      interimContent: interimContent,
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
  final List<ToolCall> toolCalls;
}

class ToolCallHandler {
  ToolCallHandler._internal() {
    registerBuiltinTools(_toolExecutor);
    unawaited(_toolExecutor.loadPreferences());
  }

  static final ToolCallHandler _instance = ToolCallHandler._internal();
  factory ToolCallHandler() => _instance;

  final ToolExecutor _toolExecutor = ToolExecutor();

  ToolExecutor get toolExecutor => _toolExecutor;

  ToolLoopSession createSession({
    required String initialUserMessage,
    required List<Map<String, dynamic>> history,
    required String accessToken,
    String? baseSystemPrompt,
    bool toolCallingEnabled = true,
    bool discoveryMode = true,
    bool allowMarkdownToolCalls = true,
  }) {
    final enforcer = ToolEnforcer(maxIterations: 24)..resetIteration();

    return ToolLoopSession(
      latestUserMessage: initialUserMessage,
      history: _cloneHistory(history),
      accessToken: accessToken,
      enforcer: enforcer,
      toolCallingEnabled: toolCallingEnabled,
      discoveryMode: discoveryMode,
      allowMarkdownToolCalls: allowMarkdownToolCalls,
      baseSystemPrompt: baseSystemPrompt,
    );
  }

  String buildInitialSystemPrompt(ToolLoopSession session) {
    if (!session.toolCallingEnabled) {
      return session.baseSystemPrompt?.trim() ?? '';
    }

    return _buildSystemPrompt(
      baseSystemPrompt: session.baseSystemPrompt,
      isToolResult: false,
      discoveryMode: session.discoveryMode,
      discoveredTools: session.discoveredTools,
    );
  }

  Future<ToolLoopResult> processAssistantResponse({
    required ToolLoopSession session,
    required String content,
    required String reasoning,
    void Function(List<ToolCall>)? onToolCallsUpdated,
  }) async {
    final enforcer = session.enforcer;
    final hallucinationCheck = enforcer.checkForHallucination(content);
    final cleanedContent = hallucinationCheck.cleanedContent.trim();

    if (!session.toolCallingEnabled) {
      final displayContent = _stripToolCallBlocks(cleanedContent);
      return ToolLoopResult.finalAnswer(
        content: displayContent.isEmpty ? cleanedContent : displayContent,
        reasoning: reasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    _appendRoundToHistory(session, assistantContent: cleanedContent);

    final roundThinking = _extractRoundThinking(
      content: cleanedContent,
      reasoning: reasoning,
    );

    final parsedCalls = parseToolCalls(
      cleanedContent,
      allowMarkdownToolCalls: session.allowMarkdownToolCalls,
    );
    if (parsedCalls.isEmpty) {
      final displayContent = _stripToolCallBlocks(cleanedContent);
      return ToolLoopResult.finalAnswer(
        content: displayContent,
        reasoning: reasoning,
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
        reasoning: reasoning,
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
          systemPrompt: _buildSystemPrompt(
            baseSystemPrompt: session.baseSystemPrompt,
            isToolResult: true,
            discoveryMode: session.discoveryMode,
            discoveredTools: session.discoveredTools,
          ),
        ),
        interimContent: _stripToolCallBlocks(cleanedContent),
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
        systemPrompt: _buildSystemPrompt(
          baseSystemPrompt: session.baseSystemPrompt,
          isToolResult: true,
          discoveryMode: session.discoveryMode,
          discoveredTools: session.discoveredTools,
        ),
      ),
      interimContent: _extractPreToolText(cleanedContent),
      toolCalls: _cloneToolCalls(session.toolCalls),
    );
  }

  void _appendRoundToHistory(
    ToolLoopSession session, {
    required String assistantContent,
  }) {
    final userText = session.latestUserMessage.trim();
    if (userText.isNotEmpty) {
      session.history.add({'role': 'user', 'content': userText});
    }

    final assistantText = assistantContent.trim();
    if (assistantText.isNotEmpty) {
      session.history.add({'role': 'assistant', 'content': assistantText});
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

    for (final tool in _toolExecutor.allTools) {
      if (tool.name == 'find_tools') continue;
      if (!discoveredNames.contains(tool.name)) continue;
      if (session.discoveredToolNames.contains(tool.name)) continue;

      session.discoveredToolNames.add(tool.name);
      session.discoveredTools.add(tool.toJson());
    }

    if (kDebugMode) {
      debugPrint(
        '[ToolDiscovery] Discovered: '
        '${session.discoveredToolNames.join(', ')}',
      );
    }
  }

  String _buildSystemPrompt({
    required String? baseSystemPrompt,
    required bool isToolResult,
    required bool discoveryMode,
    required List<Map<String, dynamic>> discoveredTools,
  }) {
    final tools = _toolExecutor.allTools.map((t) => t.toJson()).toList();
    final promptBuilder = ToolPromptBuilder(discoveryMode: discoveryMode);
    final toolProtocol = promptBuilder
        .buildToolProtocolSection(
          tools: tools,
          isToolResult: isToolResult,
          discoveredTools: discoveredTools,
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
    final providerReasoning = reasoning.trim();
    if (providerReasoning.isNotEmpty) {
      return providerReasoning;
    }

    final preToolText = _extractPreToolText(content).trim();
    if (preToolText.isEmpty) {
      return null;
    }

    return preToolText;
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

  List<Map<String, dynamic>> _cloneHistory(List<Map<String, dynamic>> history) {
    return history.map((m) => Map<String, dynamic>.from(m)).toList();
  }

  List<ToolCall> _cloneToolCalls(List<ToolCall> calls) {
    return calls.map((c) => ToolCall.fromJson(c.toJson())).toList();
  }
}
