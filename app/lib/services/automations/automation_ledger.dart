import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

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
  CoworkRelayAutomation event, {
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
String automationEventText(CoworkRelayAutomation event) {
  final a = event.automation;
  final what = '${a.name} (${a.specLabel})';
  switch (event.event) {
    case 'created':
      return a.isWatcher ? 'Watcher started: $what' : 'Scheduled: $what';
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
    default:
      return '${event.event}: $what';
  }
}
