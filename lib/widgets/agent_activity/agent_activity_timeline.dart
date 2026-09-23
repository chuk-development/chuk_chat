// lib/widgets/agent_activity/agent_activity_timeline.dart
//
// The agent's work as a rail: one step per line, a thin line connecting
// them, and under each search the pages it found as chips. Folded to a
// single "Worked for 13s" once the answer is there, so a finished turn
// reads as answer-first and the work is one tap away.

import 'dart:async';

import 'package:flutter/material.dart';


import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/utils/favicon.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/turn_status.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

class AgentActivityTimeline extends StatefulWidget {
  const AgentActivityTimeline({
    super.key,
    required this.toolCalls,
    this.steps,
    this.isRunning = false,
    this.clock,
    this.initiallyExpanded,
    this.onStepTap,
    this.onSourceTap,
    this.footer,
    this.phase,
    this.startedAt,
    this.finalDuration,
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

  /// Called when a reader taps a step, to show its arguments and result.
  /// Thinking notes are not tappable — they stand for no call.
  final void Function(ToolCall toolCall)? onStepTap;

  /// Called when a reader taps a source chip.
  final void Function(AgentActivitySource source)? onSourceTap;

  /// Shown under the last step when the timeline is open. The model line
  /// lives here: it belongs to the round, but it is not a step in it.
  final Widget? footer;

  /// What the turn is doing right now, so the header can name the wait
  /// instead of calling all of it "Thinking". Null once the turn is over.
  final StreamPhase? phase;

  /// When the request went out. The clock runs from here, not from the
  /// first tool call: the wait before the first token is the longest part
  /// of a slow turn and used to be counted as nothing at all.
  final DateTime? startedAt;

  /// The turn's measured length, kept with the message. Once it is there
  /// the header stops recomputing — a reopened chat shows the same number
  /// it showed when the answer arrived.
  final Duration? finalDuration;

  @override
  State<AgentActivityTimeline> createState() => _AgentActivityTimelineState();
}

class _AgentActivityTimelineState extends State<AgentActivityTimeline> {
  /// Null until the reader taps: before that the state follows the round.
  bool? _expandedOverride;

  Timer? _ticker;

  /// What the live counter showed when the turn settled. Used only when the
  /// turn's length was never recorded.
  Duration? _settledDuration;

  /// Diameter of the icon badge sitting on the rail.
  static const double _badgeSize = 26;

  /// Where the rail runs, measured from the left edge of the timeline.
  static const double _railCenter = _badgeSize / 2;

  @override
  void initState() {
    super.initState();
    _expandedOverride = widget.initiallyExpanded;
    _syncTicker();
  }

  @override
  void didUpdateWidget(AgentActivityTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRunning && !widget.isRunning) {
      // The moment the turn settles, keep the number the counter last
      // showed. A turn whose length was never written down would otherwise
      // drop from "Thought for 12s" to a bare "Thought" the instant it
      // finished — the reader watched it count, then saw it vanish.
      final startedAt = oldWidget.startedAt ?? widget.startedAt;
      if (startedAt != null) {
        _settledDuration = _nonNegative(_now.difference(startedAt));
      }
    }
    if (oldWidget.isRunning != widget.isRunning) {
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
    // One tick a second while the turn runs: the live counter shows whole
    // seconds, so re-rendering faster than that only wastes frames. Cancelled
    // the moment the turn settles.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  bool get _isExpanded => _expandedOverride ?? widget.isRunning;

  /// Thinking notes the reader opened, by their position in the list.
  final Set<int> _openBodies = <int>{};

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final steps = widget.steps;
    final entries = steps == null
        ? buildAgentActivityEntries(widget.toolCalls)
        : buildAgentActivityEntriesFromSteps(steps);
    // A settled round with neither a step nor a model line has nothing to
    // show. A RUNNING one still does: the header is what tells the reader
    // the turn is alive and how long it has been waiting, and at that point
    // there is usually nothing else on screen yet.
    if (entries.isEmpty && widget.footer == null && !widget.isRunning) {
      return const SizedBox.shrink();
    }
    final status = TurnStatus(
      isRunning: widget.isRunning,
      hasToolCalls: widget.toolCalls.isNotEmpty,
      hasSteps: entries.isNotEmpty,
      phase: widget.phase,
      runningToolLabel: hasRunningToolCall(widget.toolCalls)
          ? runningActivityLabel(widget.toolCalls)
          : null,
      elapsed: resolveTurnElapsed(
        finalDuration: widget.finalDuration,
        startedAt: widget.startedAt,
        now: _now,
        isRunning: widget.isRunning,
        lastLiveDuration: _settledDuration,
        toolCalls: widget.toolCalls,
      ),
    );

    return SelectionContainer.disabled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(theme, muted, status),
          if (_isExpanded) ...[
            const SizedBox(height: 4),
            for (int i = 0; i < entries.length; i++)
              _buildEntry(
                theme,
                muted,
                entries[i],
                index: i,
                isFirst: i == 0,
                isLast: i == entries.length - 1 && widget.footer == null,
                soleStep: entries.length == 1,
              ),
            if (widget.footer != null)
              Padding(
                padding: const EdgeInsets.only(left: _badgeSize + 10, top: 2),
                child: widget.footer,
              ),
          ],
        ],
      ),
    );
  }

  static Duration _nonNegative(Duration d) => d.isNegative ? Duration.zero : d;

  Widget _buildHeader(ThemeData theme, Color muted, TurnStatus status) {
    // The wording is decided in one place for every platform and every
    // layout branch — see turn_status.dart.
    final label = status.label;

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
              AppIcon(
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

  /// One step: the rail with its badge on the left, the line and the
  /// source chips on the right.
  Widget _buildEntry(
    ThemeData theme,
    Color muted,
    AgentActivityEntry entry, {
    required int index,
    required bool isFirst,
    required bool isLast,
    bool soleStep = false,
  }) {
    // A turn whose only step is the model thinking has nothing to choose
    // between: opening the bar is already the request to read the thinking,
    // and asking for a second tap to get past a clipped first sentence is
    // how the reasoning ends up looking like it is never shown at all. A
    // turn with several steps keeps them collapsed — there the rail is a
    // list to scan, and one opened body would bury the rest.
    final bool bodyOpen =
        _openBodies.contains(index) ||
        (soleStep && entry.toolCall == null && entry.hasBody);
    final Color color = entry.hasError
        ? theme.colorScheme.error.withValues(alpha: 0.85)
        : muted;
    final Color railColor = theme.colorScheme.onSurface.withValues(alpha: 0.15);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _badgeSize,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _buildEntryText(theme, entry, color),
          ),
        ),
        if (entry.hasBody && bodyOpen) ...[
          const SizedBox(height: 2),
          Text(
            entry.body!.trim(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted,
              height: 1.45,
            ),
          ),
        ],
        if (entry.sources.isNotEmpty) ...[
          const SizedBox(height: 4),
          _buildSourceChips(theme, entry.sources),
        ],
        SizedBox(height: isLast ? 2 : 8),
      ],
    );

    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _badgeSize,
            child: _buildRail(
              theme,
              entry,
              color: color,
              railColor: railColor,
              isFirst: isFirst,
              isLast: isLast,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: content),
        ],
      ),
    );

    final call = entry.toolCall;
    final onTap = widget.onStepTap;

    // A thinking note opens in place; a call opens its arguments.
    if (call == null) {
      if (!entry.hasBody) return row;
      return InkWell(
        onTap: () => setState(() {
          if (!_openBodies.remove(index)) _openBodies.add(index);
        }),
        borderRadius: BorderRadius.circular(8),
        child: row,
      );
    }
    if (onTap == null) return row;

    return InkWell(
      onTap: () => onTap(call),
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }

  /// The badge plus the line above and below it, so the steps read as one
  /// continuous thread rather than a stack of unrelated rows.
  Widget _buildRail(
    ThemeData theme,
    AgentActivityEntry entry, {
    required Color color,
    required Color railColor,
    required bool isFirst,
    required bool isLast,
  }) {
    return Stack(
      children: [
        Positioned(
          left: _railCenter - 0.5,
          top: 0,
          bottom: 0,
          child: Column(
            children: [
              SizedBox(
                height: _railCenter,
                child: isFirst
                    ? const SizedBox.shrink()
                    : Container(width: 1, color: railColor),
              ),
              SizedBox(
                height: _badgeSize - _railCenter,
                child: Container(width: 1, color: railColor),
              ),
              if (!isLast)
                Expanded(child: Container(width: 1, color: railColor)),
            ],
          ),
        ),
        Container(
          width: _badgeSize,
          height: _badgeSize,
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            shape: BoxShape.circle,
            border: Border.all(color: railColor),
          ),
          child: AppIcon(_iconFor(entry), size: 14, color: color),
        ),
      ],
    );
  }

  Widget _buildEntryText(
    ThemeData theme,
    AgentActivityEntry entry,
    Color color,
  ) {
    final baseStyle = theme.textTheme.bodySmall?.copyWith(color: color);
    final detail = entry.detail;

    if (detail == null) {
      return Text(
        entry.label,
        style: baseStyle,
        overflow: TextOverflow.ellipsis,
      );
    }

    // The query or URL is the part worth reading, so it carries more
    // contrast than the verb in front of it.
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '${entry.label}  ', style: baseStyle),
          TextSpan(
            text: detail,
            style: baseStyle?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// The pages a step found, as chips that scroll sideways — the row must
  /// never push the message wider than the bubble.
  Widget _buildSourceChips(ThemeData theme, List<AgentActivitySource> sources) {
    return SizedBox(
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: sources.length,
        padding: EdgeInsets.zero,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) =>
            _buildSourceChip(theme, sources[index]),
      ),
    );
  }

  Widget _buildSourceChip(ThemeData theme, AgentActivitySource source) {
    final onSurface = theme.colorScheme.onSurface;

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaviconImage(
            host: source.host,
            size: 16,
            fallbackColor: onSurface.withValues(alpha: 0.5),
            borderRadius: 8,
            fallbackIcon: Icons.public,
          ),
          const SizedBox(width: 6),
          Text(
            source.host,
            style: theme.textTheme.bodySmall?.copyWith(
              color: onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );

    final onTap = widget.onSourceTap;
    if (onTap == null) return chip;

    return InkWell(
      onTap: () => onTap(source),
      borderRadius: BorderRadius.circular(15),
      child: chip,
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
