import 'dart:convert';

const String toolCallStart = '<tool_call>';
const String toolCallEnd = '</tool_call>';

final RegExp _xmlToolCallBlockPattern = RegExp(
  r'<tool_call>[\s\S]*?</tool_call>',
  caseSensitive: false,
);
final RegExp _xmlToolCallStartPattern = RegExp(
  r'<tool_call>',
  caseSensitive: false,
);
final RegExp _markdownToolCallBlockPattern = RegExp(
  r'```(?:tool_call|toolcall|tool-call)\s*([\s\S]*?)```',
  caseSensitive: false,
);
final RegExp _markdownToolCallStartPattern = RegExp(
  r'```(?:tool_call|toolcall|tool-call)\b',
  caseSensitive: false,
);

/// Try to parse JSON from a tool call, with repair for common LLM errors:
/// - Missing closing braces: {"name":"x","arguments":{"q":"y"}
/// - Trailing commas: {"name":"x",}
/// - Whitespace / newlines inside the tag
Map<String, dynamic>? tryParseToolJson(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  // First try: parse as-is
  try {
    return jsonDecode(s) as Map<String, dynamic>;
  } catch (_) {}

  // Repair: add missing closing braces, ignoring braces inside strings.
  final unclosedBraces = _countUnclosedBracesOutsideStrings(s);
  if (unclosedBraces > 0) {
    s = s + ('}' * unclosedBraces);
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {}
  }

  // Repair: remove trailing commas before } or ]
  final cleaned = s.replaceAllMapped(
    RegExp(r',\s*([}\]])'),
    (m) => m.group(1)!,
  );
  if (cleaned != s) {
    try {
      return jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {}
  }

  // Give up
  return null;
}

Map<String, dynamic>? _parseLegacyToolCallSyntax(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;

  // Format:
  // <tool_name>web_search</tool_name>
  // <args_query>...</args_query>
  final toolNameTag = RegExp(
    r'<tool_name>\s*([^<]+?)\s*</tool_name>',
    caseSensitive: false,
  ).firstMatch(s);
  if (toolNameTag != null) {
    final name = toolNameTag.group(1)?.trim();
    if (name == null || name.isEmpty) return null;

    final args = <String, dynamic>{};
    final argTagPattern = RegExp(
      r'<args_([a-zA-Z0-9_]+)>\s*([\s\S]*?)\s*</args_\1>',
      caseSensitive: false,
    );
    for (final match in argTagPattern.allMatches(s)) {
      final key = match.group(1)?.trim();
      final value = match.group(2)?.trim();
      if (key != null && key.isNotEmpty && value != null) {
        args[key] = value;
      }
    }

    return {'name': name, 'arguments': args};
  }

  // Format:
  // <tool name="web_search", "arguments": {"query": "..."}>
  final toolTagName = RegExp(
    r'<tool\s+name\s*=\s*"([^"]+)"',
    caseSensitive: false,
  ).firstMatch(s);
  if (toolTagName != null) {
    final name = toolTagName.group(1)?.trim();
    if (name == null || name.isEmpty) return null;

    final args = _extractInlineArgumentsObject(s) ?? <String, dynamic>{};
    return {'name': name, 'arguments': args};
  }

  return null;
}

Map<String, dynamic>? _extractEmbeddedToolJson(String raw) {
  var searchStart = 0;
  while (true) {
    final braceStart = raw.indexOf('{', searchStart);
    if (braceStart == -1) return null;

    final candidate = _extractBalancedObject(raw, braceStart);
    if (candidate == null) {
      searchStart = braceStart + 1;
      continue;
    }

    try {
      final parsed = jsonDecode(candidate);
      if (parsed is Map<String, dynamic> && parsed.containsKey('name')) {
        return parsed;
      }
    } catch (_) {}

    searchStart = braceStart + 1;
  }
}

Map<String, dynamic>? _extractInlineArgumentsObject(String s) {
  final markerMatch = RegExp(
    r'''["']arguments["']\s*:\s*''',
    caseSensitive: false,
  ).firstMatch(s);
  if (markerMatch == null) return null;

  final braceStart = s.indexOf('{', markerMatch.end);
  if (braceStart == -1) return null;

  final objectStr = _extractBalancedObject(s, braceStart);
  if (objectStr == null) return null;

  try {
    final parsed = jsonDecode(objectStr);
    if (parsed is Map<String, dynamic>) return parsed;
  } catch (_) {}

  return null;
}

String? _extractBalancedObject(String s, int startIndex) {
  if (startIndex < 0 || startIndex >= s.length || s[startIndex] != '{') {
    return null;
  }

  int depth = 0;
  bool inString = false;
  bool escaped = false;

  for (int i = startIndex; i < s.length; i++) {
    final ch = s[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }

    if (ch == '"') {
      inString = true;
      continue;
    }

    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return s.substring(startIndex, i + 1);
      }
    }
  }

  return null;
}

int _countUnclosedBracesOutsideStrings(String s) {
  int depth = 0;
  bool inString = false;
  bool escaped = false;

  for (int i = 0; i < s.length; i++) {
    final ch = s[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }

    if (ch == '"') {
      inString = true;
      continue;
    }

    if (ch == '{') {
      depth++;
      continue;
    }

    if (ch == '}') {
      if (depth > 0) {
        depth--;
      }
    }
  }

  return depth;
}

Map<String, dynamic> _coerceStringKeyedMap(dynamic rawArgs) {
  if (rawArgs is Map<String, dynamic>) {
    return rawArgs;
  }
  if (rawArgs is! Map) {
    return <String, dynamic>{};
  }

  final args = <String, dynamic>{};
  try {
    for (final entry in rawArgs.entries) {
      final key = entry.key;
      if (key is String) {
        args[key] = entry.value;
      } else if (key != null) {
        args[key.toString()] = entry.value;
      }
    }
  } catch (_) {
    return <String, dynamic>{};
  }
  return args;
}

/// Returns true when a response has started emitting a tool-call marker,
/// including incomplete blocks during token streaming.
bool hasToolCallStartMarker(String content) {
  return _xmlToolCallStartPattern.hasMatch(content) ||
      _markdownToolCallStartPattern.hasMatch(content);
}

/// Removes tool-call XML/markdown blocks from user-visible text.
///
/// When [stripIncomplete] is true, incomplete blocks are removed from the
/// first opening marker onward to prevent raw protocol text from flashing in UI
/// while streaming.
String stripToolCallBlocksForDisplay(
  String content, {
  bool stripIncomplete = true,
}) {
  var cleaned = content
      .replaceAll(_xmlToolCallBlockPattern, '')
      .replaceAll(_markdownToolCallBlockPattern, '');

  if (stripIncomplete) {
    final xmlStart = _xmlToolCallStartPattern.firstMatch(cleaned)?.start;
    if (xmlStart != null) {
      cleaned = cleaned.substring(0, xmlStart);
    }

    final markdownStart = _markdownToolCallStartPattern
        .firstMatch(cleaned)
        ?.start;
    if (markdownStart != null) {
      cleaned = cleaned.substring(0, markdownStart);
    }
  }

  return cleaned.trim();
}

/// Parse ALL tool calls from LLM response content (supports multiple).
/// Includes JSON repair for common LLM mistakes (missing braces, etc.).
List<Map<String, dynamic>> parseToolCalls(
  String content, {
  bool allowMarkdownToolCalls = true,
}) {
  final indexedCalls = <({int index, Map<String, dynamic> call})>[];

  Map<String, dynamic>? normalizeCall(Map<String, dynamic> data) {
    if (!data.containsKey('name')) return null;

    final nameRaw = data['name'];
    final name = nameRaw is String ? nameRaw.trim() : '';
    if (name.isEmpty) {
      return null;
    }

    final rawArgs = data['arguments'] ?? data['args'];
    final args = _coerceStringKeyedMap(rawArgs);
    return {'name': name, 'arguments': args};
  }

  int searchStart = 0;

  while (true) {
    final startIdx = content.indexOf(toolCallStart, searchStart);
    if (startIdx == -1) break;

    final endIdx = content.indexOf(toolCallEnd, startIdx);
    if (endIdx == -1) break;

    final jsonStr = content
        .substring(startIdx + toolCallStart.length, endIdx)
        .trim();

    final data =
        tryParseToolJson(jsonStr) ??
        _extractEmbeddedToolJson(jsonStr) ??
        _parseLegacyToolCallSyntax(jsonStr);
    if (data != null) {
      final normalized = normalizeCall(data);
      if (normalized != null) {
        indexedCalls.add((index: startIdx, call: normalized));
      }
    }

    searchStart = endIdx + toolCallEnd.length;
  }

  if (allowMarkdownToolCalls) {
    for (final match in _markdownToolCallBlockPattern.allMatches(content)) {
      final inner = (match.group(1) ?? '').trim();
      if (inner.isEmpty) continue;

      // Avoid duplicating XML-tag based calls that are already parsed above.
      if (inner.contains(toolCallStart) && inner.contains(toolCallEnd)) {
        continue;
      }

      final data =
          tryParseToolJson(inner) ??
          _extractEmbeddedToolJson(inner) ??
          _parseLegacyToolCallSyntax(inner);
      if (data == null) continue;

      final normalized = normalizeCall(data);
      if (normalized != null) {
        indexedCalls.add((index: match.start, call: normalized));
      }
    }
  }

  indexedCalls.sort((a, b) => a.index.compareTo(b.index));
  return indexedCalls.map((entry) => entry.call).toList();
}

/// Check if the content contains any tool call tags.
bool hasToolCalls(String content) {
  if (_xmlToolCallBlockPattern.hasMatch(content)) {
    return true;
  }

  return _markdownToolCallBlockPattern.hasMatch(content);
}
