// lib/widgets/agent_activity/agent_activity_timeline.dart
//
// The agent's work as a rail: one step per line, a thin line connecting
// them, and under each search the pages it found as chips. Folded to a
// single "Worked for 13s" once the answer is there, so a finished turn
// reads as answer-first and the work is one tap away.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/settings/tool_detail_service.dart';
import 'package:chuk_chat/utils/favicon.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/min_duration_hold.dart';
import 'package:chuk_chat/widgets/agent_activity/tool_activity_category.dart';
import 'package:chuk_chat/widgets/agent_activity/turn_status.dart';
import 'package:chuk_chat/widgets/diff_widget.dart' show diffChangeCountInResult;
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';
import 'package:chuk_chat/widgets/text_shimmer.dart';

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
    this.liveVerb,
    this.liveTrailing,
    this.liveListenable,
    this.liveDots = false,
    this.liveSteps,
    this.showResultSummaries = false,
    this.toolDetailMode,
  });

  /// Overrides the "Tool detail" setting ([ToolDetailService]). Null follows
  /// the setting, which is what the app does; tests pin a mode.
  final ToolDetailMode? toolDetailMode;

  /// While the round runs, the header is only the three typing dots: it
  /// says the agent is still working and nothing more. The words (the
  /// phase, the clock) and every step sit behind a tap, in the open panel.
  /// Folded by default. Once the round settles the header is the usual
  /// "Worked for 13s" line again.
  final bool liveDots;

  /// The steps of a running round, read again on every repaint, like
  /// [liveVerb]. An Agents run reports its steps to the run ledger, not to
  /// the message, so the bubble cannot hand them down as a value. Outranks
  /// [steps] and [toolCalls] while the round runs.
  final List<AgentActivityStep> Function()? liveSteps;

  /// Prints a one-line result under every finished call
  /// ([toolResultSummary]), so the open panel says what each step returned
  /// without a tap per step.
  final bool showResultSummaries;

  /// The phase an Agents turn reports, read again on every repaint while the
  /// round runs (see [TurnStatus.liveVerb]). A callback rather than a value:
  /// the header repaints itself once a second, and a value handed down by
  /// the bubble would be as old as the bubble's last build.
  final String? Function(BuildContext context)? liveVerb;

  /// Shown after the header while the round runs, e.g. a Retry target when
  /// the computer is offline. Read on every repaint, like [liveVerb].
  final Widget? Function(BuildContext context)? liveTrailing;

  /// Repaints the header the moment it fires, instead of on the next tick —
  /// the host's acknowledgement should show within a frame, not a second.
  final Listenable? liveListenable;

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

  /// Holds a running title for at least 150 ms (header and group rows),
  /// keyed by row: -1 is the header.
  final Map<int, MinDurationHold<String>> _holds =
      <int, MinDurationHold<String>>{};
  Timer? _holdTimer;

  /// Groups the reader opened or closed by hand, by their position.
  final Map<int, bool> _groupOverrides = <int, bool>{};

  ToolDetailMode get _mode =>
      widget.toolDetailMode ?? ToolDetailService.instance.value;

  @override
  void initState() {
    super.initState();
    _expandedOverride = widget.initiallyExpanded;
    _syncTicker();
    widget.liveListenable?.addListener(_onLive);
    ToolDetailService.instance.addListener(_onMode);
  }

  void _onMode() {
    if (mounted && widget.toolDetailMode == null) setState(() {});
  }

  /// [wanted] as it may show now: a running title that changed less than
  /// 150 ms ago waits, and a timer shows the newest waiting one.
  String _held(int key, String wanted) {
    if (!widget.isRunning) {
      _holds.remove(key);
      return wanted;
    }
    final MinDurationHold<String> hold = _holds.putIfAbsent(
      key,
      MinDurationHold<String>.new,
    );
    final DateTime now = DateTime.now();
    final String shown = hold.show(wanted, now);
    final Duration? wait = hold.waitFor(now);
    if (wait != null && _holdTimer == null) {
      _holdTimer = Timer(wait, () {
        _holdTimer = null;
        // Show every waiting title now; re-checking the clock could wait
        // again and never let the title through.
        for (final MinDurationHold<String> h in _holds.values) {
          final String? next = h.pending;
          if (next != null) {
            h
              ..reset()
              ..show(next, DateTime.now());
          }
        }
        if (mounted) setState(() {});
      });
    }
    return shown;
  }

  void _onLive() {
    if (mounted && widget.isRunning) setState(() {});
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
      if (!widget.isRunning) {
        _holds.clear();
        _holdTimer?.cancel();
        _holdTimer = null;
      }
    }
    if (oldWidget.liveListenable != widget.liveListenable) {
      oldWidget.liveListenable?.removeListener(_onLive);
      widget.liveListenable?.addListener(_onLive);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _holdTimer?.cancel();
    widget.liveListenable?.removeListener(_onLive);
    ToolDetailService.instance.removeListener(_onMode);
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

  /// Whether any step of the round failed. Set in [build].
  bool _hasError = false;

  /// Open while the round runs; once it settles it folds to one line, unless
  /// a step failed (then it stays open so the failure is not hidden, in every
  /// mode) or the reader chose Verbose.
  bool get _isExpanded =>
      _expandedOverride ??
      ((widget.isRunning && !widget.liveDots) ||
          (!widget.isRunning && (_hasError || _mode.keepsSettledTurnOpen)));

  static bool _anyError(Iterable<AgentActivityEntry> entries) {
    for (final e in entries) {
      if (e.anyError) return true;
    }
    return false;
  }

  /// Whether the group at [index] shows its steps: the reader's choice,
  /// else open when a step failed, else what the mode says.
  bool _groupOpen(int index, AgentActivityEntry group) {
    final bool? manual = _groupOverrides[index];
    if (manual != null) return manual;
    if (group.anyError) return true;
    final bool running = widget.isRunning && liveCall(group.groupCalls) != null;
    return running ? _mode.opensRunningGroups : _mode.opensSettledGroups;
  }

  bool get _showSummaries =>
      widget.showResultSummaries || _mode.showsResultSummaries;

  /// The header is the typing dots right now.
  bool get _showsDots => widget.liveDots && widget.isRunning;

  /// Thinking notes the reader opened, by their position in the list.
  final Set<int> _openBodies = <int>{};

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final liveSteps = widget.isRunning ? widget.liveSteps : null;
    final steps = liveSteps != null ? liveSteps() : widget.steps;
    final flat = steps == null
        ? buildAgentActivityEntries(widget.toolCalls)
        : buildAgentActivityEntriesFromSteps(steps);
    // The Agents live panel lists every call with its result: opening it is
    // the request to see each step, so it is not grouped.
    final entries = widget.liveDots ? flat : groupAgentActivityEntries(flat);
    _hasError =
        _anyError(entries) ||
        widget.toolCalls.any((c) => c.status == ToolCallStatus.error);
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
          ? runningActivityLabel(
              widget.toolCalls,
              AppLocalizations.of(context),
            )
          : null,
      elapsed: resolveTurnElapsed(
        finalDuration: widget.finalDuration,
        startedAt: widget.startedAt,
        now: _now,
        isRunning: widget.isRunning,
        lastLiveDuration: _settledDuration,
        toolCalls: widget.toolCalls,
      ),
      liveVerb: widget.isRunning ? widget.liveVerb?.call(context) : null,
    );
    final Widget? trailing = widget.isRunning
        ? widget.liveTrailing?.call(context)
        : null;

    return SelectionContainer.disabled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trailing == null)
            _showsDots
                ? _buildDotsHeader(status)
                : _buildHeader(theme, muted, status)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: _showsDots
                      ? _buildDotsHeader(status)
                      : _buildHeader(theme, muted, status),
                ),
                const SizedBox(width: 6),
                trailing,
              ],
            ),
          if (_isExpanded) ...[
            const SizedBox(height: 4),
            // The dots say nothing but "working". The open panel says what:
            // the phase and the clock first, then every step.
            if (_showsDots)
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 6),
                child: Text(
                  status.label,
                  key: const ValueKey<String>('agents-live-phase'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: muted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
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

  /// The running header as the typing dots alone. A tap opens the panel
  /// with every step; the label is for screen readers only.
  Widget _buildDotsHeader(TurnStatus status) {
    return Semantics(
      button: true,
      expanded: _isExpanded,
      label: status.label,
      child: InkWell(
        key: const ValueKey<String>('agents-live-dots'),
        onTap: () => setState(() => _expandedOverride = !_isExpanded),
        borderRadius: BorderRadius.circular(22),
        child: const ExcludeSemantics(child: MessengerTypingIndicator()),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, Color muted, TurnStatus status) {
    // The wording is decided in one place for every platform and every
    // layout branch — see turn_status.dart.
    // An Agents phase (the host's ack, "offline") must show within a frame;
    // only the tool-derived wording is held.
    final label = status.liveVerb != null && status.liveVerb!.isNotEmpty
        ? status.label
        : _held(-1, status.label);

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
              Flexible(
                child: TextShimmer(
                  active: widget.isRunning,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: muted,
                      fontWeight: FontWeight.w500,
                      // The clock in the label counts up; fixed-width digits
                      // keep the line from jittering every second.
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
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
    if (entry.isGroup) {
      return _buildGroup(
        theme,
        muted,
        entry,
        index: index,
        isFirst: isFirst,
        isLast: isLast,
      );
    }
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
        if (_showSummaries && entry.toolCall != null)
          if (toolResultSummary(entry.toolCall!) case final String summary)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                summary,
                key: const ValueKey<String>('agent-activity-result'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: entry.hasError
                      ? theme.colorScheme.error.withValues(alpha: 0.85)
                      : muted,
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.35,
                ),
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

  /// A run of consecutive tool steps as ONE row: the category title
  /// ("Searching the web · react hooks" while it runs, "Searched the web and
  /// read pages" once closed), opening onto the steps behind it.
  Widget _buildGroup(
    ThemeData theme,
    Color muted,
    AgentActivityEntry group, {
    required int index,
    required bool isFirst,
    required bool isLast,
  }) {
    final AppLocalizations? l10n = AppLocalizations.of(context);
    final List<ToolCall> calls = group.groupCalls;
    final ToolCall? live = widget.isRunning ? liveCall(calls) : null;
    final bool running = live != null;
    String title = running
        ? runningGroupTitle(calls, l10n)
        : closedGroupTitle(calls, l10n);
    if (running && _mode.showsLiveDetail) {
      final String? detail = liveDetail(calls);
      if (detail != null) title = '$title · $detail';
    }
    title = _held(index, title);
    final bool open = _groupOpen(index, group);
    final bool failed = group.anyError;
    final Color color = failed
        ? theme.colorScheme.error.withValues(alpha: 0.85)
        : muted;
    final Color railColor = theme.colorScheme.onSurface.withValues(alpha: 0.15);
    final ToolActivityCategory category = toolActivityCategoryOf(
      (live ?? calls.first).name,
    );

    final Widget header = SizedBox(
      height: _badgeSize,
      child: Row(
        children: [
          Flexible(
            child: TextShimmer(
              active: running,
              child: Text(
                title,
                key: ValueKey<String>('agent-activity-group-$index'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          AppIcon(
            open ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
            size: 16,
            color: muted,
          ),
        ],
      ),
    );

    final List<AgentActivityEntry> steps = group.children;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: open,
          label: title,
          child: InkWell(
            onTap: () => setState(() => _groupOverrides[index] = !open),
            borderRadius: BorderRadius.circular(8),
            child: ExcludeSemantics(child: header),
          ),
        ),
        if (open) ...[
          const SizedBox(height: 4),
          // Keys for the steps' own state (opened bodies) must not collide
          // with the outer rows, so they live in their own index range.
          for (int i = 0; i < steps.length; i++)
            _buildEntry(
              theme,
              muted,
              steps[i],
              index: (index + 1) * 1000 + i,
              isFirst: i == 0,
              isLast: i == steps.length - 1,
            ),
        ],
        SizedBox(height: isLast ? 2 : 8),
      ],
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _badgeSize,
            child: _buildRailWithIcon(
              theme,
              icon: _iconForCategory(category),
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
  }) => _buildRailWithIcon(
    theme,
    icon: _iconFor(entry),
    color: color,
    railColor: railColor,
    isFirst: isFirst,
    isLast: isLast,
  );

  Widget _buildRailWithIcon(
    ThemeData theme, {
    required IconData icon,
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
          child: AppIcon(icon, size: 14, color: color),
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
    final ToolCall? call = entry.toolCall;
    // A call that has not run yet says what it is about to do, with the
    // file and the size it sends: "Preparing: Edit intro.md 1KB".
    final String? preparing = call == null
        ? null
        : preparingLabel(call, AppLocalizations.of(context));
    if (preparing != null) {
      return TextShimmer(
        active: widget.isRunning,
        child: Text(
          preparing,
          style: baseStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    // A finished edit names its change size on the folded row: "+3 -1".
    final changes =
        call != null &&
            call.status == ToolCallStatus.completed &&
            isEditCategory(toolActivityCategoryOf(call.name))
        ? diffChangeCountInResult(call.result)
        : null;
    if (changes != null) {
      final Widget text = _buildEntryTextBody(theme, entry, baseStyle);
      return Row(
        children: [
          Flexible(child: text),
          const SizedBox(width: 6),
          _ChangeCount(added: changes.added, removed: changes.removed),
        ],
      );
    }
    return _buildEntryTextBody(theme, entry, baseStyle);
  }

  Widget _buildEntryTextBody(
    ThemeData theme,
    AgentActivityEntry entry,
    TextStyle? baseStyle,
  ) {
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

  IconData _iconForCategory(ToolActivityCategory category) {
    switch (category) {
      case ToolActivityCategory.search:
      case ToolActivityCategory.webSearch:
        return Icons.search;
      case ToolActivityCategory.webFetch:
        return Icons.language;
      case ToolActivityCategory.read:
        return Icons.description_outlined;
      case ToolActivityCategory.readImage:
      case ToolActivityCategory.images:
        return Icons.image_outlined;
      case ToolActivityCategory.write:
      case ToolActivityCategory.edit:
      case ToolActivityCategory.notes:
        return Icons.edit_outlined;
      case ToolActivityCategory.documents:
        return Icons.article_outlined;
      case ToolActivityCategory.commands:
        return Icons.terminal;
      case ToolActivityCategory.code:
        return Icons.code;
      case ToolActivityCategory.questions:
        return Icons.chat_bubble_outline;
      case ToolActivityCategory.tools:
        return Icons.bolt_outlined;
    }
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

/// "+3 -1" on a folded edit row: green for added, red for removed, fixed
/// width digits. A zero side is left out.
class _ChangeCount extends StatelessWidget {
  const _ChangeCount({required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final TextStyle base = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      fontFamily: 'monospace',
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Text.rich(
      key: const ValueKey<String>('agent-activity-change-count'),
      TextSpan(
        children: [
          if (added > 0)
            TextSpan(
              text: '+$added',
              style: base.copyWith(
                color: dark ? const Color(0xFF7EE787) : const Color(0xFF1A7F37),
              ),
            ),
          if (added > 0 && removed > 0) const TextSpan(text: ' '),
          if (removed > 0)
            TextSpan(
              text: '-$removed',
              style: base.copyWith(
                color: dark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E),
              ),
            ),
        ],
      ),
      maxLines: 1,
    );
  }
}
