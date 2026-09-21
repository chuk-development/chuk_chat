import 'dart:convert';

/// The message shown when the socket to the API cannot be opened.
///
/// It is a notice about the transport, not part of the answer, but it is
/// stored in the assistant message's own `text` because there is no separate
/// error field. "Continue generation" then resumes from that body, so without
/// stripping it the notice is carried into the next attempt — and appended
/// again on the next failure, which is how one bubble ended up showing it
/// twice in front of the real answer.
const String kConnectionErrorNotice =
    'Could not establish a connection to the server. '
    'Please check your internet connection and try again.';

/// Removes the transport error notice from [text], wherever it sits.
///
/// Only this exact notice is removed. A generic `Error: …` line is left
/// alone: an answer may legitimately begin or end with one, and dropping it
/// would rewrite what the model wrote.
String stripStreamErrorNotice(String text) {
  if (text.isEmpty) return text;
  // The desktop error path stores the notice wrapped as "Error: <notice>";
  // the wrapped form goes first, or the bare replacement leaves "Error: "
  // behind and the row still looks resumable.
  final String out = text
      .replaceAll('Error: $kConnectionErrorNotice', '')
      .replaceAll(kConnectionErrorNotice, '');
  return out
      .split('\n')
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// The same cleanup for a stored content-block list.
///
/// A text block that held nothing but the notice is dropped; the rest keep
/// their order, so the blocks still describe the same turn.
String? stripStreamErrorNoticeFromBlocksJson(String? blocksJson) {
  if (blocksJson == null || blocksJson.trim().isEmpty) return blocksJson;
  final dynamic decoded;
  try {
    decoded = jsonDecode(blocksJson);
  } on FormatException {
    return blocksJson;
  }
  if (decoded is! List) return blocksJson;

  final List<dynamic> kept = <dynamic>[];
  for (final dynamic block in decoded) {
    if (block is! Map) {
      kept.add(block);
      continue;
    }
    final String type = (block['type'] ?? 'text').toString();
    if (type != 'text') {
      kept.add(block);
      continue;
    }
    final String cleaned = stripStreamErrorNotice(
      (block['text'] ?? block['content'] ?? '').toString(),
    );
    if (cleaned.isEmpty) continue;
    final Map<String, dynamic> copy = Map<String, dynamic>.from(block);
    if (copy.containsKey('text')) {
      copy['text'] = cleaned;
    } else {
      copy['content'] = cleaned;
    }
    kept.add(copy);
  }

  if (kept.isEmpty) return null;
  return jsonEncode(kept);
}
