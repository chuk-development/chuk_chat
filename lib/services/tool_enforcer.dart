/// Client-side Tool Call Enforcer (inspired by Kimi K2's Enforcer).
///
/// Validates every tool call the model emits BEFORE execution:
///  - Rejects calls to tools not in the declared tool set
///  - Validates argument keys against expected parameters
///  - Detects hallucinated tool output blocks
///  - Assigns globally-unique IDs: functions.{name}:{idx}
///  - Enforces a max-iterations safety limit on the agentic loop
///  - Strips any content after the last tool_call closing tag
class ToolEnforcer {
  /// Global call index -- increments across the entire conversation,
  /// matching Kimi K2's `functions.func_name:idx` scheme.
  int _globalCallIndex = 0;

  /// Current tool-loop iteration for the active user turn.
  int _currentIteration = 0;

  /// Maximum tool-loop rounds before the enforcer forces a stop.
  final int maxIterations;

  /// Set of currently declared tool names (updated each turn).
  Set<String> _declaredTools = {};

  /// Parameter schemas keyed by tool name.
  Map<String, Map<String, dynamic>> _toolSchemas = {};

  /// Discovery mode: when true, only find_tools + discovered tools accepted.
  bool discoveryMode = false;

  /// Tools discovered via find_tools (names only). Updated externally.
  Set<String> discoveredToolNames = {};

  ToolEnforcer({this.maxIterations = 100});

  // ─────────────────────────────────────────────────────────────────────────
  // Configuration
  // ─────────────────────────────────────────────────────────────────────────

  /// Update the declared tool set.
  void setDeclaredTools(List<Map<String, dynamic>> tools) {
    _declaredTools = {};
    _toolSchemas = {};
    for (final tool in tools) {
      final name = tool['name'] as String?;
      if (name == null) continue;
      _declaredTools.add(name);
      final params = _coerceMap(tool['parameters']);
      if (params.isNotEmpty) {
        final props = _coerceMap(params['properties']);
        if (props.isNotEmpty) {
          _toolSchemas[name] = props;
        }
      }
    }
  }

  /// Reset iteration counter -- call at the start of every new user message.
  void resetIteration() {
    _currentIteration = 0;
  }

  /// Full reset (new conversation).
  void reset() {
    _globalCallIndex = 0;
    _currentIteration = 0;
    _declaredTools = {};
    _toolSchemas = {};
    discoveryMode = false;
    discoveredToolNames = {};
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Enforcer core
  // ─────────────────────────────────────────────────────────────────────────

  /// Check the raw LLM response for hallucinated output blocks.
  HallucinationCheckResult checkForHallucination(String content) {
    final warnings = <String>[];
    var cleaned = content;

    // 1. Detect <tool_call_output>...</tool_call_output>
    final outputPattern = RegExp(
      r'<tool_call_output>.*?</tool_call_output>',
      dotAll: true,
    );
    if (outputPattern.hasMatch(cleaned)) {
      warnings.add('Stripped hallucinated <tool_call_output> block(s)');
      cleaned = cleaned.replaceAll(outputPattern, '');
    }

    // 2. Detect suspicious standalone result-like JSON objects outside
    //    <tool_call> tags. Keep pattern conservative to avoid false positives
    //    for legitimate nested payloads.
    final fakeResultPattern = RegExp(
      r'(^|\n)\s*\{\s*"(?:tool_result|result)"\s*:\s*'
      r'(?:"[^"]*"|\{[^{}]*\})\s*\}\s*($|\n)',
      multiLine: true,
    );
    if (fakeResultPattern.hasMatch(cleaned)) {
      warnings.add('Detected possible hallucinated result JSON in response');
    }

    // 3. Detect the model continuing with text after the last </tool_call>
    final lastEnd = cleaned.lastIndexOf('</tool_call>');
    if (lastEnd != -1) {
      final afterToolCalls = cleaned
          .substring(lastEnd + '</tool_call>'.length)
          .trim();
      if (afterToolCalls.isNotEmpty && afterToolCalls.length > 20) {
        warnings.add(
          'Model continued generating ${afterToolCalls.length} chars after '
          'last </tool_call> -- stripped trailing content',
        );
        cleaned = cleaned.substring(0, lastEnd + '</tool_call>'.length);
      }
    }

    return HallucinationCheckResult(
      cleanedContent: cleaned,
      warnings: warnings,
      hadHallucination: warnings.isNotEmpty,
    );
  }

  /// Validate and enrich a list of parsed tool calls.
  EnforcerResult enforce(List<Map<String, dynamic>> parsedCalls) {
    _currentIteration++;

    final valid = <EnforcedToolCall>[];
    final rejected = <RejectedToolCall>[];

    // Check iteration limit
    if (_currentIteration > maxIterations) {
      rejected.addAll(
        parsedCalls.map(
          (c) => RejectedToolCall(
            name: c['name'] as String? ?? 'unknown',
            arguments: _coerceMap(c['arguments']),
            reason: 'Max iterations ($maxIterations) exceeded -- forcing stop',
          ),
        ),
      );
      return EnforcerResult(
        validCalls: [],
        rejectedCalls: rejected,
        iterationLimitReached: true,
        currentIteration: _currentIteration,
      );
    }

    for (final call in parsedCalls) {
      final name = call['name'] as String? ?? '';
      final args = _coerceMap(call['arguments']);

      // 1. Check tool exists in declared set
      if (!_declaredTools.contains(name)) {
        rejected.add(
          RejectedToolCall(
            name: name,
            arguments: args,
            reason:
                'Tool "$name" not in declared tool set: '
                '${_declaredTools.join(", ")}',
          ),
        );
        continue;
      }

      // 1b. In discovery mode, only find_tools + notes + ask_user +
      //     discovered tools are allowed without discovery.
      if (discoveryMode &&
          name != 'find_tools' &&
          name != 'notes' &&
          name != 'ask_user' &&
          !discoveredToolNames.contains(name)) {
        rejected.add(
          RejectedToolCall(
            name: name,
            arguments: args,
            reason:
                'Discovery mode: call find_tools first to discover "$name". '
                'Only find_tools and already-discovered tools are allowed.',
          ),
        );
        continue;
      }

      // 1c. find_tools query must stay short and categorical.
      if (name == 'find_tools') {
        final validationError = _validateFindToolsArgs(args);
        if (validationError != null) {
          rejected.add(
            RejectedToolCall(
              name: name,
              arguments: args,
              reason: validationError,
            ),
          );
          continue;
        }
      }

      // 2. Validate argument keys (warn on unexpected keys, don't reject)
      final schema = _toolSchemas[name];
      final argWarnings = <String>[];
      if (schema != null && args.isNotEmpty) {
        for (final key in args.keys) {
          if (!schema.containsKey(key)) {
            argWarnings.add('Unexpected arg "$key" for tool "$name"');
          }
        }
      }

      // 3. Assign Kimi-style global ID
      final callId = 'functions.$name:$_globalCallIndex';
      _globalCallIndex++;

      valid.add(
        EnforcedToolCall(
          callId: callId,
          name: name,
          arguments: args,
          warnings: argWarnings,
        ),
      );
    }

    return EnforcerResult(
      validCalls: valid,
      rejectedCalls: rejected,
      iterationLimitReached: false,
      currentIteration: _currentIteration,
    );
  }

  String? _validateFindToolsArgs(Map<String, dynamic> args) {
    final query = (args['query'] ?? '').toString().trim();
    if (query.isEmpty) {
      return 'find_tools requires a "query" argument with 1-3 short '
          'category keywords. Example: '
          '{"name": "find_tools", "arguments": {"query": "qr code"}}';
    }

    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length > 3 || query.length > 40) {
      return 'find_tools query must be 1-3 short category keywords '
          '(e.g. "qr", "web search", "restaurant", "spotify", "email"). '
          'Do not pass the full user request.';
    }

    final lowered = words.map((w) => w.toLowerCase()).toList();
    const visualWords = {
      'chart',
      'charts',
      'graph',
      'graphs',
      'plot',
      'diagram',
      'map',
      'maps',
      'karte',
      'karten',
    };
    final isVisualOnly =
        lowered.isNotEmpty && lowered.every((w) => visualWords.contains(w));
    if (isVisualOnly) {
      return 'find_tools is for DATA tools, not visual rendering tags. '
          'Do not search for chart/map tools. Discover data tools and then '
          'output <chart>/<map> directly in the final response text.';
    }

    return null;
  }

  /// Build the structured result message to send back to the model.
  String buildResultMessage(List<ToolCallResult> results) {
    final buffer = StringBuffer();
    buffer.writeln('Tool Results:');
    for (final r in results) {
      buffer.writeln('[${r.callId}] ${r.name}: ${r.result}');
    }
    return buffer.toString().trimRight();
  }

  Map<String, dynamic> _coerceMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      try {
        return Map<String, dynamic>.from(value);
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    return <String, dynamic>{};
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data classes
// ─────────────────────────────────────────────────────────────────────────────

class HallucinationCheckResult {
  final String cleanedContent;
  final List<String> warnings;
  final bool hadHallucination;

  const HallucinationCheckResult({
    required this.cleanedContent,
    required this.warnings,
    required this.hadHallucination,
  });
}

class EnforcedToolCall {
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;
  final List<String> warnings;

  const EnforcedToolCall({
    required this.callId,
    required this.name,
    required this.arguments,
    this.warnings = const [],
  });
}

class RejectedToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final String reason;

  const RejectedToolCall({
    required this.name,
    required this.arguments,
    required this.reason,
  });
}

class EnforcerResult {
  final List<EnforcedToolCall> validCalls;
  final List<RejectedToolCall> rejectedCalls;
  final bool iterationLimitReached;
  final int currentIteration;

  const EnforcerResult({
    required this.validCalls,
    required this.rejectedCalls,
    required this.iterationLimitReached,
    required this.currentIteration,
  });

  bool get hasValidCalls => validCalls.isNotEmpty;
  bool get hasRejections => rejectedCalls.isNotEmpty;
}

class ToolCallResult {
  final String callId;
  final String name;
  final String result;
  final bool isError;

  const ToolCallResult({
    required this.callId,
    required this.name,
    required this.result,
    this.isError = false,
  });
}
