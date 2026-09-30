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
    return Container(
      decoration: BoxDecoration(
        color: fill ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(card: card, icon: _icons[card.kind] ?? HugeIcons.sparkles),
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double? temp = card.number('temperature');
    final List<Map<String, dynamic>> hourly = card.list('hourly');
    final List<Map<String, dynamic>> daily = card.list('daily');
    final List<String> details = <String>[
      if (card.number('apparent') != null)
        'feels ${card.number('apparent')!.round()}°',
      if (card.number('humidity') != null)
        '${card.number('humidity')!.round()} % humidity',
      if (card.number('wind') != null) '${card.number('wind')!.round()} km/h',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              temp == null ? '–' : '${temp.round()}°',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w300,
                height: 1,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (card.text('condition') != null)
                    Text(
                      card.text('condition')!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  if (details.isNotEmpty)
                    Text(
                      details.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (hourly.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          // A Row in a horizontal scroll takes its children's height, so
          // a larger text scale grows the strip instead of clipping it.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (int i = 0; i < hourly.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: 14),
                  _HourColumn(entry: hourly[i]),
                ],
              ],
            ),
          ),
        ],
        if (daily.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          for (final Map<String, dynamic> d in daily)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      <String>[
                        _day(d['date']),
                        '${d['condition'] ?? ''}',
                      ].where((String s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '${_round(d['min'])}° / ${_round(d['max'])}°',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  static String _round(Object? v) => v is num ? '${v.round()}' : '–';

  static const List<String> _weekdays = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
  ];

  /// `2026-09-29` -> "Tue"; anything else as it came.
  static String _day(Object? raw) {
    if (raw == null) return '';
    final DateTime? d = DateTime.tryParse('$raw');
    return d == null ? '$raw' : _weekdays[d.weekday - 1];
  }
}

class _HourColumn extends StatelessWidget {
  const _HourColumn({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime? t = DateTime.tryParse('${entry['time']}');
    final Object? rawTemp = entry['temp'];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t == null ? '' : t.hour.toString().padLeft(2, '0'),
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Text(
          rawTemp is num ? '${rawTemp.round()}°' : '–',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
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
