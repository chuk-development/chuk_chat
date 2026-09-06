import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Default color palette for charts when the AI doesn't specify colors.
const List<Color> _defaultColors = [
  Color(0xFF2196F3), // blue
  Color(0xFFF44336), // red
  Color(0xFF4CAF50), // green
  Color(0xFFFF9800), // orange
  Color(0xFF9C27B0), // purple
  Color(0xFF00BCD4), // cyan
  Color(0xFFFFEB3B), // yellow
  Color(0xFFE91E63), // pink
  Color(0xFF8BC34A), // light green
  Color(0xFF3F51B5), // indigo
];

/// Parse a hex color like "#FF5722", "FF5722" or "#CCFF5722" into a Color.
///
/// Returns null for anything else. Colors arrive as model output, so "blue"
/// or a truncated value is a normal input, not a reason to take the message
/// down with a FormatException.
Color? _tryParseColor(Object? raw) {
  if (raw is! String) return null;
  var hex = raw.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  return Color(int.parse(hex, radix: 16));
}

Color _colorAt(int index) => _defaultColors[index % _defaultColors.length];

/// Normalize the shorthand chart shapes the model may emit into the canonical
/// `type` + `labels` + `datasets` form.
///
/// The short form is one bar per row, each with its own color — the shape a
/// result table has (a party, its share, its own official color):
///
///     {"title": "...", "rows": [{"label": "AfD", "value": 44.8,
///                                "color": "#80cdec"}, ...]}
///
/// `type` defaults to `bar` because a row list is a bar chart; an explicit
/// `type`, `labels` or `datasets` always wins and passes through untouched.
Map<String, dynamic> normalizeChartData(Map<String, dynamic> raw) {
  final rows = raw['rows'];
  final rawType = raw['type'];
  final type = rawType is String ? rawType.toLowerCase() : null;
  if (rows is! List || raw.containsKey('datasets') || raw.containsKey('data')) {
    if (rawType is! String && raw.containsKey('labels')) {
      return <String, dynamic>{...raw, 'type': 'bar'};
    }
    return raw;
  }
  // A row list is a category and a value. That is a bar chart, and it maps
  // just as well onto a pie; a scatter needs x/y pairs, so it is left alone
  // and the block stays prose rather than rendering an empty frame.
  const rowShapes = {null, 'bar', 'line', 'radar', 'pie'};
  if (!rowShapes.contains(type)) return raw;

  final labels = <String>[];
  final values = <num>[];
  final colors = <String?>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final value = row['value'];
    final numeric = value is num ? value : num.tryParse('$value');
    if (numeric == null) continue;
    labels.add((row['label'] ?? row['party'] ?? '').toString());
    values.add(numeric);
    final color = row['color'];
    colors.add(color is String && color.trim().isNotEmpty ? color : null);
  }
  if (labels.isEmpty) return raw;

  if (type == 'pie') {
    return <String, dynamic>{
      ...raw,
      'type': 'pie',
      'data': [
        for (var i = 0; i < labels.length; i++)
          <String, dynamic>{
            'label': labels[i],
            'value': values[i],
            if (colors[i] != null) 'color': colors[i],
          },
      ],
    }..remove('rows');
  }

  final dataset = <String, dynamic>{
    'label': (raw['series_label'] ?? raw['value_label'] ?? '').toString(),
    'data': values,
  };
  if (colors.any((c) => c != null)) dataset['colors'] = colors;

  return <String, dynamic>{
    ...raw,
    'type': type ?? 'bar',
    'labels': labels,
    'datasets': [dataset],
  }..remove('rows');
}

/// Top-level widget: parses a JSON map and picks the right chart builder.
///
/// Supports bar, line, pie, scatter, and radar chart types via fl_chart.
class ChartRenderer extends StatelessWidget {
  final Map<String, dynamic> data;

  ChartRenderer({super.key, required Map<String, dynamic> data})
      : data = normalizeChartData(data);

  /// Convenience: try to parse a raw JSON string. Returns null on failure.
  ///
  /// A map counts as a chart when it names its `type`, or when it carries the
  /// data of one (`rows` or `labels`) — the short row form has no `type`.
  static ChartRenderer? tryParse(String jsonString) {
    try {
      final parsed = jsonDecode(jsonString);
      if (parsed is Map<String, dynamic> &&
          (parsed.containsKey('type') ||
              parsed['rows'] is List ||
              parsed['labels'] is List)) {
        return ChartRenderer(data: parsed);
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final rawType = data['type'];
    final type = rawType is String ? rawType.toLowerCase() : '';
    final title = data['title'] as String?;
    final height = (data['height'] as num?)?.toDouble() ?? 250;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          SizedBox(height: height, child: _buildChart(type, context)),
          if (type == 'pie')
            _buildPieLegend(context)
          else
            _buildDatasetLegend(context),
          _buildFooter(context),
        ],
      ),
    );
  }

  /// Caption and provenance under the chart.
  ///
  /// A result chart is only as good as its source: when the data carries a
  /// `caption`, a `source_url` or a `retrieved_at`, they belong on the chart,
  /// not in the prose around it.
  Widget _buildFooter(BuildContext context) {
    final theme = Theme.of(context);
    String stringField(String key) {
      final value = data[key];
      return value is String ? value.trim() : '';
    }

    final caption = stringField('caption');
    final source = stringField('source_url');
    final retrieved = stringField('retrieved_at');
    final provenance = [
      if (retrieved.isNotEmpty) retrieved,
      if (source.isNotEmpty) source,
    ].join(' · ');
    if (caption.isEmpty && provenance.isEmpty) return const SizedBox.shrink();

    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 11,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (caption.isNotEmpty) Text(caption, style: style),
          if (provenance.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: caption.isEmpty ? 0 : 2),
              child: Text(provenance, style: style),
            ),
        ],
      ),
    );
  }

  /// Pick a "nice" axis interval covering the given range with ~targetTicks
  /// labels — avoids fl_chart drawing crowded labels like 14 / 14.5 next to
  /// each other when the data range is small.
  static double _niceInterval(double range, {int targetTicks = 5}) {
    if (range <= 0 || !range.isFinite) return 1;
    final raw = range / targetTicks;
    final exponent = (math.log(raw) / math.ln10).floor();
    final pow10 = math.pow(10, exponent).toDouble();
    final mantissa = raw / pow10;
    double nice;
    if (mantissa < 1.5) {
      nice = 1;
    } else if (mantissa < 3) {
      nice = 2;
    } else if (mantissa < 7) {
      nice = 5;
    } else {
      nice = 10;
    }
    return nice * pow10;
  }

  /// The axis labels as strings. A model may send numbers as labels, and a
  /// blind `cast<String>()` throws mid-render on exactly that.
  static List<String> _labelsOf(Map<String, dynamic> data) {
    final raw = data['labels'];
    if (raw is! List) return const [];
    return [for (final label in raw) '$label'];
  }

  /// The pie/scatter-style items that carry a label and a numeric value.
  static List<Map<String, dynamic>> _pieItemsOf(Map<String, dynamic> data) {
    final raw = data['data'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map && item['value'] is num) Map<String, dynamic>.from(item),
    ];
  }

  /// The datasets that are really maps. A malformed entry is skipped, never
  /// cast blindly: a chart arrives as model output, and one bad field must not
  /// take the whole chat message down.
  static List<Map<String, dynamic>> _datasetsOf(Map<String, dynamic> data) {
    final raw = data['datasets'];
    if (raw is! List) return const [];
    return [
      for (final ds in raw)
        if (ds is Map) Map<String, dynamic>.from(ds),
    ];
  }

  /// The values of one dataset, position for position: index i still lines up
  /// with label i. An entry that is not a number becomes null and its bar,
  /// point or spoke is skipped — a stray string must not shift the series.
  static List<num?> _valuesOf(Map<String, dynamic> dataset) {
    final raw = dataset['data'];
    if (raw is! List) return const [];
    return [
      for (final v in raw) v is num ? v : num.tryParse('$v'),
    ];
  }

  /// True when this map holds at least one number to draw. Used to decide
  /// whether a `<chart>` block is a chart at all.
  static bool hasPlottableData(Map<String, dynamic> data) {
    for (final ds in _datasetsOf(data)) {
      if (_valuesOf(ds).whereType<num>().isNotEmpty) return true;
      final points = ds['data'];
      if (points is List) {
        for (final point in points) {
          // A scatter point is a pair; one half of it draws nothing.
          if (point is Map && point['x'] is num && point['y'] is num) return true;
        }
      }
    }
    for (final item in _pieItemsOf(data)) {
      if (item['value'] is num) return true;
    }
    return false;
  }

  /// Largest numeric value across every dataset's `data` list.
  /// Returns 0 if no datasets/values are present.
  static double _maxYFromDatasets(List<dynamic> datasets) {
    double m = 0;
    for (final ds in datasets) {
      if (ds is! Map) continue;
      final values = ds['data'];
      if (values is! List) continue;
      for (final v in values) {
        final d = v is num ? v.toDouble() : double.tryParse('$v');
        if (d != null && d > m) m = d;
      }
    }
    return m;
  }

  /// Format axis values compactly: 1500 -> "1.5K", 2000000 -> "2M", etc.
  static String _formatAxisValue(double value) {
    if (value == 0) return '0';
    final abs = value.abs();
    if (abs >= 1e12) return '${(value / 1e12).toStringAsFixed(1)}T';
    if (abs >= 1e9) return '${(value / 1e9).toStringAsFixed(1)}B';
    if (abs >= 1e6) return '${(value / 1e6).toStringAsFixed(1)}M';
    if (abs >= 1e4) return '${(value / 1e3).toStringAsFixed(1)}K';
    if (value % 1 == 0) return value.toInt().toString();
    if (abs >= 100) return value.toStringAsFixed(0);
    if (abs >= 10) return value.toStringAsFixed(1);
    return value.toStringAsFixed(2);
  }

  Widget _buildChart(String type, BuildContext context) {
    switch (type) {
      case 'bar':
        return _buildBarChart(context);
      case 'line':
        return _buildLineChart(context);
      case 'pie':
        return _buildPieChart(context);
      case 'scatter':
        return _buildScatterChart(context);
      case 'radar':
        return _buildRadarChart(context);
      default:
        return Center(
          child: Text(
            'Unsupported chart type: $type',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
    }
  }

  // ---------------------------------------------------------------------------
  // BAR CHART
  // ---------------------------------------------------------------------------
  Widget _buildBarChart(BuildContext context) {
    final labels = _labelsOf(data);
    final datasets = _datasetsOf(data);
    final providedMaxY = (data['max_y'] as num?)?.toDouble();
    final double dataMaxY = _maxYFromDatasets(datasets);
    final double yInterval = _niceInterval((providedMaxY ?? dataMaxY).abs());
    // Round up to a multiple of yInterval so fl_chart doesn't add a stray
    // label one tick above the highest bar (e.g. "21" sitting on top of
    // "20" when the data tops out at 20.7).
    final double computedMaxY = providedMaxY ??
        (yInterval > 0
            ? ((dataMaxY / yInterval).ceilToDouble() * yInterval)
            : dataMaxY);

    final groups = <BarChartGroupData>[];
    // A dataset with no value for this category contributes no rod, so the
    // rod index is not the dataset index. Keep the source dataset per rod so
    // the tooltip names the series the bar actually came from.
    final rodSources = <int, List<int>>{};
    for (var i = 0; i < labels.length; i++) {
      final rods = <BarChartRodData>[];
      final sources = <int>[];
      for (var ds = 0; ds < datasets.length; ds++) {
        final dsMap = datasets[ds];
        final values = _valuesOf(dsMap);
        // `colors` gives every bar its own color (one row = one party); a
        // single `color` paints the whole series. Missing entries fall back
        // to the series color, then to the palette.
        final perBar = dsMap['colors'];
        final barColor = (perBar is List && i < perBar.length) ? perBar[i] : null;
        final color = _tryParseColor(barColor) ??
            _tryParseColor(dsMap['color']) ??
            _colorAt(ds);
        final value = i < values.length ? values[i] : null;
        if (value != null) {
          sources.add(ds);
          rods.add(
            BarChartRodData(
              toY: value.toDouble(),
              color: color,
              width: datasets.length > 1 ? 12 : 22,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
            ),
          );
        }
      }
      rodSources[i] = sources;
      groups.add(BarChartGroupData(x: i, barRods: rods));
    }

    final double barLabelInterval;
    if (labels.length <= 12) {
      barLabelInterval = 1;
    } else {
      barLabelInterval = (labels.length / 10).ceilToDouble();
    }

    return BarChart(
      BarChartData(
        maxY: computedMaxY,
        barGroups: groups,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: barLabelInterval,
              reservedSize: labels.length > 20 ? 32 : 24,
              getTitlesWidget: (value, _) {
                final idx = value.toInt();
                if (idx >= 0 && idx < labels.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Transform.rotate(
                      angle: labels.length > 20 ? -0.5 : 0,
                      child: Text(
                        labels[idx],
                        style: TextStyle(
                          fontSize: labels.length > 50 ? 8 : 10,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: yInterval,
              reservedSize: 48,
              getTitlesWidget: (value, _) => Text(
                _formatAxisValue(value),
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItem: (group, gIdx, rod, rIdx) {
              final label = gIdx < labels.length ? labels[gIdx] : '';
              final sources = rodSources[group.x] ?? const <int>[];
              final dsIdx = rIdx < sources.length ? sources[rIdx] : -1;
              final dsLabel = dsIdx >= 0 && dsIdx < datasets.length
                  ? '${datasets[dsIdx]['label'] ?? ''}'.trim()
                  : '';
              final valueText = _formatAxisValue(rod.toY);
              final body = dsLabel.isEmpty
                  ? valueText
                  : '$dsLabel: $valueText';
              return BarTooltipItem(
                '$label\n$body',
                TextStyle(
                  color: rod.color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // LINE CHART
  // ---------------------------------------------------------------------------
  Widget _buildLineChart(BuildContext context) {
    final labels = _labelsOf(data);
    final datasets = _datasetsOf(data);
    final maxY = (data['max_y'] as num?)?.toDouble();
    final minY = (data['min_y'] as num?)?.toDouble();
    final double yInterval = _niceInterval(
      ((maxY ?? _maxYFromDatasets(datasets)) - (minY ?? 0)).abs(),
    );

    int maxDataLen = 0;
    final lines = <LineChartBarData>[];
    for (var ds = 0; ds < datasets.length; ds++) {
      final dsMap = datasets[ds];
      final values = _valuesOf(dsMap);
      if (values.length > maxDataLen) maxDataLen = values.length;
      final color = _tryParseColor(dsMap['color']) ?? _colorAt(ds);
      final curved = dsMap['curved'] as bool? ?? true;

      final spots = <FlSpot>[];
      for (var i = 0; i < values.length; i++) {
        final value = values[i];
        // A missing value is a gap, not a shortcut: nullSpot breaks the line
        // there instead of drawing straight over the hole.
        spots.add(
          value == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), value.toDouble()),
        );
      }

      lines.add(
        LineChartBarData(
          spots: spots,
          isCurved: curved,
          color: color,
          barWidth: maxDataLen > 100 ? 1.5 : 2.5,
          isStrokeCapRound: true,
          dotData: FlDotData(show: maxDataLen <= 20),
          belowBarData: BarAreaData(
            show: datasets.length == 1,
            color: color.withValues(alpha: 0.12),
          ),
        ),
      );
    }

    final labelCount = labels.isNotEmpty ? labels.length : maxDataLen;
    final double labelInterval;
    if (labelCount <= 12) {
      labelInterval = 1;
    } else {
      labelInterval = (labelCount / 10).ceilToDouble();
    }

    return LineChart(
      LineChartData(
        maxY: maxY,
        minY: minY,
        lineBarsData: lines,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: labels.isNotEmpty,
              interval: labelInterval,
              reservedSize: labelCount > 20 ? 32 : 24,
              getTitlesWidget: (value, _) {
                final idx = value.toInt();
                if (idx >= 0 && idx < labels.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Transform.rotate(
                      angle: labelCount > 20 ? -0.5 : 0,
                      child: Text(
                        labels[idx],
                        style: TextStyle(
                          fontSize: labelCount > 50 ? 8 : 10,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: yInterval,
              reservedSize: 48,
              getTitlesWidget: (value, _) => Text(
                _formatAxisValue(value),
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: (spots) => spots.map((spot) {
              final dsIdx = spot.barIndex;
              final dsLabel = dsIdx < datasets.length
                  ? (datasets[dsIdx] as Map)['label'] ?? ''
                  : '';
              final idx = spot.x.toInt();
              final xLabel = (idx >= 0 && idx < labels.length)
                  ? labels[idx]
                  : '';
              final yFormatted = spot.y >= 1000
                  ? spot.y.toStringAsFixed(0)
                  : spot.y.toStringAsFixed(2);
              return LineTooltipItem(
                '${xLabel.isNotEmpty ? "$xLabel\n" : ""}$dsLabel: $yFormatted',
                TextStyle(
                  color: spot.bar.color ?? _colorAt(dsIdx),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PIE CHART
  // ---------------------------------------------------------------------------
  Widget _buildPieChart(BuildContext context) {
    final items = _pieItemsOf(data);

    final sections = <PieChartSectionData>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final value = (item['value'] as num).toDouble();
      final color = _tryParseColor(item['color']) ?? _colorAt(i);

      sections.add(
        PieChartSectionData(
          value: value,
          color: color,
          title: value.toStringAsFixed(value % 1 == 0 ? 0 : 1),
          titleStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          radius: 80,
          titlePositionPercentageOffset: 0.55,
        ),
      );
    }

    return PieChart(
      PieChartData(
        sections: sections,
        sectionsSpace: 2,
        centerSpaceRadius: 40,
        pieTouchData: PieTouchData(touchCallback: (_, _) {}),
      ),
    );
  }

  /// Generic legend for bar/line/scatter/radar charts with named datasets.
  /// Shown only when at least one dataset has a non-empty `label`.
  Widget _buildDatasetLegend(BuildContext context) {
    final datasets = _datasetsOf(data);
    if (datasets.length < 2) return const SizedBox.shrink();

    final entries = <(String, Color)>[];
    for (var i = 0; i < datasets.length; i++) {
      final ds = datasets[i];
      final label = (ds['label'] as String?)?.trim() ?? '';
      if (label.isEmpty) continue;
      final color = _tryParseColor(ds['color']) ?? _colorAt(i);
      entries.add((label, color));
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          for (final entry in entries)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: entry.$2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  entry.$1,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildPieLegend(BuildContext context) {
    final items = _pieItemsOf(data);
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          for (var i = 0; i < items.length; i++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _tryParseColor(items[i]['color']) ?? _colorAt(i),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${items[i]['label'] ?? ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SCATTER CHART
  // ---------------------------------------------------------------------------
  Widget _buildScatterChart(BuildContext context) {
    final datasets = _datasetsOf(data);
    final maxX = (data['max_x'] as num?)?.toDouble();
    final maxY = (data['max_y'] as num?)?.toDouble();
    final minX = (data['min_x'] as num?)?.toDouble();
    final minY = (data['min_y'] as num?)?.toDouble();

    final spots = <ScatterSpot>[];
    for (var ds = 0; ds < datasets.length; ds++) {
      final dsMap = datasets[ds];
      final points = (dsMap['data'] as List?) ?? const [];
      final color = _tryParseColor(dsMap['color']) ?? _colorAt(ds);
      final radius = (dsMap['radius'] as num?)?.toDouble() ?? 6;

      for (final pt in points) {
        if (pt is! Map) continue;
        final x = pt['x'];
        final y = pt['y'];
        if (x is! num || y is! num) continue;
        spots.add(
          ScatterSpot(
            x.toDouble(),
            y.toDouble(),
            dotPainter: FlDotCirclePainter(color: color, radius: radius),
          ),
        );
      }
    }

    return ScatterChart(
      ScatterChartData(
        scatterSpots: spots,
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              getTitlesWidget: (value, _) => Text(
                value % 1 == 0
                    ? value.toInt().toString()
                    : value.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, _) => Text(
                value % 1 == 0
                    ? value.toInt().toString()
                    : value.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        scatterTouchData: ScatterTouchData(
          touchTooltipData: ScatterTouchTooltipData(
            getTooltipItems: (spot) {
              return ScatterTooltipItem(
                '(${spot.x}, ${spot.y})',
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // RADAR CHART
  // ---------------------------------------------------------------------------
  Widget _buildRadarChart(BuildContext context) {
    final labels = _labelsOf(data);
    final datasets = _datasetsOf(data);
    final maxValue = (data['max_value'] as num?)?.toDouble() ?? 5;

    final dataSets = <RadarDataSet>[];
    for (var ds = 0; ds < datasets.length; ds++) {
      final dsMap = datasets[ds];
      final values = _valuesOf(dsMap);
      // A radar ring is one closed shape: a missing value would either shift
      // every following spoke or invent a zero. Skip the whole series instead.
      if (values.isEmpty || values.any((v) => v == null)) continue;
      final color = _tryParseColor(dsMap['color']) ?? _colorAt(ds);

      dataSets.add(
        RadarDataSet(
          dataEntries: values
              .map((v) => RadarEntry(value: v!.toDouble()))
              .toList(),
          fillColor: color.withValues(alpha: 0.15),
          borderColor: color,
          borderWidth: 2,
          entryRadius: 3,
        ),
      );
    }

    if (dataSets.isEmpty) return const SizedBox.shrink();

    return RadarChart(
      RadarChartData(
        dataSets: dataSets,
        radarBackgroundColor: Colors.transparent,
        borderData: FlBorderData(show: false),
        radarBorderData: const BorderSide(color: Colors.grey, width: 0.5),
        tickBorderData: const BorderSide(color: Colors.grey, width: 0.5),
        gridBorderData: const BorderSide(color: Colors.grey, width: 0.5),
        tickCount: maxValue.toInt(),
        ticksTextStyle: TextStyle(
          fontSize: 9,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        titleTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        getTitle: (index, _) {
          if (index < labels.length) {
            return RadarChartTitle(text: labels[index]);
          }
          return const RadarChartTitle(text: '');
        },
        titlePositionPercentageOffset: 0.2,
      ),
    );
  }
}
