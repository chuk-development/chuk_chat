// lib/services/tool_pairing_validator.dart
//
// Native tool calling needs a strict shape in the history: every id in an
// assistant message's `tool_calls` is answered by exactly one `role: "tool"`
// message right after it, and no tool message answers a call that is not
// there. One broken pair and the upstream rejects the whole request with a
// 400, so the turn dies. The helpers here repair the history before it is
// sent instead.

/// The text of the tool result added for a call that never got one.
const String kUnansweredToolCallResult =
    'Error: this tool call got no result (it was not run or its result was '
    'lost).';

/// A copy of [history] that native tool calling accepts:
///
/// * A tool message with no matching call in the assistant message right
///   before it (an orphan) is dropped.
/// * A call with no tool message gets one, with [kUnansweredToolCallResult].
/// * A call id used twice (in one message or across rounds) is renamed with a
///   `_2`, `_3`, ... suffix. The tool messages that answer it follow in
///   order, so the first answer for that id goes to the first call and the
///   next one to the renamed call.
/// * A call with no id gets one, which then counts as unanswered.
///
/// Messages without tool data pass through unchanged. The input is not
/// modified.
List<Map<String, dynamic>> validateToolPairing(
  List<Map<String, dynamic>> history,
) {
  final out = <Map<String, dynamic>>[];
  final usedIds = <String>{};
  var i = 0;
  while (i < history.length) {
    final message = history[i];
    final role = message['role'];
    final rawCalls = message['tool_calls'];

    if (role == 'tool') {
      // Not right after an assistant message with tool calls: an orphan.
      i++;
      continue;
    }
    if (role != 'assistant' || rawCalls is! List || rawCalls.isEmpty) {
      out.add(message);
      i++;
      continue;
    }

    // Original id -> the ids it was given in this message, in call order.
    final pendingByOriginal = <String, List<String>>{};
    final callIds = <String>[];
    final calls = <dynamic>[];
    for (final raw in rawCalls) {
      if (raw is! Map) {
        continue;
      }
      final call = Map<String, dynamic>.from(raw);
      final original = (call['id'] ?? '').toString();
      final id = uniqueToolCallId(
        original.isEmpty ? 'call_${usedIds.length}' : original,
        usedIds,
      );
      call['id'] = id;
      calls.add(call);
      callIds.add(id);
      (pendingByOriginal[original] ??= <String>[]).add(id);
    }
    if (calls.isEmpty) {
      // Only junk entries: keep the text of the message, drop the calls.
      final copy = Map<String, dynamic>.from(message)..remove('tool_calls');
      final content = copy['content'];
      if (content is String && content.trim().isNotEmpty) out.add(copy);
      i++;
      continue;
    }
    out.add(Map<String, dynamic>.from(message)..['tool_calls'] = calls);

    // The tool messages that follow answer these calls.
    final answered = <String>{};
    var j = i + 1;
    while (j < history.length && history[j]['role'] == 'tool') {
      final result = history[j];
      final original = (result['tool_call_id'] ?? '').toString();
      final queue = pendingByOriginal[original];
      if (queue != null && queue.isNotEmpty) {
        final id = queue.removeAt(0);
        answered.add(id);
        out.add(Map<String, dynamic>.from(result)..['tool_call_id'] = id);
      }
      // No open call with that id: an orphan or a second answer. Dropped.
      j++;
    }
    for (final id in callIds) {
      if (answered.contains(id)) continue;
      out.add(<String, dynamic>{
        'role': 'tool',
        'tool_call_id': id,
        'content': kUnansweredToolCallResult,
      });
    }
    i = j;
  }
  return out;
}

/// [base] when it is not in [used], else `base_2`, `base_3`, ... The id
/// returned is added to [used].
String uniqueToolCallId(String base, Set<String> used) {
  var id = base;
  var n = 2;
  while (used.contains(id)) {
    id = '${base}_$n';
    n++;
  }
  used.add(id);
  return id;
}
