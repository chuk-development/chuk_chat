/// Rows nobody typed (docs/WIRE_CONTRACT.md, "Typed source on synthetic
/// rows"): a goal round, a fired schedule, a job wake, a mail, the plan-mode
/// rules, a loaded skill, a settled subagent, the background review.
///
/// They are stored like the transcript's other rows, so a reload keeps them:
///  * a user row with a source keeps it in `inputMode` as
///    `agents_source:<source>`;
///  * a runtime context row rides on the answer it belongs to as one
///    synthetic `agents_context` call.
///
/// The list item reads both back with [agentsRowSource] and
/// [splitAgentsContext] and draws a small chip instead of a user bubble or a
/// tool line.
library;

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// The tool name of a typed-source context row (docs/WIRE_CONTRACT.md,
/// "Typed source on synthetic rows"). It rides on the answer as a synthetic
/// call; the list item lifts it off and draws it as a small chip, never as a
/// tool line or a user bubble.
const String kAgentsContextToolName = 'agents_context';

/// The `inputMode` of a user row nobody typed (`agents_source:<source>`). The
/// row is stored like any user row; the list item draws it as a chip.
const String kAgentsSourceInputModePrefix = 'agents_source:';

/// The source a user row was written by, or null for a row the user typed.
String? agentsRowSource(Map<String, String> row) {
  final String? mode = row['inputMode'];
  if (mode == null || !mode.startsWith(kAgentsSourceInputModePrefix)) {
    return null;
  }
  final String source = mode.substring(kAgentsSourceInputModePrefix.length);
  return source.isEmpty ? null : source;
}

/// The renderer's shape of one context row, live or replayed — ONE mapping.
ToolCall contextCallFromRelay(AgentsRelayContext event, {DateTime? now}) {
  final DateTime at = event.sentAt ?? now ?? DateTime.now();
  return ToolCall(
    name: kAgentsContextToolName,
    arguments: <String, dynamic>{'source': event.source, 'text': event.text},
    status: ToolCallStatus.completed,
    startedAt: at,
  )..completedAt = at;
}

/// [calls] without the context calls, and the context calls in order. The
/// same lists come back when there is none, so a plain row costs nothing.
({List<ToolCall> rest, List<({String source, String text})> context})
splitAgentsContext(List<ToolCall> calls) {
  if (!calls.any((ToolCall c) => c.name == kAgentsContextToolName)) {
    return (rest: calls, context: const <({String source, String text})>[]);
  }
  final List<ToolCall> rest = <ToolCall>[];
  final List<({String source, String text})> context =
      <({String source, String text})>[];
  for (final ToolCall call in calls) {
    if (call.name != kAgentsContextToolName) {
      rest.add(call);
      continue;
    }
    final Object? source = call.arguments['source'];
    final Object? text = call.arguments['text'];
    if (source is String && source.isNotEmpty) {
      context.add((source: source, text: text is String ? text : ''));
    }
  }
  return (rest: rest, context: context);
}
