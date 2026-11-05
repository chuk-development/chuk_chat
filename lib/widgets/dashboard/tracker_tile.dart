// Home tracker: a progress ring that springs to today's sum, the number big
// inside it, step buttons that log at once, seven mini bars with the goal
// line, and the streak (docs/DASHBOARD.md §3).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/main_agent_launcher.dart';
import 'package:chuk_chat/services/dashboard/dashboard_controller.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/shapes.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

HugeIconData trackerIconGlyph(TrackerIcon icon) => switch (icon) {
  TrackerIcon.dumbbell => HugeIcons.dumbbell01,
  TrackerIcon.run => HugeIcons.activity01,
  TrackerIcon.water => HugeIcons.droplet,
  TrackerIcon.book => HugeIcons.bookOpen01,
  TrackerIcon.sleep => HugeIcons.moon02,
  TrackerIcon.heart => HugeIcons.favourite,
  TrackerIcon.check => HugeIcons.checkmarkCircle02,
};

String _signed(double v) => '${v >= 0 ? '+' : ''}${formatNumber(v)}';

class TrackerTile extends StatelessWidget {
  const TrackerTile({
    super.key,
    required this.tracker,
    required this.controller,
    required this.now,
  });

  final TrackerWidget tracker;
  final DashboardController controller;
  final DateTime now;

  void _log(BuildContext context, double value) {
    HapticFeedback.lightImpact();
    controller.log(tracker.id, value);
  }

  Future<void> _openMenu(BuildContext context) async {
    final AppLocalizations l = dashboardStrings(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TrackerEntry? last = tracker.undoable;
    final String? choice = await showMenuSheet<String>(
      context,
      header: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          tracker.title,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      groups: <List<Widget>>[
        <Widget>[
          Builder(
            builder: (BuildContext row) => MenuActionRow(
              leading: HugeIcon(
                HugeIcons.undo02,
                size: 20,
                color: scheme.onSurface.withValues(
                  alpha: last == null ? 0.38 : 1,
                ),
              ),
              label: last == null
                  ? l.dashNothingToUndo
                  : l.dashUndoLast(_signed(last.value)),
              enabled: last != null,
              onTap: () => Navigator.of(row).pop('undo'),
            ),
          ),
          Builder(
            builder: (BuildContext row) => MenuActionRow(
              leading: HugeIcon(
                HugeIcons.sparkles,
                size: 20,
                color: scheme.onSurface,
              ),
              label: l.dashAskAgent,
              onTap: () => Navigator.of(row).pop('ask'),
            ),
          ),
        ],
      ],
    );
    switch (choice) {
      case 'undo':
        if (last != null) {
          HapticFeedback.selectionClick();
          await controller.log(tracker.id, -last.value);
        }
      case 'ask':
        MainAgentLauncher.instance.openWithPrompt(
          l.dashAskAgentPrompt(tracker.title),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = dashboardStrings(context);
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final Color card = dashboardCardFill(theme);
    final double today = tracker.current(now);
    final int streak = tracker.streak(now);
    final double fraction = (today / tracker.goal).clamp(0.0, 1.0);
    final bool full = tracker.size == DashboardSize.full;
    final bool reached = today >= tracker.goal;
    final int percent = (today / tracker.goal * 100).round();

    // The gauge carries the icon, big and in the badge shape, so the tile
    // reads as "push-ups" before a word is read.
    final Widget gauge = _ProgressRing(
      fraction: fraction,
      size: full ? 128 : 112,
      child: DashboardBadge(
        icon: trackerIconGlyph(tracker.icon),
        size: full ? 54 : 48,
        fill: reached ? theme.colorScheme.primary : m3.primaryContainer,
        glyph: reached
            ? readableOnFill(
                theme.colorScheme.primary,
                theme.colorScheme.onPrimary,
              )
            : m3.onPrimaryContainer,
        shape: const CookieShape(lobes: 8, softness: 0.09),
      ),
    );

    final Widget value = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                formatNumber(today),
                key: ValueKey<String>('tracker-today-${tracker.id}'),
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1,
                  letterSpacing: -1,
                  color: theme.colorScheme.onSurface,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              if (tracker.unit.isNotEmpty) ...<Widget>[
                const SizedBox(width: 4),
                Text(
                  tracker.unit,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: m3.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${l.dashOfGoal(formatNumber(tracker.goal), '').trim()} · $percent %',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: m3.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );

    final Widget steps = Row(
      children: <Widget>[
        for (int i = 0; i < tracker.steps.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: _StepButton(
              key: ValueKey<String>('tracker-step-${tracker.id}-$i'),
              label: _signed(tracker.steps[i]),
              primary: i == tracker.steps.length - 1,
              onTap: () => _log(context, tracker.steps[i]),
            ),
          ),
        ],
      ],
    );

    final Widget bars = SizedBox(
      height: 22,
      child: CustomPaint(
        painter: _MiniBarsPainter(
          values: tracker.recent(now),
          goal: tracker.goal,
          hit: theme.colorScheme.primary.withValues(alpha: 0.75),
          miss: m3.onSurfaceVariant.withValues(alpha: 0.14),
          current: theme.colorScheme.primary.withValues(alpha: 0.4),
          line: m3.onSurfaceVariant.withValues(alpha: 0.35),
        ),
      ),
    );

    final Widget streakLine = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        HugeIcon(
          reached && streak == 0 ? HugeIcons.checkmarkBadge01 : HugeIcons.fire,
          size: 14,
          color: streak > 0 || reached
              ? theme.accentForegroundOn(card)
              : m3.onSurfaceVariant,
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            streak > 0
                ? (tracker.period == TrackerPeriod.day
                      ? l.dashStreakDays('$streak')
                      : l.dashStreakWeeks('$streak'))
                : (reached ? l.dashGoalReached : l.dashNoStreak),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: m3.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );

    final Widget body = full
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  gauge,
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        value,
                        const SizedBox(height: 14),
                        bars,
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: streakLine,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              steps,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              value,
              const SizedBox(height: 10),
              Center(child: gauge),
              const SizedBox(height: 12),
              steps,
              const SizedBox(height: 14),
              bars,
              const SizedBox(height: 8),
              Center(child: streakLine),
            ],
          );

    return DashboardCard(
      widget: tracker,
      now: now,
      trailing: Builder(
        builder: (BuildContext anchor) => _SmallIconButton(
          key: ValueKey<String>('tracker-menu-${tracker.id}'),
          icon: HugeIcons.moreHorizontal,
          tooltip: l.dashMoreOptions,
          onTap: () => _openMenu(anchor),
        ),
      ),
      child: body,
    );
  }
}

/// A 36 px squircle target for the head row of a small card. Same family
/// as [ExpressiveIconButton]; that one is 48 px and too big for a half tile.
class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final HugeIconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final MaterialYouTokens m3 = Theme.of(context).m3;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: MorphTap(
          onTap: onTap,
          color: Colors.transparent,
          pressedColor: m3.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: HugeIcon(icon, size: 20, color: m3.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    // The strong action is an ink pill (onSurface), the others are tonal.
    final Color fill = primary
        ? theme.colorScheme.primary
        : m3.surfaceContainerHighest;
    final Color fg = primary
        ? readableOnFill(fill, theme.colorScheme.onPrimary)
        : theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      label: label,
      child: MorphTap(
        onTap: onTap,
        color: fill,
        pressedScale: 0.9,
        shape: const StadiumBorder(),
        child: SizedBox(
          height: 40,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The ring. It springs from where it was to [fraction] on every change.
class _ProgressRing extends StatefulWidget {
  const _ProgressRing({
    required this.fraction,
    required this.size,
    required this.child,
  });

  final double fraction;
  final double size;
  final Widget child;

  @override
  State<_ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<_ProgressRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.fraction,
  );

  @override
  void didUpdateWidget(_ProgressRing old) {
    super.didUpdateWidget(old);
    if (old.fraction == widget.fraction) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = widget.fraction;
      return;
    }
    _c.animateWith(
      SpringSimulation(kSpatialSpring, _c.value, widget.fraction, _c.velocity),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (BuildContext context, Widget? child) => CustomPaint(
          painter: _RingPainter(
            fraction: _c.value,
            track: theme.m3.surfaceContainerHighest,
            arc: theme.colorScheme.primary,
            stroke: widget.size * 0.075,
          ),
          child: child,
        ),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.track,
    required this.arc,
    required this.stroke,
  });

  final double fraction;
  final Color track;
  final Color arc;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate(stroke / 2);
    final Paint base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    // A gauge, not a closed ring: 270 degrees, open at the bottom.
    const double start = math.pi * 0.75;
    const double sweep = math.pi * 1.5;
    canvas.drawArc(rect, start, sweep, false, base);
    final double f = fraction.clamp(0.0, 1.0);
    if (f <= 0.001) return;
    canvas.drawArc(rect, start, sweep * f, false, base..color = arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.track != track ||
      old.arc != arc ||
      old.stroke != stroke;
}

/// Seven small bars, oldest left, today right, and a dashed goal line.
class _MiniBarsPainter extends CustomPainter {
  const _MiniBarsPainter({
    required this.values,
    required this.goal,
    required this.hit,
    required this.miss,
    required this.current,
    required this.line,
  });

  final List<double> values;
  final double goal;
  final Color hit;
  final Color miss;
  final Color current;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final double top = math.max(goal * 1.15, values.reduce(math.max));
    final double gap = 5;
    final double w = (size.width - gap * (values.length - 1)) / values.length;
    final double r = math.min(4, w / 2);
    for (int i = 0; i < values.length; i++) {
      final double v = values[i].clamp(0.0, top);
      final double h = math.max(4, size.height * (v / top));
      final double x = i * (w + gap);
      final bool last = i == values.length - 1;
      final Color c = values[i] >= goal ? hit : (last ? current : miss);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, w, h),
          Radius.circular(r),
        ),
        Paint()..color = c,
      );
    }
    final double y = size.height - size.height * (goal / top);
    final Paint dash = Paint()
      ..color = line
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (double x = 0; x < size.width; x += 6) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + 3, size.width), y),
        dash,
      );
    }
  }

  @override
  bool shouldRepaint(_MiniBarsPainter old) =>
      !listEquals(old.values, values) ||
      old.goal != goal ||
      old.hit != hit ||
      old.miss != miss;
}
