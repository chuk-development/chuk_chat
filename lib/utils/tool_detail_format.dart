// lib/utils/tool_detail_format.dart
//
// How a tool's arguments and result are shown when the reader opens a step.
//
// Both arrive as strings, and both are frequently not prose. A tool that
// answers with JSON hands over one unbroken line — the Canva design search
// returns four candidates as a single 800-character blob — and a tool that
// takes a brief is handed markdown, which then shows as `**Presentation
// Brief**` with the asterisks. Neither is readable, and both are cheap to
// tell apart from plain text.

import 'dart:convert';

/// How a tool-detail body should be shown.
enum ToolBodyKind {
  /// Plain text, shown as it is.
  text,

  /// JSON, shown indented.
  json,

  /// Markdown, shown rendered.
  markdown,
}

/// A tool body together with how to show it.
class ToolBody {
  const ToolBody(this.kind, this.text);

  final ToolBodyKind kind;

  /// The text to show. For [ToolBodyKind.json] this is the indented form,
  /// otherwise the original.
  final String text;
}

/// Markers that only appear in text meant to be rendered: a heading, a
/// bullet, bold, a fenced block, a link, a table row. One is not enough —
/// a lone asterisk is a wildcard as often as it is emphasis — so a body
/// counts as markdown only when two different markers are present.
final List<RegExp> _markdownMarkers = [
  RegExp(r'^#{1,6}\s+\S', multiLine: true),
  RegExp(r'^\s*[-*+]\s+\S', multiLine: true),
  RegExp(r'^\s*\d+\.\s+\S', multiLine: true),
  RegExp(r'\*\*\S[\s\S]*?\S\*\*'),
  RegExp(r'```'),
  RegExp(r'\[[^\]]+\]\([^)]+\)'),
  RegExp(r'^\s*\|.+\|\s*$', multiLine: true),
  RegExp(r'^\s*>\s+\S', multiLine: true),
];

/// Decide how [raw] should be shown, and hand back the text to show.
///
/// JSON wins over markdown: a JSON document full of markdown strings is
/// still a JSON document, and indenting it is what makes the markdown
/// inside it visible in the first place.
ToolBody classifyToolBody(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return ToolBody(ToolBodyKind.text, raw);

  final pretty = prettyJsonOrNull(trimmed);
  if (pretty != null) return ToolBody(ToolBodyKind.json, pretty);

  final markers = _markdownMarkers.where((r) => r.hasMatch(raw)).length;
  if (markers >= 2) return ToolBody(ToolBodyKind.markdown, raw);

  return ToolBody(ToolBodyKind.text, raw);
}

/// [raw] indented, or null when it is not a JSON object or array.
///
/// Only objects and arrays count. A bare `42` or `"hello"` is valid JSON
/// too, but showing it as a JSON document would be a lie about what the
/// tool returned — those are just a number and a string.
String? prettyJsonOrNull(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length < 2) return null;
  final first = trimmed[0];
  if (first != '{' && first != '[') return null;

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map && decoded is! List) return null;
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } on FormatException {
    // Tools also return prose that happens to start with a brace, and
    // truncated results that were valid until they were cut.
    return null;
  }
}
