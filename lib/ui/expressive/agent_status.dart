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
///  * "Active now" with no dot when it is idle and simply available.
///
/// Every one of those comes from something the app observes: [CoworkAgent
/// .activity] and the run the [CoworkRunLedger] tracks for the thread. Nothing
/// here invents a status.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/ui/expressive/working_dots.dart';

/// What one running tool is called, in words a reader recognises. The host's
/// tool names are snake_case ids (`read_file`, `browser_click`); this only
/// makes them readable, it never renames them into something they are not.
String humanToolLabel(String rawName) {
  final String name = rawName.trim();
  if (name.isEmpty) return 'working';
  final String spaced = name.replaceAll('_', ' ').replaceAll('-', ' ');
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
  });

  final CoworkAgent agent;

  /// The thread whose run is read for the work in progress. Null falls back to
  /// the coworker's own `running` flag.
  final String? sessionKey;

  /// Injectable for tests; defaults to the process-wide ledger.
  final CoworkRunLedger? ledger;

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final CoworkRunLedger source = ledger ?? CoworkRunLedger.instance;
    return AnimatedBuilder(
      animation: source,
      builder: (BuildContext context, Widget? _) {
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
            : const Color(0xFF34C759);
        // Idle is still "active": a coworker is reachable whenever the host is,
        // so the dot stays, and the words say there is nothing running.
        final String label = work ?? 'Active now';

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
      },
    );
  }

  /// A coworker has one permanent session, and its key is the thread's key.
  String _defaultSessionKey() =>
      agent.threads.isEmpty ? '' : agent.threads.first.key;
}
