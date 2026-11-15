import 'dart:convert';

import 'package:chuk_chat/models/chat_stream_event.dart';

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

/// Shown when the server answered this request before but kept no copy of
/// the answer (a `duplicate` with `truncated: true` and no content). A new
/// send makes a new request.
const String kAnswerUnavailableNotice =
    'This message was already answered, but the answer could not be '
    'restored. Send it again for a new answer.';

/// Shown when the server still writes the answer to this request after the
/// app asked several times.
const String kAnswerPendingNotice =
    'The server is still writing this answer. Try again in a moment.';

/// The alert type of the note a failed turn ends with. The answer-block
/// parser draws `> [!INTERRUPTED]` as an error card (`_AlertBlock`); no model
/// writes it, so it can be found and removed again exactly.
const String kTurnErrorAlertType = 'INTERRUPTED';

/// The stored form of a turn error: an alert block, so the bubble shows a
/// card with an icon instead of the error as if it were the answer.
String turnErrorNote(String friendly) {
  final String body = friendly
      .trim()
      .split('\n')
      .map((String l) => '> $l')
      .join('\n');
  return '> [!$kTurnErrorAlertType]\n$body';
}

final RegExp _turnErrorNoteRe = RegExp(
  r'(^|\n)> \[!' + kTurnErrorAlertType + r'\][^\n]*(\n>[^\n]*)*',
);

/// What the reader is told when a turn ends on [message] with [code].
///
/// The raw text of a transport failure ("WebSocket connection failed:
/// SocketException: Failed host lookup ...") says nothing to a reader and
/// was shown as if it were the answer. Transport failures get one plain
/// sentence; a server message (already written for people) stays, without
/// an "Error: " prefix.
String userFacingStreamError(String message, {String? code}) {
  final String lower = message.toLowerCase();
  final bool transport =
      code == StreamErrorCodes.connectionLost ||
      lower.contains('socketexception') ||
      lower.contains('websocket') ||
      lower.contains('failed host lookup') ||
      lower.contains('handshakeexception') ||
      lower.contains('connection lost') ||
      lower.contains('connection closed') ||
      lower.contains('network is unreachable');
  if (transport) {
    return 'No connection to the server. The answer could not be finished. '
        'Tap Retry when you are online again.';
  }
  switch (code) {
    case StreamErrorCodes.idleTimeout:
      return 'The server stopped answering. Tap Retry to ask again.';
    case StreamErrorCodes.streamInterrupted:
    case StreamErrorCodes.upstreamInterrupted:
    case StreamErrorCodes.streamFailure:
      return 'The answer broke off before it finished. Tap Retry to ask '
          'again.';
    case StreamErrorCodes.requestPending:
      return kAnswerPendingNotice;
  }
  String out = message.trim();
  if (out.startsWith('Error: ')) out = out.substring(7).trim();
  return out.isEmpty ? 'Something went wrong. Tap Retry to ask again.' : out;
}

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
      .replaceAll(_turnErrorNoteRe, '')
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
