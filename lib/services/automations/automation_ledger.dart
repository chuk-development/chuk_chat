import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// The transcript line of one automation: ONE [ToolCall] per automation id,
/// updated on every event (last event wins), the same mapping for the live
/// ledger and the replay loader — as `subagentCallFromRelay` does for a
/// child agent (docs/WIRE_CONTRACT.md, "Automations").
///
/// The card is informational: the buttons live on the thread's strip and on
/// the Automations page, where the current state is known. Here the line
/// says what happened and when.
ToolCall automationCallFromRelay(
  ToolCall? existing,
  AgentsRelayAutomation event, {
  DateTime? now,
}) {
  final automation = event.automation;
  final call =
      existing ??
      ToolCall(
        name: 'automation',
        arguments: <String, dynamic>{
          'id': automation.id,
          'kind': automation.kind,
          'name': automation.name,
          'spec': automation.specLabel,
        },
        status: ToolCallStatus.running,
      );
  call.arguments['event'] = event.event;
  call.arguments['state'] = automation.state;
  call.arguments['fire_count'] = automation.fireCount;
  if (event.runId != null) call.arguments['run_id'] = event.runId;
  if (event.reason != null) call.arguments['reason'] = event.reason;
  // `result` tags the run it closes: the thread can fold a quiet run to one
  // line (docs/WIRE_CONTRACT.md, "Notify only on change").
  if (event.event == 'result') {
    call.arguments['changed'] = event.changed ?? true;
    if (event.summary != null) {
      call.arguments['summary'] = event.summary;
    } else {
      call.arguments.remove('summary');
    }
  }
  call.arguments['notify'] = automation.notify;
  if (automation.unchangedCount > 0) {
    call.arguments['unchanged_count'] = automation.unchangedCount;
  } else {
    call.arguments.remove('unchanged_count');
  }
  call.result = automationEventText(event);
  if (automation.isOver) {
    call.status = automation.state == 'failed'
        ? ToolCallStatus.error
        : ToolCallStatus.completed;
    call.completedAt = now ?? event.at ?? DateTime.now();
  } else {
    call.status = ToolCallStatus.running;
  }
  return call;
}

/// One line of English for an automation event, for the transcript card.
String automationEventText(AgentsRelayAutomation event) {
  final a = event.automation;
  final what = '${a.name} (${a.specLabel})';
  switch (event.event) {
    case 'created':
      return switch (a.kind) {
        'watcher' => 'Watcher started: $what',
        'watch_url' => 'Watching a page: $what',
        'mail' => 'Watching mail: $what',
        _ => 'Scheduled: $what',
      };
    case 'fired':
      final reason = event.reason;
      return reason == null || reason.isEmpty
          ? 'Fired: $what'
          : 'Fired: $what — $reason';
    case 'paused':
      return 'Paused: $what';
    case 'resumed':
      return 'Resumed: $what';
    case 'cancelled':
      return 'Cancelled: $what';
    case 'failed':
      final error = a.lastError;
      return error == null ? 'Failed: $what' : 'Failed: $what — $error';
    case 'done':
      return 'Finished: $what';
    case 'updated':
      return 'Edited: $what';
    case 'result':
      final summary = event.summary;
      if (event.changed == false) {
        return summary == null
            ? 'No change: $what'
            : 'No change: $what — $summary';
      }
      if (event.reported == false) return 'Ran, no report: $what';
      return summary == null ? 'Changed: $what' : 'Changed: $what — $summary';
    default:
      return '${event.event}: $what';
  }
}
