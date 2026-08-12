// lib/widgets/agent_activity/agent_activity_timeline.dart
//
// The agent's work, shown the way a reader wants it: every step visible
// while it happens, folded into one line ("Worked for 13s") once the
// answer is there. No box, no chrome — a thin rail and muted text, so the
// answer stays the loudest thing on screen.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';

class AgentActivityTimeline extends StatefulWidget {
  const AgentActivityTimeline({
    super.key,
    required this.toolCalls,
    this.steps,
    this.isRunning = false,
    this.clock,
    this.initiallyExpanded,
    this.onStepTap,
  });

  /// The round's calls, in the order the model made them. Drives the
  /// duration, and the lines when [steps] is null.
  final List<ToolCall> toolCalls;

  /// The round as it happened, with reasoning between the calls. Pass this
  /// when the order matters; otherwise the lines come from [toolCalls].
  final List<AgentActivityStep>? steps;

  /// Whether the round is still going. While true the timeline stays open
  /// and the header counts up.
  final bool isRunning;

  /// Injectable clock. Tests pass a fixed value so the counting header is
  /// deterministic; production leaves it null and reads [DateTime.now].
  final DateTime Function()? clock;

  /// Overrides the default open/closed state (open while running, closed
  /// once finished).
  final bool? initiallyExpanded;

  /// Called when a reader taps a single step, to show its arguments and
  /// result. Group headers and thinking notes are not tappable — they
  /// stand for several calls or none. Leave null to make steps inert.
  final void Function(ToolCall toolCall)? onStepTap;

  @override
  State<AgentActivityTimeline> createState() => _AgentActivityTimelineState();
}

class _AgentActivityTimelineState extends State<AgentActivityTimeline> {
  /// Null until the reader taps: before that the state follows the round.
  bool? _expandedOverride;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _expandedOverride = widget.initiallyExpanded;
    _syncTicker();
  }

  @override
  void didUpdateWidget(AgentActivityTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRunning != widget.isRunning) {
      // Finishing a round returns to the default (folded), unless the
      // reader already made a choice.
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// The header counts seconds, so it needs a repaint per second — but
  /// only while the round runs.
  void _syncTicker() {
    _ticker?.cancel();
    if (!widget.isRunning) {
      _ticker = null;
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  bool get _isExpanded => _expandedOverride ?? widget.isRunning;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  Widget build(BuildContext context) {
    if (widget.toolCalls.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final steps = widget.steps;
    final entries = steps == null
        ? buildAgentActivityEntries(widget.toolCalls)
        : buildAgentActivityEntriesFromSteps(steps);
    final duration = agentActivityDuration(widget.toolCalls, now: _now);

    return SelectionContainer.disabled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(theme, muted, duration),
          if (_isExpanded) ...[
            const SizedBox(height: 6),
            ...entries.map((entry) => _buildEntry(theme, muted, entry)),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, Color muted, Duration? duration) {
    final label = duration == null
        ? (widget.isRunning ? 'Working' : 'Worked')
        : widget.isRunning
        ? 'Working for ${formatAgentDuration(duration)}'
        : 'Worked for ${formatAgentDuration(duration)}';

    return Semantics(
      button: true,
      expanded: _isExpanded,
      label: label,
      child: InkWell(
        onTap: () => setState(() => _expandedOverride = !_isExpanded),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              // Points down when open, right when folded — the same
              // affordance Grok uses, and it survives a text-only reading
              // through the Semantics `expanded` flag above.
              Icon(
                _isExpanded
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 16,
                color: muted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(
    ThemeData theme,
    Color muted,
    AgentActivityEntry entry, {
    bool isChild = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: isChild ? 22 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEntryRow(theme, muted, entry, isChild: isChild),
          ...entry.children.map(
            (child) => _buildEntry(theme, muted, child, isChild: true),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryRow(
    ThemeData theme,
    Color muted,
    AgentActivityEntry entry, {
    required bool isChild,
  }) {
    final Color color = entry.hasError
        ? theme.colorScheme.error.withValues(alpha: 0.8)
        : muted;

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_iconFor(entry), size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildEntryText(theme, entry, color, isChild: isChild),
          ),
        ],
      ),
    );

    final call = entry.toolCall;
    final onTap = widget.onStepTap;
    if (call == null || onTap == null) return row;

    return InkWell(
      onTap: () => onTap(call),
      borderRadius: BorderRadius.circular(6),
      child: row,
    );
  }

  Widget _buildEntryText(
    ThemeData theme,
    AgentActivityEntry entry,
    Color color, {
    required bool isChild,
  }) {
    final baseStyle = theme.textTheme.bodySmall?.copyWith(color: color);
    final detail = entry.detail;

    if (detail == null) {
      return Text(entry.label, style: baseStyle);
    }

    // The query or URL is the part worth reading, so it gets a monospace
    // face and a touch more contrast than the verb in front of it.
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '${entry.label} ', style: baseStyle),
          TextSpan(
            text: detail,
            style: baseStyle?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  IconData _iconFor(AgentActivityEntry entry) {
    switch (entry.kind) {
      case AgentActivityKind.search:
        return Icons.search;
      case AgentActivityKind.page:
        return Icons.language;
      case AgentActivityKind.thinking:
        return Icons.lightbulb_outline;
      case AgentActivityKind.other:
        return Icons.bolt_outlined;
    }
  }
}
