import 'dart:convert';

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

/// Parse a hex color string like "#FF5722" or "FF5722" into a Color.
Color _parseColor(String hex) {
  hex = hex.replaceAll('#', '');
  if (hex.length == 6) hex = 'FF$hex';
  return Color(int.parse(hex, radix: 16));
}

Color _colorAt(int index) => _defaultColors[index % _defaultColors.length];

/// Top-level widget: parses a JSON map and picks the right chart builder.
///
/// Supports bar, line, pie, scatter, and radar chart types via fl_chart.
class ChartRenderer extends StatelessWidget {
  final Map<String, dynamic> data;

  const ChartRenderer({super.key, required this.data});

  /// Convenience: try to parse a raw JSON string. Returns null on failure.
  static ChartRenderer? tryParse(String jsonString) {
    try {
      final parsed = jsonDecode(jsonString);
      if (parsed is Map<String, dynamic> && parsed.containsKey('type')) {
        return ChartRenderer(data: parsed);
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final type = (data['type'] as String?)?.toLowerCase() ?? '';
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
          if (type == 'pie') _buildPieLegend(context),
        ],
      ),
    );
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
    final labels = (data['labels'] as List?)?.cast<String>() ?? [];
    final datasets = (data['datasets'] as List?) ?? [];
    final maxY = (data['max_y'] as num?)?.toDouble();

    final groups = <BarChartGroupData>[];
    for (var i = 0; i < labels.length; i++) {
      final rods = <BarChartRodData>[];
      for (var ds = 0; ds < datasets.length; ds++) {
        final dsMap = datasets[ds] as Map<String, dynamic>;
        final values = (dsMap['data'] as List).cast<num>();
        final color = dsMap['color'] != null
            ? _parseColor(dsMap['color'] as String)
            : _colorAt(ds);
        if (i < values.length) {
          rods.add(
            BarChartRodData(
              toY: values[i].toDouble(),
              color: color,
              width: datasets.length > 1 ? 12 : 22,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
            ),
          );
        }
      }
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
        maxY: maxY,
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
              return BarTooltipItem(
                '$label\n${_formatAxisValue(rod.toY)}',
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
    final labels = (data['labels'] as List?)?.cast<String>() ?? [];
    final datasets = (data['datasets'] as List?) ?? [];
    final maxY = (data['max_y'] as num?)?.toDouble();
    final minY = (data['min_y'] as num?)?.toDouble();

    int maxDataLen = 0;
    final lines = <LineChartBarData>[];
    for (var ds = 0; ds < datasets.length; ds++) {
      final dsMap = datasets[ds] as Map<String, dynamic>;
      final values = (dsMap['data'] as List).cast<num>();
      if (values.length > maxDataLen) maxDataLen = values.length;
      final color = dsMap['color'] != null
          ? _parseColor(dsMap['color'] as String)
          : _colorAt(ds);
      final curved = dsMap['curved'] as bool? ?? true;

      final spots = <FlSpot>[];
      for (var i = 0; i < values.length; i++) {
        spots.add(FlSpot(i.toDouble(), values[i].toDouble()));
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
    final items = (data['data'] as List?) ?? [];

    final sections = <PieChartSectionData>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i] as Map<String, dynamic>;
      final value = (item['value'] as num).toDouble();
      final color = item['color'] != null
          ? _parseColor(item['color'] as String)
          : _colorAt(i);

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

  Widget _buildPieLegend(BuildContext context) {
    final items = (data['data'] as List?) ?? [];
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
                    color: (items[i] as Map)['color'] != null
                        ? _parseColor((items[i] as Map)['color'] as String)
                        : _colorAt(i),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  (items[i] as Map)['label'] as String? ?? '',
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
    final datasets = (data['datasets'] as List?) ?? [];
    final maxX = (data['max_x'] as num?)?.toDouble();
    final maxY = (data['max_y'] as num?)?.toDouble();
    final minX = (data['min_x'] as num?)?.toDouble();
    final minY = (data['min_y'] as num?)?.toDouble();

    final spots = <ScatterSpot>[];
    for (var ds = 0; ds < datasets.length; ds++) {
      final dsMap = datasets[ds] as Map<String, dynamic>;
      final points = (dsMap['data'] as List?) ?? [];
      final color = dsMap['color'] != null
          ? _parseColor(dsMap['color'] as String)
          : _colorAt(ds);
      final radius = (dsMap['radius'] as num?)?.toDouble() ?? 6;

      for (final pt in points) {
        final p = pt as Map<String, dynamic>;
        spots.add(
          ScatterSpot(
            (p['x'] as num).toDouble(),
            (p['y'] as num).toDouble(),
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
    final labels = (data['labels'] as List?)?.cast<String>() ?? [];
    final datasets = (data['datasets'] as List?) ?? [];
    final maxValue = (data['max_value'] as num?)?.toDouble() ?? 5;

    final dataSets = <RadarDataSet>[];
    for (var ds = 0; ds < datasets.length; ds++) {
      final dsMap = datasets[ds] as Map<String, dynamic>;
      final values = (dsMap['data'] as List).cast<num>();
      final color = dsMap['color'] != null
          ? _parseColor(dsMap['color'] as String)
          : _colorAt(ds);

      dataSets.add(
        RadarDataSet(
          dataEntries: values
              .map((v) => RadarEntry(value: v.toDouble()))
              .toList(),
          fillColor: color.withValues(alpha: 0.15),
          borderColor: color,
          borderWidth: 2,
          entryRadius: 3,
        ),
      );
    }

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
