/// "Active now" — the line under a coworker's name, and what it says here.
///
/// A messenger writes "Active now" under a person's name when they have the app
/// open. A coworker does not sleep: it is reachable whenever the host is, so the
/// interesting question is not "is it there" but "what is it doing right now".
/// So the line is
///
///  * a green dot and the work in progress while a run is in flight — the tool
///    it is running, or the task the host says it picked up;
///  * an amber dot and "Scheduled" when it carries a schedule and waits for it;
///  * a green dot and "Active now" when it is idle on a paired host;
///  * a grey dot and "Not connected" when there is no transport. A coworker is
///    reachable whenever the host is — but if this device cannot reach the
///    host, saying "Active now" would send the reader looking for an answer
///    that cannot arrive.
///
/// Every one of those comes from something the app observes: [CoworkAgent
/// .activity], the run the [CoworkRunLedger] tracks for the thread, and the
/// bound transport's own state. Nothing here invents a status.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/ui/expressive/working_dots.dart';

/// What one running tool is called, in words a reader recognises. The host's
/// tool names are ids (`read_file`, `mcp__playwright__browser_navigate`); this
/// only makes them readable, it never renames them into something they are not.
String humanToolLabel(String rawName) {
  String name = rawName.trim();
  if (name.isEmpty) return 'working';
  // An MCP tool carries its server in the id: keep the tool, drop the routing.
  final RegExpMatch? mcp = RegExp(r'^mcp__.+?__(.+)$').firstMatch(name);
  if (mcp != null) name = mcp.group(1)!;
  final String spaced = name
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (spaced.isEmpty) return 'working';
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// The words for the status line, or null while the coworker is simply idle
/// (the caller then writes "Active now").
///
/// [run] is the ledger's record for this coworker's thread, if any.
String? workInProgressLabel(CoworkAgent agent, CoworkRun? run) {
  if (agent.activity == AgentActivity.scheduled) return 'Scheduled';
  final bool running = agent.running || (run?.running ?? false);
  if (!running) return null;

  // The tool that is open right now beats everything else: it is the most
  // precise true statement about what the coworker is doing.
  if (run != null) {
    for (final ToolCall call in run.toolCalls.reversed) {
      if (call.status == ToolCallStatus.running) {
        return humanToolLabel(call.name);
      }
    }
    // A run this client did not start: the host says what it picked up.
    final String? prompt = run.detachedPrompt?.trim();
    if (prompt != null && prompt.isNotEmpty) {
      return prompt.length <= 42 ? prompt : '${prompt.substring(0, 41)}…';
    }
  }
  return 'working';
}

/// The line itself: the dot, and the words next to it.
class AgentStatusLine extends StatelessWidget {
  const AgentStatusLine({
    super.key,
    required this.agent,
    this.sessionKey,
    this.ledger,
    this.fontSize = 11,
    this.link,
  });

  final CoworkAgent agent;

  /// The thread whose run is read for the work in progress. Null falls back to
  /// the coworker's own `running` flag.
  final String? sessionKey;

  /// Injectable for tests; defaults to the process-wide ledger.
  final CoworkRunLedger? ledger;

  final double fontSize;

  /// The bound transport, for the reachability half of the line. Injectable for
  /// tests; defaults to the process-wide link.
  final CoworkRelayLink? link;

  @override
  Widget build(BuildContext context) {
    final CoworkRunLedger source = ledger ?? CoworkRunLedger.instance;
    final CoworkRelayLink transport = link ?? CoworkRelayLink.instance;
    return AnimatedBuilder(
      animation: source,
      builder: (BuildContext context, Widget? _) =>
          ValueListenableBuilder<CoworkRelayController?>(
            valueListenable: transport.controller,
            builder: (BuildContext context, CoworkRelayController? controller, _) {
              if (controller == null) {
                return _line(context, source, paired: false);
              }
              return ValueListenableBuilder<CoworkRelayState>(
                valueListenable: controller.state,
                builder: (BuildContext context, CoworkRelayState state, _) =>
                    _line(context, source, paired: state.isPaired),
              );
            },
          ),
    );
  }

  Widget _line(
    BuildContext context,
    CoworkRunLedger source, {
    required bool paired,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String key = sessionKey ?? _defaultSessionKey();
    final CoworkRun? run = key.isEmpty ? null : source.runFor(key);
    final String? work = workInProgressLabel(agent, run);
    final bool working = agent.activity == AgentActivity.working ||
        (run?.running ?? false);
    final bool scheduled =
        !working && agent.activity == AgentActivity.scheduled;

    final Color dotColor = working
        ? const Color(0xFF34C759)
        : scheduled
        ? const Color(0xFFFF9F0A)
        : paired
        ? const Color(0xFF34C759)
        : scheme.onSurfaceVariant.withValues(alpha: 0.5);
    // Idle on a paired host is still "active": a coworker does not go to
    // sleep. Without a transport the line says so instead.
    final String label = work ?? (paired ? 'Active now' : 'Not connected');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: working
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
              fontSize: fontSize,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (working) ...<Widget>[
          const SizedBox(width: 4),
          WorkingDots(color: scheme.primary, label: ''),
        ],
      ],
    );
  }

  /// A coworker has one permanent session, and its key is the thread's key.
  String _defaultSessionKey() =>
      agent.threads.isEmpty ? '' : agent.threads.first.key;
}
