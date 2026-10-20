// lib/voice/widgets/voice_agent_card.dart
//
// Draws a card the voice agent pushed during a call (`ui.card`). Ported from
// new-voicemode `app/lib/widgets/agent_card.dart`, fitted to docs/DESIGN.md:
// HugeIcons only (no Material glyphs), corner 16, flat fill, no border glow,
// no network images, no spinner that turns forever. A kind this build does
// not know draws as a key/value list, so a newer worker never leaves a blank.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

class VoiceAgentCard extends StatelessWidget {
  const VoiceAgentCard({super.key, required this.card, this.fill});

  final VoiceCard card;

  /// The card's fill. Null: `surfaceContainerHighest`, one step above the
  /// call panel and the record card it sits on.
  final Color? fill;

  static const Map<String, HugeIconData> _icons = <String, HugeIconData>{
    'weather': HugeIcons.sun01,
    'search': HugeIcons.search01,
    'news': HugeIcons.note01,
    'article': HugeIcons.fileText,
    'stock': HugeIcons.presentation01,
    'map': HugeIcons.mapPin,
    'list': HugeIcons.listView,
    'currency': HugeIcons.dollar01,
    'calc': HugeIcons.braces,
    'time': HugeIcons.clock01,
    'memory': HugeIcons.bookmark01,
    'task': HugeIcons.timer01,
    'reminder': HugeIcons.notification01,
    'device': HugeIcons.laptop,
  };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool weather = card.kind == 'weather';
    return Container(
      decoration: BoxDecoration(
        color: weather
            ? Colors.transparent
            : fill ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      padding: weather
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: weather
          ? _WeatherBody(card: card)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Header(
                  card: card,
                  icon: _icons[card.kind] ?? HugeIcons.sparkles,
                ),
                _body(),
              ],
            ),
    );
  }

  Widget _body() => switch (card.kind) {
    'weather' => _WeatherBody(card: card),
    'search' => _SearchBody(card: card),
    'news' => _LinksBody(entries: card.list('items').take(8).toList()),
    'list' => _LinksBody(entries: card.list('items').take(20).toList()),
    'article' => _ArticleBody(card: card),
    'stock' => _StockBody(card: card),
    'map' => _MapBody(card: card),
    'currency' || 'calc' || 'time' => _ValueBody(card: card),
    'memory' => _FactsBody(card: card),
    'task' || 'reminder' => _TaskBody(card: card),
    'device' => _DeviceBody(card: card),
    _ => _GenericBody(card: card),
  };
}

// ── Pieces ───────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.card, required this.icon});

  final VoiceCard card;
  final HugeIconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? subtitle = card.kind == 'search' ? null : card.subtitle;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: HugeIcon(icon, size: 16, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  card.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (card.source != null && card.source!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(
                card.source!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens a web link the card carries. Only http(s): the card comes from a
/// model-driven agent.
void _openWebLink(String? url) {
  if (url == null) return;
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasAuthority) return;
  if (uri.scheme != 'https' && uri.scheme != 'http') return;
  unawaited(
    launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    ).then((_) {}, onError: (Object _) {}),
  );
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? url = entry['url']?.toString();
    final bool linked = url != null && url.isNotEmpty;
    final String title = entry['title']?.toString() ?? url ?? '';
    final String? snippet = entry['snippet']?.toString();
    final String source = <String>[
      if (entry['source'] != null) '${entry['source']}',
      if (entry['published'] != null) '${entry['published']}',
    ].where((String s) => s.isNotEmpty).join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: linked ? () => _openWebLink(url) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: linked ? FontWeight.w600 : FontWeight.w400,
                color: linked ? scheme.primary : scheme.onSurface,
              ),
            ),
            if (snippet != null && snippet.isNotEmpty)
              Text(
                snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (source.isNotEmpty)
              Text(
                source,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LinksBody extends StatelessWidget {
  const _LinksBody({required this.entries});

  final List<Map<String, dynamic>> entries;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (final Map<String, dynamic> e in entries) _LinkRow(entry: e),
    ],
  );
}

/// A small text link in the card's accent ("Open in browser").
class _TextLink extends StatelessWidget {
  const _TextLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              HugeIcon(
                HugeIcons.arrowUpRight01,
                size: 14,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Bodies ───────────────────────────────────────────────────────────────

class _WeatherBody extends StatelessWidget {
  const _WeatherBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final int code = _codeOf(card.data['code'] ?? card.data['icon']);
    final bool isDay = card.data['is_day'] != false;
    final List<Color> wash = _washFor(code, isDay);
    final double? temp = card.number('temperature');
    final double? feels = card.number('apparent');
    final String condition = card.text('condition') ?? '';
    final String location = <String>[
      card.title,
      if ((card.subtitle ?? '').isNotEmpty) card.subtitle!,
    ].join(', ');
    final List<Map<String, dynamic>> hourly = card.list('hourly');
    final List<Map<String, dynamic>> daily = card.list('daily');

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: wash.first,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: wash,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (location.isNotEmpty)
                      Row(
                        children: <Widget>[
                          HugeIcon(
                            HugeIcons.mapPin,
                            size: 14,
                            color: Colors.white.withValues(alpha: 0.75),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              location,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        HugeIcon(_iconFor(code), size: 56, color: Colors.white),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                temp == null ? '–' : '${temp.round()}°',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 44,
                                  fontWeight: FontWeight.w300,
                                  height: 1,
                                ),
                              ),
                              if (condition.isNotEmpty)
                                Text(
                                  condition,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              if (feels != null)
                                Text(
                                  'Feels like ${feels.round()}°',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      children: <Widget>[
                        if (card.number('humidity') != null)
                          _WeatherStat(
                            icon: HugeIcons.cloudLittleRain,
                            value: '${card.number('humidity')!.round()}%',
                            label: 'Humidity',
                          ),
                        if (card.number('wind') != null)
                          _WeatherStat(
                            icon: HugeIcons.cloud,
                            value: '${card.number('wind')!.round()} km/h',
                            label: 'Wind',
                          ),
                        if (card.number('precipitation') != null)
                          _WeatherStat(
                            icon: HugeIcons.cloudAngledRain,
                            value: '${_fmt(card.number('precipitation')!)} mm',
                            label: 'Precip',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (hourly.isNotEmpty)
                ColoredBox(
                  color: Colors.black.withValues(alpha: 0.12),
                  child: SizedBox(
                    height: 92,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: hourly.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 14),
                      itemBuilder: (_, int i) => _WeatherHour(entry: hourly[i]),
                    ),
                  ),
                ),
              if (daily.isNotEmpty)
                ColoredBox(
                  color: Colors.black.withValues(alpha: 0.16),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                    child: Column(
                      children: <Widget>[
                        for (final Map<String, dynamic> d in daily)
                          _WeatherDay(entry: d),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
}

class _WeatherStat extends StatelessWidget {
  const _WeatherStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  final HugeIconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        HugeIcon(icon, size: 14, color: Colors.white.withValues(alpha: 0.75)),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _WeatherHour extends StatelessWidget {
  const _WeatherHour({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final DateTime? t = DateTime.tryParse('${entry['time'] ?? ''}');
    final Object? rawTemp = entry['temp'];
    final int code = _codeOf(entry['code'] ?? entry['icon']);
    final Object? precip = entry['precip_prob'];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t == null ? '' : t.hour.toString().padLeft(2, '0'),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w500,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        HugeIcon(_iconFor(code), size: 18, color: Colors.white),
        const SizedBox(height: 2),
        Text(
          rawTemp is num ? '${rawTemp.round()}°' : '–',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.1,
          ),
        ),
        if (precip is num && precip > 0)
          Text(
            '${precip.round()}%',
            style: const TextStyle(
              color: Color(0xFFB3E5FC),
              fontSize: 10,
              height: 1.1,
            ),
          ),
      ],
    );
  }
}

class _WeatherDay extends StatelessWidget {
  const _WeatherDay({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final int code = _codeOf(entry['code'] ?? entry['icon']);
    final Object? min = entry['min'] ?? entry['temp_min'];
    final Object? max = entry['max'] ?? entry['temp_max'];
    final Object? precip = entry['precip_prob'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(
              _dayLabel(entry['date']),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          HugeIcon(_iconFor(code), size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: precip is num && precip > 0
                ? Text(
                    '${precip.round()}%',
                    style: const TextStyle(
                      color: Color(0xFFB3E5FC),
                      fontSize: 11,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Text(
            min is num ? '${min.round()}°' : '',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            max is num ? '${max.round()}°' : '',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

int _codeOf(Object? raw) {
  if (raw is num) return raw.toInt();
  switch ('$raw') {
    case 'clear':
    case 'clear_night':
      return 0;
    case 'partly_cloudy':
    case 'partly_cloudy_night':
      return 2;
    case 'overcast':
    case 'cloudy':
      return 3;
    case 'fog':
      return 45;
    case 'drizzle':
      return 51;
    case 'rain':
    case 'showers':
    case 'heavy_showers':
      return 61;
    case 'snow':
    case 'heavy_snow':
    case 'snow_showers':
      return 71;
    case 'thunderstorm':
    case 'thunderstorm_hail':
      return 95;
    default:
      return 3;
  }
}

HugeIconData _iconFor(int code) {
  if (code == 0 || code == 1) return HugeIcons.sun01;
  if (code == 2) return HugeIcons.sunCloud01;
  if (code == 45 || code == 48) return HugeIcons.cloudFog;
  if (code >= 71 && code <= 86) return HugeIcons.cloudSnow;
  if (code >= 95) return HugeIcons.cloudAngledZap;
  if (code >= 51) return HugeIcons.cloudAngledRain;
  return HugeIcons.cloud;
}

List<Color> _washFor(int code, bool isDay) {
  if (code >= 95) {
    return const <Color>[Color(0xFF2C3E50), Color(0xFF1A1A2E)];
  }
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
    return const <Color>[Color(0xFF4A6572), Color(0xFF232F34)];
  }
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
    return const <Color>[Color(0xFF355C7D), Color(0xFF2C3E50)];
  }
  if (code == 45 || code == 48) {
    return const <Color>[Color(0xFF3E4247), Color(0xFF2A2D33)];
  }
  if (code == 3) {
    return const <Color>[Color(0xFF3C4A5E), Color(0xFF253142)];
  }
  if (code == 1 || code == 2) {
    return isDay
        ? const <Color>[Color(0xFF5A9BD4), Color(0xFF81B7DE)]
        : const <Color>[Color(0xFF3A5683), Color(0xFF1E3A5F)];
  }
  return isDay
      ? const <Color>[Color(0xFF4A90E2), Color(0xFF7FB3E7)]
      : const <Color>[Color(0xFF1E3A5F), Color(0xFF0F1E2F)];
}

String _dayLabel(Object? raw) {
  final DateTime? parsed = DateTime.tryParse('$raw');
  if (parsed == null) return raw?.toString() ?? '';
  const List<String> days = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime target = DateTime(parsed.year, parsed.month, parsed.day);
  final int diff = target.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  return days[(parsed.weekday - 1) % 7];
}

class _SearchBody extends StatelessWidget {
  const _SearchBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? answer = card.text('answer');
    final List<Map<String, dynamic>> results = card.list('results');
    final Object? rawSummary = card.data['summary'];
    final Map<String, dynamic>? summary = rawSummary is Map
        ? rawSummary.cast<String, dynamic>()
        : null;
    final String? extract = summary?['extract']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (answer != null)
          Text(
            answer,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.4,
              color: theme.colorScheme.onSurface,
            ),
          ),
        if (extract != null && extract.isNotEmpty) ...<Widget>[
          if (answer != null) const SizedBox(height: 6),
          Text(
            extract,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.4,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (summary?['url'] != null)
            _TextLink(
              label: summary?['title']?.toString() ?? 'Wikipedia',
              onTap: () => _openWebLink(summary?['url']?.toString()),
            ),
        ],
        if (results.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          _LinksBody(entries: results.take(6).toList()),
        ],
      ],
    );
  }
}

class _ArticleBody extends StatelessWidget {
  const _ArticleBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? url = card.text('url');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (card.text('text') != null)
          Text(
            card.text('text')!,
            maxLines: 12,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.4,
              color: theme.colorScheme.onSurface,
            ),
          ),
        if (url != null)
          _TextLink(label: 'Open in browser', onTap: () => _openWebLink(url)),
      ],
    );
  }
}

class _StockBody extends StatelessWidget {
  const _StockBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double change = card.number('change_pct') ?? 0;
    final bool up = change >= 0;
    // Text colour only: green up, the theme's error red down.
    final Color accent = up ? const Color(0xFF2E7D32) : scheme.error;
    final Object? rawSeries = card.data['series'];
    final List<double> series = rawSeries is List
        ? <double>[
            for (final Object? v in rawSeries)
              if (v is num) v.toDouble(),
          ]
        : const <double>[];
    final double? price = card.number('price');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (price != null)
          Text(
            '${price.toStringAsFixed(2)} ${card.text('currency') ?? ''}'.trim(),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        Row(
          children: <Widget>[
            Text(
              '${up ? '+' : ''}${change.toStringAsFixed(2)} %',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: accent,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              card.text('symbol') ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (series.length > 1) ...<Widget>[
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: CustomPaint(painter: _SparklinePainter(series, accent)),
          ),
        ],
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double low = values.reduce(math.min);
    final double high = values.reduce(math.max);
    final double range = (high - low).abs() < 1e-9 ? 1.0 : high - low;
    final Path path = Path();
    for (int i = 0; i < values.length; i++) {
      final double x = size.width * i / (values.length - 1);
      final double y = size.height - ((values[i] - low) / range) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color;
}

class _MapBody extends StatelessWidget {
  const _MapBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? lat = card.number('latitude');
    final double? lon = card.number('longitude');
    final double? population = card.number('population');
    final double? elevation = card.number('elevation');
    final List<String> facts = <String>[
      if (card.text('detail') != null) card.text('detail')!,
      if (population != null) '${population.round()} people',
      if (elevation != null) '${elevation.round()} m',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (facts.isNotEmpty)
          Text(
            facts.join(' · '),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        if (lat != null && lon != null)
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              _TextLink(
                label: 'Open map',
                onTap: () => _openWebLink(
                  'https://www.openstreetmap.org/?mlat=$lat&mlon=$lon'
                  '#map=15/$lat/$lon',
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _ValueBody extends StatelessWidget {
  const _ValueBody({required this.card});

  final VoiceCard card;

  /// The big value and the small line under it, per kind.
  (String?, String?) _lines() {
    switch (card.kind) {
      case 'calc':
        return (card.text('result'), card.text('expression'));
      case 'time':
        return (
          card.text('time'),
          <String?>[
            card.text('date'),
            card.text('location'),
            card.text('timezone'),
          ].whereType<String>().join(' · '),
        );
      case 'currency':
        final String? result = card.text('result');
        final double? rate = card.number('rate');
        return (
          result == null ? null : '$result ${card.text('to') ?? ''}'.trim(),
          <String>[
            if (card.text('amount') != null)
              '${card.text('amount')} ${card.text('from') ?? ''}'.trim(),
            if (rate != null) 'rate ${rate.toStringAsFixed(4)}',
            if (card.text('date') != null) card.text('date')!,
          ].join(' · '),
        );
      default:
        return (null, null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (String? value, String? detail) = _lines();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (value != null && value.isNotEmpty)
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        if (detail != null && detail.isNotEmpty)
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _FactsBody extends StatelessWidget {
  const _FactsBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Object? raw = card.data['facts'];
    final List<String> facts = raw is List
        ? <String>[for (final Object? f in raw) '$f']
        : const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final String fact in facts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '·  $fact',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
      ],
    );
  }
}

class _TaskBody extends StatelessWidget {
  const _TaskBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime? due = DateTime.tryParse(card.text('due_iso') ?? '');
    final String? what = card.text('about') ?? card.text('label');
    final String line;
    if (due != null) {
      final DateTime local = due.toLocal();
      line =
          'Due at ${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    } else {
      line = 'Running in the background';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (what != null)
          Text(
            what,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        Text(
          line,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DeviceBody extends StatelessWidget {
  const _DeviceBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double level = card.number('battery') ?? 0;
    final List<String> parts = <String>[
      '${level.round()} %',
      if (card.data['charging'] == true) 'charging',
      if (card.text('network') != null) card.text('network')!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (level / 100).clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: scheme.surfaceContainerHigh,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          parts.join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _GenericBody extends StatelessWidget {
  const _GenericBody({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Iterable<MapEntry<String, dynamic>> entries = card.data.entries
        .where(
          (MapEntry<String, dynamic> e) => e.value is! List && e.value is! Map,
        )
        .take(8);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final MapEntry<String, dynamic> e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              '${e.key}: ${e.value}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
