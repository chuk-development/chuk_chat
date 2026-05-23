import 'dart:convert';

import 'package:chuk_chat/utils/tool_sanitizer.dart';

// Per-result and per-message caps for prior tool-call context. Past tool
// results bloat fast (search results often >10k chars each), so cap
// aggressively while still preserving enough to be useful as context.
const int _maxResultChars = 4000;
const int _maxTotalChars = 16000;

/// Builds the assistant `content` string for one stored message, optionally
/// prepending a `<previous_tool_results>` block so the model can reuse the
/// data it already fetched instead of re-running the same tools.
///
/// Returns null when there is no content to send (empty text, no tool calls).
String? formatAssistantContent(
  Map<String, String> message, {
  bool includeReasoning = false,
}) {
  final text = (message['text'] ?? '').trim();
  if (text == 'Thinking...') {
    return null;
  }

  final toolBlock = _buildPreviousToolResultsBlock(message['toolCalls']);
  final reasoning = includeReasoning ? (message['reasoning'] ?? '') : '';

  final buf = StringBuffer();
  if (toolBlock.isNotEmpty) {
    buf.writeln(toolBlock);
    buf.writeln();
  }
  if (reasoning.isNotEmpty) {
    buf
      ..writeln('<thinking>')
      ..writeln(reasoning)
      ..writeln('</thinking>')
      ..writeln();
  }
  if (text.isNotEmpty) {
    buf.write(text);
  }

  final result = buf.toString().trimRight();
  return result.isEmpty ? null : result;
}

String _buildPreviousToolResultsBlock(String? toolCallsJson) {
  if (toolCallsJson == null || toolCallsJson.isEmpty) {
    return '';
  }

  final List<dynamic> decoded;
  try {
    final parsed = jsonDecode(toolCallsJson);
    if (parsed is! List) return '';
    decoded = parsed;
  } catch (_) {
    return '';
  }

  final lines = <String>[];
  var totalChars = 0;
  for (final raw in decoded) {
    if (raw is! Map) continue;
    final status = (raw['status'] as String?)?.toLowerCase() ?? '';
    if (status != 'completed' && status != 'error') continue;

    final name = (raw['name'] as String? ?? '').trim();
    final result = (raw['result'] as String?)?.trim() ?? '';
    if (name.isEmpty || result.isEmpty) continue;

    final args = raw['arguments'];
    final argsStr = args is Map ? jsonEncode(args) : '';

    final sanitized = sanitizeResultForModel(result);
    final truncated = sanitized.length > _maxResultChars
        ? '${sanitized.substring(0, _maxResultChars)}... [truncated]'
        : sanitized;

    final line = argsStr.isEmpty
        ? '[$name] result: $truncated'
        : '[$name] args: $argsStr | result: $truncated';

    totalChars += line.length;
    if (totalChars > _maxTotalChars) {
      lines.add('... [further tool results omitted to stay within size limits]');
      break;
    }
    lines.add(line);
  }

  if (lines.isEmpty) return '';

  return '<previous_tool_results>\n${lines.join('\n')}\n</previous_tool_results>';
}
