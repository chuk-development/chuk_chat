// Home chart: the agent's ChukChart spec, the same renderer as a `<chart>`
// tag in a message (lib/widgets/charts/chuk_chart.dart).

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/widgets/charts/chuk_chart.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';

class ChartTile extends StatelessWidget {
  const ChartTile({
    super.key,
    required this.chart,
    required this.now,
    this.animate = true,
  });

  final ChartWidget chart;
  final DateTime now;

  /// False draws the finished chart at once (goldens).
  final bool animate;

  @override
  Widget build(BuildContext context) {
    // The card carries the title; a spec title that only repeats it is
    // dropped, a different one stays as the chart's own heading.
    final Map<String, dynamic> json = Map<String, dynamic>.of(chart.spec);
    if ((json['title'] as Object?)?.toString().trim() == chart.title.trim()) {
      json.remove('title');
    }
    // A tile keeps a tile's height on a wide window too.
    json['height'] ??= 180;
    // One series with no colours of its own draws in the accent, so a
    // Home tile stays calm instead of a rainbow of bars.
    final Object? points = json['points'];
    if (json['series'] == null &&
        json['kind'] != 'column_delta' &&
        points is List &&
        points.every((Object? p) => p is Map && p['color'] == null)) {
      final int rgb =
          Theme.of(context).colorScheme.primary.toARGB32() & 0xFFFFFF;
      final String hex = '#${rgb.toRadixString(16).padLeft(6, '0')}';
      json['points'] = <Object?>[
        for (final Object? p in points)
          <String, dynamic>{
            ...Map<String, dynamic>.from(p! as Map),
            'color': hex,
          },
      ];
    }
    return DashboardCard(
      widget: chart,
      now: now,
      leading: DashboardBadge(
        icon: dashboardTypeIcon(DashboardWidgetType.chart),
      ),
      child: ChukChart(
        spec: ChartSpec.parse(json),
        animate: animate,
        framed: false,
      ),
    );
  }
}
