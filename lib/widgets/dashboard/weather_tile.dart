// Home weather: a compact tile of its own (the chat's WeatherBlockWidget is a
// full-width gradient block; a dashboard tile needs a flat tonal card). It
// reads the same WMO codes.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// The glyph for a WMO weather code.
HugeIconData weatherGlyph(int code) {
  if (code == 0) return HugeIcons.sun01;
  if (code == 1 || code == 2) return HugeIcons.sunCloud01;
  if (code == 3) return HugeIcons.cloud;
  if (code == 45 || code == 48) return HugeIcons.cloudFog;
  if (code >= 51 && code <= 57) return HugeIcons.cloudLittleRain;
  if (code >= 61 && code <= 67) return HugeIcons.cloudAngledRain;
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
    return HugeIcons.cloudSnow;
  }
  if (code >= 80 && code <= 82) return HugeIcons.cloudAngledRain;
  if (code >= 95 && code <= 99) return HugeIcons.cloudAngledZap;
  return HugeIcons.sunCloud01;
}

String _deg(double? v) => v == null ? '–' : '${v.round()}°';

class WeatherTile extends StatelessWidget {
  const WeatherTile({super.key, required this.weather, required this.now});

  final WeatherWidget weather;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final bool full = weather.size == DashboardSize.full;
    final String locale =
        Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en';
    final WeatherDay? today = weather.daily.isEmpty
        ? null
        : weather.daily.first;
    final List<WeatherDay> days = full ? weather.daily : const <WeatherDay>[];

    // The week's range, so every day's bar sits on the same scale.
    final List<double> lows = <double>[
      for (final WeatherDay d in weather.daily)
        if (d.min != null) d.min!,
      if (weather.temp != null) weather.temp!,
    ];
    final List<double> highs = <double>[
      for (final WeatherDay d in weather.daily)
        if (d.max != null) d.max!,
      if (weather.temp != null) weather.temp!,
    ];
    final double? weekLo = lows.isEmpty
        ? null
        : lows.reduce((a, b) => a < b ? a : b);
    final double? weekHi = highs.isEmpty
        ? null
        : highs.reduce((a, b) => a > b ? a : b);

    final Widget current = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              _deg(weather.temp),
              key: ValueKey<String>('weather-temp-${weather.id}'),
              style: theme.textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1,
                letterSpacing: -2,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        HugeIcon(
          weatherGlyph(weather.code),
          size: full ? 52 : 40,
          color: theme.colorScheme.onSurface,
        ),
      ],
    );

    final Widget condition = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (weather.condition.isNotEmpty)
          Text(
            weather.condition,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        if (weather.place.isNotEmpty && weather.place != weather.title)
          Text(
            weather.place,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
            ),
          ),
      ],
    );

    final Widget? range =
        today == null || today.min == null || today.max == null
        ? null
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Text(
                _deg(today.min),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RangeBar(
                  lo: weekLo ?? today.min!,
                  hi: weekHi ?? today.max!,
                  from: today.min!,
                  to: today.max!,
                  marker: weather.temp,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _deg(today.max),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );

    return DashboardCard(
      widget: weather,
      now: now,
      leading: HugeIcon(
        HugeIcons.location01,
        size: 16,
        color: m3.onSurfaceVariant,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          current,
          const SizedBox(height: 8),
          condition,
          if (range != null) ...<Widget>[const SizedBox(height: 14), range],
          if (days.length > 1) ...<Widget>[
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                for (final WeatherDay d in days)
                  Expanded(
                    child: _Day(
                      day: d,
                      label: d.date == null
                          ? ''
                          : DateFormat.E(locale).format(d.date!.toLocal()),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A thin track for the week's range with today's span filled, and a dot
/// where the temperature is now.
class RangeBar extends StatelessWidget {
  const RangeBar({
    super.key,
    required this.lo,
    required this.hi,
    required this.from,
    required this.to,
    this.marker,
  });

  final double lo;
  final double hi;
  final double from;
  final double to;
  final double? marker;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: 10,
      child: CustomPaint(
        painter: _RangePainter(
          lo: lo,
          hi: hi,
          from: from,
          to: to,
          marker: marker,
          track: theme.m3.surfaceContainerHighest,
          fill: theme.colorScheme.primary,
          dot: theme.colorScheme.onSurface,
          ring: dashboardCardFill(theme),
        ),
      ),
    );
  }
}

class _RangePainter extends CustomPainter {
  const _RangePainter({
    required this.lo,
    required this.hi,
    required this.from,
    required this.to,
    required this.marker,
    required this.track,
    required this.fill,
    required this.dot,
    required this.ring,
  });

  final double lo, hi, from, to;
  final double? marker;
  final Color track, fill, dot, ring;

  @override
  void paint(Canvas canvas, Size size) {
    final double span = hi - lo == 0 ? 1 : hi - lo;
    double x(double v) => ((v - lo) / span).clamp(0.0, 1.0) * size.width;
    final double cy = size.height / 2;
    const double t = 5;
    final RRect base = RRect.fromLTRBR(
      0,
      cy - t / 2,
      size.width,
      cy + t / 2,
      const Radius.circular(t / 2),
    );
    canvas.drawRRect(base, Paint()..color = track);
    final double a = x(from);
    final double b = (x(to) - a).abs() < t ? a + t : x(to);
    canvas.drawRRect(
      RRect.fromLTRBR(
        a,
        cy - t / 2,
        b,
        cy + t / 2,
        const Radius.circular(t / 2),
      ),
      Paint()..color = fill,
    );
    final double? m = marker;
    if (m != null) {
      canvas.drawCircle(Offset(x(m), cy), 5, Paint()..color = ring);
      canvas.drawCircle(Offset(x(m), cy), 3.2, Paint()..color = dot);
    }
  }

  @override
  bool shouldRepaint(_RangePainter old) =>
      old.from != from ||
      old.to != to ||
      old.marker != marker ||
      old.lo != lo ||
      old.hi != hi ||
      old.fill != fill;
}

class _Day extends StatelessWidget {
  const _Day({required this.day, required this.label});

  final WeatherDay day;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: m3.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        HugeIcon(
          weatherGlyph(day.code),
          size: 22,
          color: theme.colorScheme.onSurface,
        ),
        const SizedBox(height: 8),
        Text(
          _deg(day.max),
          maxLines: 1,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _deg(day.min),
          maxLines: 1,
          style: theme.textTheme.labelMedium?.copyWith(
            color: m3.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
