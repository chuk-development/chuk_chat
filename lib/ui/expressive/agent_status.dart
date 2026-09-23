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
/// Every one of those comes from something the app observes: [AgentsAgent
/// .activity], the run the [AgentsRunLedger] tracks for the thread, and the
/// bound transport's own state. Nothing here invents a status.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/ui/expressive/working_dots.dart';

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
String? workInProgressLabel(AgentsAgent agent, AgentsRun? run) {
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

/// The dot's diameter as a fraction of the font size it sits next to.
///
/// 0.55 em is the x-height of the app's text face: the dot is exactly as tall
/// as a lower-case letter, so it reads as a bullet ON the line and not as a
/// badge parked beside it.
const double kStatusDotSizeFactor = 0.55;

/// The single gap between the dot and its words.
const double kStatusDotGap = 6;

/// The presence dot of a status line, on ONE optical line with its words.
///
/// Two rules do the whole job, and they are what keeps the line from drifting
/// when the text scaler grows:
///
///  * the diameter is the text's x-height ([kStatusDotSizeFactor] of the
///    SCALED font size), so the dot grows with the words;
///  * its bottom edge sits ON the alphabetic baseline, which leaves its centre
///    half an x-height above the baseline — the middle of the lower-case
///    letters, which is where the eye reads the line.
///
/// The second rule needs the parent to be a `Row` with
/// [CrossAxisAlignment.baseline] and [TextBaseline.alphabetic]. A circle has no
/// baseline of its own and Flutter then drops it at the top of the row, so
/// [_BaselinedBox] lends it one at its bottom edge and the row does the rest.
/// Centring the dot in the row instead (the old way) centres it on the LINE
/// BOX, which sits about a tenth of the font size above the middle of the
/// letters: visible at 11 px, and it drifts further as the text grows.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, required this.fontSize});

  final Color color;

  /// The unscaled font size of the words beside it.
  final double fontSize;

  /// The painted diameter in [context].
  static double sizeIn(BuildContext context, double fontSize) =>
      MediaQuery.textScalerOf(context).scale(fontSize) * kStatusDotSizeFactor;

  @override
  Widget build(BuildContext context) {
    final double size = sizeIn(context, fontSize);
    return _BaselinedBox(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// A box whose baseline is its own bottom edge.
class _BaselinedBox extends SingleChildRenderObjectWidget {
  const _BaselinedBox({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBaselinedBox();
}

class _RenderBaselinedBox extends RenderProxyBox {
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => size.height;

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryLayout(constraints).height;
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

  final AgentsAgent agent;

  /// The thread whose run is read for the work in progress. Null falls back to
  /// the coworker's own `running` flag.
  final String? sessionKey;

  /// Injectable for tests; defaults to the process-wide ledger.
  final AgentsRunLedger? ledger;

  final double fontSize;

  /// The bound transport, for the reachability half of the line. Injectable for
  /// tests; defaults to the process-wide link.
  final AgentsRelayLink? link;

  @override
  Widget build(BuildContext context) {
    final AgentsRunLedger source = ledger ?? AgentsRunLedger.instance;
    final AgentsRelayLink transport = link ?? AgentsRelayLink.instance;
    return AnimatedBuilder(
      animation: source,
      builder: (BuildContext context, Widget? _) =>
          ValueListenableBuilder<AgentsRelayController?>(
            valueListenable: transport.controller,
            builder:
                (BuildContext context, AgentsRelayController? controller, _) {
                  if (controller == null) {
                    return _line(context, source, paired: false);
                  }
                  return ValueListenableBuilder<AgentsRelayState>(
                    valueListenable: controller.state,
                    builder:
                        (BuildContext context, AgentsRelayState state, _) =>
                            _line(context, source, paired: state.isPaired),
                  );
                },
          ),
    );
  }

  Widget _line(
    BuildContext context,
    AgentsRunLedger source, {
    required bool paired,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String key = sessionKey ?? _defaultSessionKey();
    final AgentsRun? run = key.isEmpty ? null : source.runFor(key);
    final String? work = workInProgressLabel(agent, run);
    final bool working =
        agent.activity == AgentActivity.working || (run?.running ?? false);
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
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        StatusDot(color: dotColor, fontSize: fontSize),
        const SizedBox(width: kStatusDotGap),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: working ? scheme.primary : scheme.onSurfaceVariant,
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
