// Home metric: one big number, its unit, a delta pill in the tone's
// container colour, and a sparkline of the trend.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/main_agent_launcher.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.metric, required this.now});

  final MetricWidget metric;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final AppLocalizations l = dashboardStrings(context);
    final bool full = metric.size == DashboardSize.full;
    final String delta = metric.delta.trim();
    final bool down = delta.startsWith('-') || delta.startsWith('−');
    final bool up = delta.startsWith('+');
    final Color toneInk = switch (metric.tone) {
      MetricTone.good => m3.success,
      MetricTone.warn => m3.warning,
      MetricTone.bad => theme.colorScheme.error,
      MetricTone.neutral => m3.onSurfaceVariant,
    };
    final Color line = metric.tone == MetricTone.neutral
        ? theme.colorScheme.primary
        : toneInk;

    final Widget value = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(
            metric.value,
            key: ValueKey<String>('metric-value-${metric.id}'),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.8,
              height: 1,
              color: theme.colorScheme.onSurface,
            ),
          ),
          if (metric.unit.isNotEmpty) ...<Widget>[
            const SizedBox(width: 4),
            Text(
              metric.unit,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: m3.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );

    final Widget deltaLine = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (up || down) ...<Widget>[
          HugeIcon(
            up ? HugeIcons.arrowUpRight01 : HugeIcons.arrowDownRight01,
            size: 14,
            color: toneInk,
          ),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            delta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: toneInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );

    final Widget? caption = metric.caption.isEmpty
        ? null
        : Text(
            metric.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
            ),
          );

    final Widget? spark = metric.trend.length < 2
        ? null
        : SizedBox(
            height: full ? 56 : 40,
            width: double.infinity,
            child: CustomPaint(
              painter: SparklinePainter(
                values: metric.trend,
                color: line,
                baseline: m3.onSurfaceVariant.withValues(alpha: 0.4),
                ring: dashboardCardFill(theme),
              ),
            ),
          );

    final Widget numbers = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        value,
        if (delta.isNotEmpty) ...<Widget>[const SizedBox(height: 6), deltaLine],
        if (caption != null) ...<Widget>[const SizedBox(height: 2), caption],
      ],
    );

    return DashboardCard(
      widget: metric,
      now: now,
      onTap: () => MainAgentLauncher.instance.openWithPrompt(
        l.dashAskAgentPrompt(metric.title),
      ),
      leading: HugeIcon(
        HugeIcons.chartLineData01,
        size: 16,
        color: m3.onSurfaceVariant,
      ),
      trailing: HugeIcon(
        HugeIcons.arrowRight01,
        size: 16,
        color: m3.onSurfaceVariant,
      ),
      child: full
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(child: numbers),
                if (spark != null) ...<Widget>[
                  const SizedBox(width: 16),
                  Expanded(child: spark),
                ],
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                numbers,
                if (spark != null) ...<Widget>[
                  const SizedBox(height: 12),
                  spark,
                ],
              ],
            ),
    );
  }
}

/// A smooth line through [values], a dotted baseline at the first value and
/// a dot on the newest one, set off by a ring in the card colour.
class SparklinePainter extends CustomPainter {
  const SparklinePainter({
    required this.values,
    required this.color,
    required this.baseline,
    required this.ring,
  });

  final List<double> values;
  final Color color;
  final Color baseline;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final double lo = values.reduce(math.min);
    final double hi = values.reduce(math.max);
    final double span = hi - lo == 0 ? 1 : hi - lo;
    const double pad = 6;
    final double h = size.height - pad * 2;
    double yOf(double v) => pad + h - h * ((v - lo) / span);
    Offset at(int i) =>
        Offset((size.width - pad) * i / (values.length - 1), yOf(values[i]));
    final double by = yOf(values.first);
    final Paint dot = Paint()..color = baseline;
    for (double x = 0; x < size.width; x += 5) {
      canvas.drawCircle(Offset(x, by), 0.9, dot);
    }
    final Path line = Path()..moveTo(at(0).dx, at(0).dy);
    for (int i = 1; i < values.length; i++) {
      final Offset p0 = at(i - 1);
      final Offset p1 = at(i);
      final double mx = (p0.dx + p1.dx) / 2;
      line.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    final Offset end = at(values.length - 1);
    canvas.drawCircle(end, 5.5, Paint()..color = ring);
    canvas.drawCircle(end, 3.8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      !listEquals(old.values, values) || old.color != color || old.ring != ring;
}
