import 'dart:convert';

import 'package:chuk_chat/utils/artifact_tag_parser.dart';

const String toolCallStart = '<tool_call>';
const String toolCallEnd = '</tool_call>';

final RegExp _xmlToolCallBlockPattern = RegExp(
  r'<tool_call>[\s\S]*?</tool_call>',
  caseSensitive: false,
);
final RegExp _xmlDirectToolTagBlockPattern = RegExp(
  r'<([a-zA-Z][a-zA-Z0-9_]*_[a-zA-Z0-9_]+)>\s*([\s\S]*?)\s*</\1>',
  caseSensitive: false,
);
final RegExp _xmlToolCallStartPattern = RegExp(
  r'<tool_call>',
  caseSensitive: false,
);
// Kimi-style structured tool-call section tokens, e.g.
// `<|tool_calls_section_begin|>` / `<|tool_call_begin|>`. Matched from the
// opener so an incomplete token mid-stream still signals a tool round.
final RegExp _kimiToolCallStartPattern = RegExp(
  r'<\|tool_calls?(?:_section)?_begin',
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
// The app prepends a `<previous_tool_results>…</previous_tool_results>` block
// to the assistant `content` it feeds back to the model (see
// tool_history_formatter.dart). The model sees its own prior turns starting
// with that tag and sometimes echoes it verbatim into its visible output —
// occasionally with a doubled `<<` opener, and occasionally fabricating a
// fake tool result in place of a real call. Strip the echoed block (and any
// mid-stream opener) so it never renders as raw protocol text. `<+` tolerates
// the doubled opener; the close tag is matched leniently too.
final RegExp _previousToolResultsBlockPattern = RegExp(
  r'<+\s*previous_tool_results\s*>[\s\S]*?<\s*/\s*previous_tool_results\s*>',
  caseSensitive: false,
);
final RegExp _previousToolResultsStartPattern = RegExp(
  r'<+\s*previous_tool_results\b',
  caseSensitive: false,
);
// ---------------------------------------------------------------------------
// Foreign tool-call protocols.
//
// This app speaks exactly one wire format: `<tool_call>{json}</tool_call>`.
// Providers do not agree on how a model's native tool call is serialised into
// the text stream, so the same model behaves differently per provider — one
// passes the native tokens straight through, another rewrites them, a third
// emits an entirely different XML dialect. Anything we neither parse nor
// recognise used to render verbatim in the chat.
//
// These patterns are deliberately DETECTION-ONLY: the payload is removed from
// the visible text and `hasToolCallStartMarker` reports a tool round, which
// makes the malformed-protocol recovery in ToolCallHandler re-prompt for the
// canonical form. Guessing at the arguments and executing them would be worse
// than asking the model again.
//
// Every match is ignored inside fenced/inline code so a conversation *about*
// these formats is never mangled.

// Tag names of the dialects seen in the wild. The `s?` covers singular and
// plural (`<tool_call>` vs `<tool_calls>`).
const String _foreignToolTagNames =
    r'(?:tool_calls?|toolcalls?|function_calls?|invoke)';

// Optional `minimax:` style prefix, on the opener and independently on the
// closer — emitters are usually symmetric, but nothing guarantees it.
const String _foreignToolTagNamespace = r'(?:[a-zA-Z][a-zA-Z0-9_.-]*\s*:\s*)?';

// Keeps the bare, un-namespaced `<tool_call>` out of the foreign matcher —
// that is this app's own canonical format, handled by the patterns above.
// `<minimax:tool_call>` and `<tool_calls>` are unaffected.
const String _notCanonicalToolCallTag = r'(?!tool_call\b)(?!toolcall\b)';

// `<tool_calls>`, `<minimax:tool_call>`, `<function_call>`, `<invoke …>` …
// with the matching close tag. Group 1 is the bare tag name, so the closer
// matches with or without a namespace.
final RegExp _foreignToolProtocolBlockPattern = RegExp(
  '<\\s*$_notCanonicalToolCallTag$_foreignToolTagNamespace'
  '($_foreignToolTagNames)\\b[^>]*>'
  r'[\s\S]*?'
  '<\\s*/\\s*$_foreignToolTagNamespace\\1\\s*>',
  caseSensitive: false,
);

// `<invoke name="x">…</invoke>` with `<parameter name="k">v</parameter>`
// children — MiniMax-M2's documented native format, usually wrapped in
// `<minimax:tool_call>`. Unlike the dialects above this one is unambiguous, so
// it is parsed into real calls instead of triggering a re-prompt.
//
// Known limit (vllm-project/vllm#44060): a `</parameter>` sequence inside an
// argument value truncates that value, because the closer is matched
// non-greedily. The format has no escaping for it.
final RegExp _invokeToolCallPattern = RegExp(
  '<\\s*$_foreignToolTagNamespace'
  // `\b` before `name`: without it the non-greedy scan happily matches the
  // tail of an unrelated attribute such as `displayname="…"` and captures the
  // wrong tool name — which would then be executed.
  r'''invoke\b[^>]*?\bname\s*=\s*["']([^"']+)["'][^>]*>'''
  r'([\s\S]*?)'
  '<\\s*/\\s*$_foreignToolTagNamespace'
  r'invoke\s*>',
  caseSensitive: false,
);
final RegExp _invokeParameterPattern = RegExp(
  '<\\s*$_foreignToolTagNamespace'
  r'''parameter\b[^>]*?\bname\s*=\s*["']([^"']+)["'][^>]*>'''
  r'([\s\S]*?)'
  '<\\s*/\\s*$_foreignToolTagNamespace'
  r'parameter\s*>',
  caseSensitive: false,
);

// Opener of any of the above, plus provider-specific plain-text markers:
// Mistral `[TOOL_CALLS]`, Llama `<|python_tag|>`, DeepSeek's full-width
// `<｜tool▁calls▁begin｜>` (U+FF5C pipes, U+2581 separators).
final RegExp _foreignToolProtocolStartPattern = RegExp(
  '<\\s*$_notCanonicalToolCallTag$_foreignToolTagNamespace'
  '$_foreignToolTagNames\\b'
  r'|\[TOOL_CALLS\]'
  r'|<[|｜]\s*(?:python_tag|tool[▁_ ]?calls?)',
  caseSensitive: false,
);

const Set<String> _knownDirectXmlToolNames = <String>{
  'ask_user',
  'web_search',
  'web_crawl',
  'generate_image',
  'fetch_image',
  'view_chat_images',
  'search_places',
  'search_restaurants',
  'get_route',
  'search_chats',
  'google_calendar',
  'random_number',
  'flip_coin',
  'roll_dice',
  'password_generator',
  'uuid_generator',
  'artifact_manager',
  'artifact_schema',
  'update_project',
  'typst_compile',
};

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
      _markdownToolCallStartPattern.hasMatch(content) ||
      _kimiToolCallStartPattern.hasMatch(content) ||
      _earliestDirectXmlToolStart(content) != -1 ||
      hasForeignToolProtocolMarker(content);
}

/// True when the text carries a tool-call protocol this app does not parse
/// (another provider's dialect). Code spans are excluded, so prose *about*
/// these formats does not count.
bool hasForeignToolProtocolMarker(String content) {
  final codeRanges = _codeSpanRanges(content);
  return _firstMatchOutsideCode(
        _foreignToolProtocolStartPattern,
        content,
        codeRanges,
      ) !=
      null;
}

/// Start/end offsets of fenced blocks and inline code spans.
///
/// An unterminated fence extends to end-of-string: mid-stream, a half-arrived
/// code block must stay protected until its closer shows up.
List<({int start, int end})> _codeSpanRanges(String content) {
  final ranges = <({int start, int end})>[];

  var search = 0;
  while (true) {
    final open = content.indexOf('```', search);
    if (open == -1) break;
    final close = content.indexOf('```', open + 3);
    if (close == -1) {
      ranges.add((start: open, end: content.length));
      // `break`, not `return`: inline spans *before* this still-open fence
      // must be collected too. Mid-stream this is a common state — prose
      // mentioning `<tool_calls>` inline, then a code block still arriving.
      break;
    }
    ranges.add((start: open, end: close + 3));
    search = close + 3;
  }

  for (final match in RegExp(r'`[^`\n]*`').allMatches(content)) {
    if (ranges.any((r) => match.start >= r.start && match.start < r.end)) {
      continue;
    }
    ranges.add((start: match.start, end: match.end));
  }

  return ranges;
}

bool _isInsideCode(int index, List<({int start, int end})> codeRanges) {
  for (final range in codeRanges) {
    if (index >= range.start && index < range.end) return true;
  }
  return false;
}

Match? _firstMatchOutsideCode(
  RegExp pattern,
  String content,
  List<({int start, int end})> codeRanges,
) {
  for (final match in pattern.allMatches(content)) {
    if (!_isInsideCode(match.start, codeRanges)) return match;
  }
  return null;
}

/// Removes foreign tool-call protocol text so it never reaches the user.
///
/// Complete blocks are cut out; with [stripIncomplete] an unterminated opener
/// truncates the rest, exactly like the canonical `<tool_call>` handling.
String _stripForeignToolProtocol(
  String content, {
  required bool stripIncomplete,
}) {
  var cleaned = content;

  // Blocks are removed one at a time: every removal shifts the offsets, so the
  // code-span ranges have to be recomputed against the current string.
  while (true) {
    final match = _firstMatchOutsideCode(
      _foreignToolProtocolBlockPattern,
      cleaned,
      _codeSpanRanges(cleaned),
    );
    if (match == null) break;
    cleaned = cleaned.replaceRange(match.start, match.end, '');
  }

  if (stripIncomplete) {
    final opener = _firstMatchOutsideCode(
      _foreignToolProtocolStartPattern,
      cleaned,
      _codeSpanRanges(cleaned),
    );
    if (opener != null) {
      cleaned = cleaned.substring(0, opener.start);
    }
  }

  return cleaned;
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
      .replaceAll(_markdownToolCallBlockPattern, '')
      .replaceAll(_previousToolResultsBlockPattern, '');
  cleaned = cleaned.replaceAllMapped(_xmlDirectToolTagBlockPattern, (match) {
    final tagName = (match.group(1) ?? '').trim().toLowerCase();
    if (_isKnownDirectXmlToolName(tagName)) {
      return '';
    }
    return match.group(0) ?? '';
  });

  // Also strip inline <artifact> blocks — they are rendered as inline
  // artifact cards (mirroring artifact_manager tool-call output), not as
  // raw text. Keeping them in view would show the protocol XML.
  cleaned = stripArtifactTagsForDisplay(
    cleaned,
    stripIncomplete: stripIncomplete,
  );

  // Deny-by-default: a tool-call dialect we cannot parse is still protocol,
  // never prose. Removing it here keeps it out of the UI; the matching marker
  // in `hasToolCallStartMarker` makes ToolCallHandler re-prompt for the
  // canonical `<tool_call>` form instead of leaving the user an empty turn.
  cleaned = _stripForeignToolProtocol(
    cleaned,
    stripIncomplete: stripIncomplete,
  );

  if (stripIncomplete) {
    // Match the full opening tag (already-streamed) AND any partial open like
    // `<tool_call` mid-stream, so we never flash protocol text in the UI.
    // The tag has no alternate forms in this codebase, so any occurrence of
    // `<tool_call` is always tool protocol — safe to truncate from there.
    final xmlPartialIdx = _earliestCaseInsensitiveIndex(cleaned, '<tool_call');
    if (xmlPartialIdx != -1) {
      cleaned = cleaned.substring(0, xmlPartialIdx);
    }

    final directToolStartIdx = _earliestDirectXmlToolStart(cleaned);
    if (directToolStartIdx != -1) {
      cleaned = cleaned.substring(0, directToolStartIdx);
    }

    // Same for the markdown form: a fenced block starting with
    // ```tool_call / ```toolcall / ```tool-call (or any in-flight prefix
    // thereof, e.g. just ```too).
    final markdownPartialIdx = _earliestMarkdownToolCallStart(cleaned);
    if (markdownPartialIdx != -1) {
      cleaned = cleaned.substring(0, markdownPartialIdx);
    }

    // A `<previous_tool_results>` opener with no matching close is an echoed
    // scaffolding tag still streaming in (or one whose close never arrived) —
    // truncate from it so the protocol block never flashes into view.
    final prevResultsStart = _previousToolResultsStartPattern.firstMatch(
      cleaned,
    );
    if (prevResultsStart != null) {
      cleaned = cleaned.substring(0, prevResultsStart.start);
    }

    // Kimi K2.x (Fireworks) emits native tool calls wrapped in special
    // tokens like `<|tool_calls_section_begin|>`. The structured calls are
    // surfaced separately by the v2 multiplex path, but the leading `<` (and
    // sometimes a partial `<|…` token) leaks into the content stream. Strip
    // complete special-token blocks, any trailing partial token, and a bare
    // dangling `<` so it never renders as a stray `<` text block above the
    // tool-call bar.
    // Full-width pipes (U+FF5C) included: DeepSeek writes `<｜tool▁calls▁begin｜>`.
    cleaned = cleaned.replaceAll(RegExp(r'<[|｜][^>]*[|｜]>'), '');
    cleaned = cleaned.replaceFirst(RegExp(r'<[|｜][^>]*$'), '');
    // One or more `<` left dangling at the very end are tag-opener fragments
    // (start of `<tool_call>` / `<|…|>` that were split or server-stripped),
    // never real prose. A multiplex with several tool-call sections can leak
    // more than one — e.g. `…verschlüsselt.\n\n<\n<` — so strip the whole
    // trailing run, not just the last `<`. Mid-text `<` (e.g. "a < b") is
    // preserved because the run must reach end-of-string.
    cleaned = cleaned.replaceFirst(RegExp(r'(?:<\s*)+$'), '');
  }

  // A line consisting solely of `<` characters is never real prose — it is a
  // dangling tag-opener fragment (the leading `<` of a `<|tool_calls_section_…`
  // special token whose remainder the server already stripped). In a multi-pass
  // Kimi stream these land *between* prose blocks, so the end-anchored trailing
  // strip above misses them. Drop such lines unconditionally so they vanish
  // from cached/finalised messages too. Mid-prose `<` (e.g. `a < b`) is kept
  // because the line must begin with `<` to match.
  // Trailing blank lines left by the junk run are swallowed too so the prose
  // on either side rejoins with a single separator rather than a widening gap.
  cleaned = cleaned.replaceAll(
    RegExp(r'^[ \t]*<+[ \t]*\r?$\n?(?:[ \t]*\r?\n)*', multiLine: true),
    '',
  );

  return cleaned.trim();
}

int _earliestCaseInsensitiveIndex(String haystack, String needle) {
  return haystack.toLowerCase().indexOf(needle.toLowerCase());
}

int _earliestMarkdownToolCallStart(String content) {
  final lower = content.toLowerCase();
  var search = 0;
  while (true) {
    final fence = lower.indexOf('```', search);
    if (fence == -1) return -1;
    final after = lower.substring(fence + 3);
    if (after.startsWith('tool_call') ||
        after.startsWith('toolcall') ||
        after.startsWith('tool-call') ||
        // In-flight prefix of any of the above (e.g. ```too).
        ('tool_call'.startsWith(after) && after.isNotEmpty) ||
        ('toolcall'.startsWith(after) && after.isNotEmpty) ||
        ('tool-call'.startsWith(after) && after.isNotEmpty)) {
      return fence;
    }
    search = fence + 3;
  }
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

  for (final match in _xmlDirectToolTagBlockPattern.allMatches(content)) {
    final tagName = (match.group(1) ?? '').trim();
    final normalizedName = tagName.toLowerCase();
    if (!_isKnownDirectXmlToolName(normalizedName)) {
      continue;
    }

    final inner = (match.group(2) ?? '').trim();
    final args = _parseDirectXmlToolArgs(inner);
    indexedCalls.add((
      index: match.start,
      call: <String, dynamic>{'name': normalizedName, 'arguments': args},
    ));
  }

  // Code spans are excluded here, not just in the display strip: an example
  // of the format inside a fence must never be executed as a real call.
  final codeRanges = _codeSpanRanges(content);
  for (final match in _invokeToolCallPattern.allMatches(content)) {
    if (_isInsideCode(match.start, codeRanges)) continue;

    final name = (match.group(1) ?? '').trim();
    if (name.isEmpty) continue;

    final args = <String, dynamic>{};
    for (final param in _invokeParameterPattern.allMatches(
      match.group(2) ?? '',
    )) {
      final key = (param.group(1) ?? '').trim();
      if (key.isEmpty) continue;
      args[key] = _decodeInvokeParameterValue(param.group(2) ?? '');
    }

    indexedCalls.add((
      index: match.start,
      call: <String, dynamic>{'name': name, 'arguments': args},
    ));
  }

  indexedCalls.sort((a, b) => a.index.compareTo(b.index));
  return indexedCalls.map((entry) => entry.call).toList();
}

/// `<parameter>` bodies are untyped text. Only unambiguous JSON shapes are
/// decoded — an object, an array, a bare number, or a literal true/false/null.
/// Everything else stays a string, so a query like `null and void` or a
/// house number is not silently retyped.
dynamic _decodeInvokeParameterValue(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';

  final looksStructural = value.startsWith('{') || value.startsWith('[');
  final looksLiteral =
      value == 'true' ||
      value == 'false' ||
      value == 'null' ||
      RegExp(r'^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$').hasMatch(value);
  if (!looksStructural && !looksLiteral) return value;

  try {
    return jsonDecode(value);
  } catch (_) {
    return value;
  }
}

/// Check if the content contains any tool call tags.
bool hasToolCalls(String content) {
  if (_xmlToolCallBlockPattern.hasMatch(content)) {
    return true;
  }

  final hasDirectXmlTool = _xmlDirectToolTagBlockPattern
      .allMatches(content)
      .any(
        (match) => _isKnownDirectXmlToolName(
          (match.group(1) ?? '').trim().toLowerCase(),
        ),
      );
  if (hasDirectXmlTool) {
    return true;
  }

  if (_markdownToolCallBlockPattern.hasMatch(content)) {
    return true;
  }

  final codeRanges = _codeSpanRanges(content);
  return _firstMatchOutsideCode(_invokeToolCallPattern, content, codeRanges) !=
      null;
}

bool _isKnownDirectXmlToolName(String tagName) {
  return tagName.isNotEmpty && _knownDirectXmlToolNames.contains(tagName);
}

Map<String, dynamic> _parseDirectXmlToolArgs(String inner) {
  if (inner.isEmpty) {
    return <String, dynamic>{};
  }

  final parsed =
      tryParseToolJson(inner) ??
      _extractEmbeddedToolJson(inner) ??
      _parseLegacyToolCallSyntax(inner);

  if (parsed == null) {
    return <String, dynamic>{};
  }

  final rawArgs = parsed['arguments'] ?? parsed['args'];
  if (rawArgs != null) {
    return _coerceStringKeyedMap(rawArgs);
  }

  final valueOnly = <String, dynamic>{};
  for (final entry in parsed.entries) {
    if (entry.key == 'name' ||
        entry.key == 'arguments' ||
        entry.key == 'args') {
      continue;
    }
    valueOnly[entry.key] = entry.value;
  }
  return valueOnly;
}

int _earliestDirectXmlToolStart(String content) {
  for (final match in RegExp(
    r'<([a-zA-Z][a-zA-Z0-9_]*_[a-zA-Z0-9_]+)\b',
    caseSensitive: false,
  ).allMatches(content)) {
    final tagName = (match.group(1) ?? '').trim().toLowerCase();
    if (_isKnownDirectXmlToolName(tagName)) {
      return match.start;
    }
  }
  return -1;
}
