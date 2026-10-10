// Widget tests for the B2 charts: every chart renders at phone and
// desktop width in both themes, and bad, empty, mismatched or partial
// data never throws.
// ignore_for_file: experimental_member_use

import 'package:fl_chart/fl_chart.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/components/tables_charts/chart_common.dart';
import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

Future<void> _pump(
  WidgetTester tester,
  String source, {
  double width = 360,
  Brightness brightness = Brightness.dark,
  bool isStreaming = false,
}) async {
  await tester.pumpWidget(
    openUiTestApp(
      OpenUiView(
        source: source,
        isStreaming: isStreaming,
        actionHandler: RecordingOpenUiHandler(),
      ),
      brightness: brightness,
      width: width,
    ),
  );
  await tester.pumpAndSettle();
}

/// One sample per chart, with the widget type that must appear.
final Map<String, (String, Finder Function())>
_samples = <String, (String, Finder Function())>{
  'BarChart grouped': (
    'root = BarChart(["Jan", "Feb", "Mar"], [Series("Opened", [341, 327, 308]), '
        'Series("Resolved", [319, 318, 301])], "grouped", "Month", "Tickets")',
    () => find.byType(fl.BarChart),
  ),
  'BarChart stacked with negatives': (
    'root = BarChart(["A", "B", "C"], [Series("x", [5, -2, 3]), '
        'Series("y", [1, 4, -6])], "stacked")',
    () => find.byType(fl.BarChart),
  ),
  'LineChart natural': (
    'root = LineChart(["Mon", "Tue", "Wed", "Thu"], [Series("BTC", [61200, 62800, 61900, 63500])], "natural")',
    () => find.byType(fl.LineChart),
  ),
  'LineChart step': (
    'root = LineChart(["a", "b", "c"], [Series("s", [1, 3, 2])], "step", "x", "y", 300)',
    () => find.byType(fl.LineChart),
  ),
  'AreaChart': (
    'root = AreaChart(["Jan", "Feb", "Mar", "Apr"], [Series("Spend", [44, 46.8, 49.2, 51.6]), '
        'Series("Pipeline", [158.2, 171.5, 184.9, 196.1])], "natural", "Month", "Value")',
    () => find.byType(fl.LineChart),
  ),
  'RadarChart': (
    'root = RadarChart(["Speed", "Power", "Range", "Comfort", "Price"], '
        '[Series("Car A", [8, 6, 7, 5, 4]), Series("Car B", [6, 8, 5, 7, 6])])',
    () => find.byType(fl.RadarChart),
  ),
  'HorizontalBarChart': (
    'root = HorizontalBarChart(["Organic search with a long label", "Paid", "Email"], '
        '[Series("Revenue", [82.4, 68.1, 54.6])], "grouped", "Revenue (k)", "Channel")',
    () => find.text('Organic search with a long label'),
  ),
  'HorizontalBarChart stacked': (
    'root = HorizontalBarChart(["A", "B"], [Series("x", [1, 2]), Series("y", [3, 4])], "stacked")',
    () => find.text('B'),
  ),
  'PieChart donut': (
    'root = PieChart(["Rent", "Food", "Fun"], [1200, 450, 150], "donut")',
    () => find.text('Rent'),
  ),
  'PieChart semi': (
    'root = PieChart(["Rent", "Food"], [3, 1], "pie", "semiCircular")',
    () => find.text('75%'),
  ),
  'RadialChart': (
    'root = RadialChart(["Done", "Open", "Blocked"], [12, 5, 2])',
    () => find.text('Blocked'),
  ),
  'SingleStackedBarChart': (
    'root = SingleStackedBarChart(["Stocks", "Bonds", "Cash"], [60, 30, 10])',
    () => find.text('60%'),
  ),
  'ScatterChart': (
    'root = ScatterChart([ScatterSeries("A", [Point(1, 2), Point(2, 3), Point(3, 5, 9)]), '
        'ScatterSeries("B", [Point(1, 4), Point(4, 1)])], "Height", "Weight")',
    () => find.byType(fl.ScatterChart),
  ),
};

void main() {
  for (final entry in _samples.entries) {
    for (final width in <double>[360, 900]) {
      for (final b in Brightness.values) {
        testWidgets('${entry.key} renders at $width (${b.name})', (
          tester,
        ) async {
          await _pump(tester, entry.value.$1, width: width, brightness: b);
          expect(tester.takeException(), isNull);
          expect(entry.value.$2(), findsWidgets);
        });
      }
    }
  }

  testWidgets('a multi-series chart has a legend, one series has none', (
    tester,
  ) async {
    await _pump(
      tester,
      'root = BarChart(["a", "b"], [Series("Alpha", [1, 2]), Series("Beta", [2, 1])])',
    );
    expect(find.byType(ChartLegend), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    await _pump(
      tester,
      'root = BarChart(["a", "b"], [Series("Alpha", [1, 2])])',
    );
    expect(find.byType(ChartLegend), findsNothing);
  });

  testWidgets('axis titles are drawn', (tester) async {
    await _pump(
      tester,
      'root = LineChart(["a", "b"], [Series("s", [1, 2])], "linear", "Month", "Users")',
    );
    expect(find.text('Month'), findsOneWidget);
    expect(find.text('Users'), findsOneWidget);
  });

  testWidgets('PieChart reads the legacy Slice form', (tester) async {
    await _pump(
      tester,
      'root = PieChart([Slice("Cats", 3), Slice("Dogs", 1)], [])',
    );
    expect(find.text('Cats'), findsOneWidget);
    expect(find.text('Dogs'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
  });

  testWidgets('BarChart reads the table form (column names + rows)', (
    tester,
  ) async {
    await _pump(
      tester,
      'root = BarChart(["day", "views", "users"], [["Mon", 100, 50], ["Tue", 200, 75]])',
    );
    expect(find.byType(fl.BarChart), findsOneWidget);
    expect(find.text('views'), findsOneWidget);
    expect(find.text('users'), findsOneWidget);
  });

  testWidgets('RadarChart with two labels falls back to bars', (tester) async {
    await _pump(tester, 'root = RadarChart(["a", "b"], [Series("s", [1, 2])])');
    expect(find.byType(fl.RadarChart), findsNothing);
    expect(find.byType(fl.BarChart), findsOneWidget);
  });

  group('bad data does not throw', () {
    const bad = <String>[
      // empty
      'root = BarChart([], [])',
      'root = LineChart([], [Series("s", [])])',
      'root = AreaChart(null, null)',
      'root = RadarChart([], [])',
      'root = HorizontalBarChart([], [])',
      'root = PieChart([], [])',
      'root = RadialChart([], [])',
      'root = SingleStackedBarChart([], [])',
      'root = ScatterChart([])',
      // wrong types
      'root = BarChart("x", "y")',
      'root = BarChart([1, 2, 3], [Series("s", ["a", "4", null])])',
      'root = LineChart(["a", "b"], [Series(5, "nope")])',
      'root = PieChart(["a", "b"], ["x", -3])',
      'root = PieChart(["a", "b"], [0, 0])',
      'root = RadialChart(["a"], [-5])',
      'root = ScatterChart([ScatterSeries("A", [Point("x", 2), Point(null, null)])])',
      'root = ScatterChart("nope", 3, 4)',
      // mismatched lengths
      'root = BarChart(["a", "b", "c", "d"], [Series("s", [1])])',
      'root = LineChart(["a"], [Series("s", [1, 2, 3, 4])])',
      'root = AreaChart(["a", "b"], [Series("s", [1, 2]), Series("t", [9])], "step")',
      'root = RadarChart(["a", "b", "c", "d"], [Series("s", [1, 2])])',
      'root = PieChart(["a", "b", "c"], [5])',
      'root = SingleStackedBarChart(["a"], [1, 2, 3])',
      'root = HorizontalBarChart(["a", "b"], [Series("s", [1, null, 3])], "stacked")',
      // all equal or zero
      'root = BarChart(["a", "b"], [Series("s", [0, 0])])',
      'root = LineChart(["a", "b"], [Series("s", [5, 5])])',
      'root = RadarChart(["a", "b", "c"], [Series("s", [0, 0, 0])])',
      'root = ScatterChart([ScatterSeries("A", [Point(1, 1)])])',
      // huge and tiny
      'root = BarChart(["a", "b"], [Series("s", [1e14, 1e-9])])',
      'root = LineChart(["a", "b", "c"], [Series("s", [-1e9, 0.0001, 3e12])])',
    ];
    for (final source in bad) {
      testWidgets(source, (tester) async {
        await _pump(tester, source);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('many labels do not overflow at phone width', (tester) async {
    final labels = List<String>.generate(60, (i) => '"Label $i"').join(', ');
    final values = List<String>.generate(60, (i) => '${i * 3 % 17}').join(', ');
    await _pump(
      tester,
      'root = BarChart([$labels], [Series("s", [$values]), Series("t", [$values])])',
    );
    expect(tester.takeException(), isNull);
    await _pump(
      tester,
      'root = LineChart([$labels], [Series("s", [$values])], "natural")',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a partial (streaming) chart renders what is valid', (
    tester,
  ) async {
    const full =
        'root = BarChart(["Jan", "Feb", "Mar"], [Series("A", [1, 2, 3]), '
        'Series("B", [4, 5, 6])])';
    for (var cut = 10; cut <= full.length; cut += 7) {
      await _pump(tester, full.substring(0, cut), isStreaming: true);
      expect(tester.takeException(), isNull, reason: full.substring(0, cut));
    }
    await _pump(tester, full);
    expect(find.byType(fl.BarChart), findsOneWidget);
  });

  testWidgets('a streaming chart with no data yet keeps a placeholder', (
    tester,
  ) async {
    await _pump(tester, 'root = PieChart(["a", "b"], [', isStreaming: true);
    expect(tester.takeException(), isNull);
  });

  group('helpers', () {
    test('an axis with an unusable range falls back and ends', () {
      // -1e308..1e308 overflows to Infinity; 1e17..1e17+10 has a step
      // that does not move the value. Both looped forever before.
      for (final (lo, hi) in <(double, double)>[
        (-1e308, 1e308),
        (1e17, 1e17 + 10),
      ]) {
        final scale = AxisScale.fit(lo, hi, fromZero: false);
        expect(scale.interval, greaterThan(0));
        expect(scale.max + scale.interval, isNot(scale.max));
      }
    });

    test('formatAxisValue is compact', () {
      expect(formatAxisValue(0), '0');
      expect(formatAxisValue(1500), '1500');
      expect(formatAxisValue(15000), '15K');
      expect(formatAxisValue(2000000), '2M');
      expect(formatAxisValue(2.5), '2.5');
    });

    test('formatChartValue groups thousands', () {
      expect(formatChartValue(1234567.891), '1,234,567.89');
      expect(formatChartValue(3), '3');
    });

    test('AxisScale is round and includes the data', () {
      final s = AxisScale.fit(-3, 47);
      expect(s.min, lessThanOrEqualTo(-3));
      expect(s.max, greaterThanOrEqualTo(47));
      expect(s.max % s.interval, closeTo(0, 1e-9));
      final flat = AxisScale.fit(5, 5);
      expect(flat.max, greaterThan(flat.min));
    });

    test('chartNumber reads numeric strings', () {
      expect(chartNumber('1,234'), 1234);
      expect(chartNumber('12%'), 12);
      expect(chartNumber('x'), isNull);
      expect(chartNumber(double.nan), isNull);
    });
  });
}
