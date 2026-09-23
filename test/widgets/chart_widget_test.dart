import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/chart_widget.dart';

Future<void> _pumpChart(WidgetTester tester, Map<String, dynamic> data) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 600, child: ChartRenderer(data: data)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('normalizeChartData', () {
    test('turns rows into labels + one dataset with per-bar colors', () {
      final normalized = normalizeChartData({
        'title': 'Zweitstimmen',
        'rows': [
          {'label': 'AfD', 'value': 44.8, 'color': '#80cdec'},
          {'label': 'CDU', 'value': 16.8, 'color': '#576164'},
        ],
      });

      expect(normalized['type'], 'bar');
      expect(normalized.containsKey('rows'), isFalse);
      expect(normalized['labels'], ['AfD', 'CDU']);
      final dataset = (normalized['datasets'] as List).single as Map;
      expect(dataset['data'], [44.8, 16.8]);
      expect(dataset['colors'], ['#80cdec', '#576164']);
    });

    test('an explicit datasets form passes through untouched', () {
      final raw = <String, dynamic>{
        'type': 'line',
        'labels': ['a'],
        'datasets': [
          {'data': [1]},
        ],
      };

      expect(normalizeChartData(raw), same(raw));
    });

    test('rows without a numeric value are dropped, not zeroed', () {
      final normalized = normalizeChartData({
        'rows': [
          {'label': 'AfD', 'value': 44.8},
          {'label': 'HEIMAT', 'value': null},
        ],
      });

      expect(normalized['labels'], ['AfD']);
      expect(((normalized['datasets'] as List).single as Map)['data'], [44.8]);
    });

    test('a pie row list becomes pie data, colors kept', () {
      final normalized = normalizeChartData({
        'type': 'pie',
        'rows': [
          {'label': 'AfD', 'value': 44.8, 'color': '#80cdec'},
          {'label': 'CDU', 'value': 16.8},
        ],
      });

      expect(normalized.containsKey('rows'), isFalse);
      expect(normalized['data'], [
        {'label': 'AfD', 'value': 44.8, 'color': '#80cdec'},
        {'label': 'CDU', 'value': 16.8},
      ]);
    });

    test('a scatter row list is left alone — rows are not x/y pairs', () {
      final raw = <String, dynamic>{
        'type': 'scatter',
        'rows': [
          {'label': 'a', 'value': 1},
        ],
      };

      expect(normalizeChartData(raw), same(raw));
      expect(ChartRenderer.hasPlottableData(normalizeChartData(raw)), isFalse);
    });

    test('a non-string type falls back to bar instead of throwing', () {
      final normalized = normalizeChartData({
        'type': 42,
        'rows': [
          {'label': 'a', 'value': 1},
        ],
      });

      expect(normalized['type'], 'bar');
      expect(normalized['labels'], ['a']);
    });
  });

  group('hasPlottableData', () {
    test('false when a dataset carries no data list', () {
      expect(
        ChartRenderer.hasPlottableData({
          'type': 'bar',
          'labels': ['a'],
          'datasets': [
            {'label': 'x'},
          ],
        }),
        isFalse,
      );
    });

    test('true for a pie chart data list', () {
      expect(
        ChartRenderer.hasPlottableData({
          'type': 'pie',
          'data': [
            {'label': 'a', 'value': 1},
          ],
        }),
        isTrue,
      );
    });

    test('a scatter dataset without numeric x/y is not plottable', () {
      expect(
        ChartRenderer.hasPlottableData({
          'type': 'scatter',
          'datasets': [
            {
              'data': [
                {'x': 'n/a'},
              ],
            },
          ],
        }),
        isFalse,
      );
    });

    test('true for a scatter dataset with a real point', () {
      expect(
        ChartRenderer.hasPlottableData({
          'type': 'scatter',
          'datasets': [
            {
              'data': [
                {'x': 1, 'y': 2},
              ],
            },
          ],
        }),
        isTrue,
      );
    });

    test('a scatter dataset of bare numbers is not plottable', () {
      expect(
        ChartRenderer.hasPlottableData({
          'type': 'scatter',
          'datasets': [
            {
              'data': [1, 2, 3],
            },
          ],
        }),
        isFalse,
      );
    });
  });

  testWidgets('renders a row chart with its caption and source', (tester) async {
    await _pumpChart(tester, {
      'title': 'Zweitstimmen',
      'rows': [
        {'label': 'AfD', 'value': 44.8, 'color': '#80cdec'},
        {'label': 'CDU', 'value': 16.8, 'color': '#576164'},
      ],
      'caption': '2505 von 2660 Wahlbezirken',
      'retrieved_at': '06.09.2026 22:25 Uhr',
      'source_url': 'https://example.test/erg',
    });

    expect(find.text('Zweitstimmen'), findsOneWidget);
    expect(find.text('2505 von 2660 Wahlbezirken'), findsOneWidget);
    expect(
      find.text('06.09.2026 22:25 Uhr · https://example.test/erg'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dataset without data draws nothing and does not throw',
      (tester) async {
    await _pumpChart(tester, {
      'type': 'bar',
      'labels': ['a', 'b'],
      'datasets': [
        {'label': 'broken'},
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a non-numeric value keeps the other bars in place',
      (tester) async {
    await _pumpChart(tester, {
      'type': 'bar',
      'labels': ['a', 'b', 'c'],
      'datasets': [
        {
          'data': [1, 'n/a', 3],
        },
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a bogus color falls back instead of throwing', (tester) async {
    await _pumpChart(tester, {
      'rows': [
        {'label': 'a', 'value': 1, 'color': 'blue'},
        {'label': 'b', 'value': 2, 'color': '#zzzzzz'},
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a malformed sibling dataset does not break the chart',
      (tester) async {
    await _pumpChart(tester, {
      'type': 'bar',
      'labels': ['a'],
      'datasets': [
        {'data': [1]},
        'bad',
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a radar series with a gap is skipped, not shifted',
      (tester) async {
    await _pumpChart(tester, {
      'type': 'radar',
      'labels': ['a', 'b', 'c'],
      'datasets': [
        {
          'data': [1, 'n/a', 3],
        },
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a pie entry without a numeric value is dropped', (tester) async {
    await _pumpChart(tester, {
      'type': 'pie',
      'data': [
        {'label': 'a', 'value': 1},
        {'label': 'broken'},
      ],
    });

    expect(tester.takeException(), isNull);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('broken'), findsNothing);
  });

  testWidgets('a scatter point without x/y is dropped', (tester) async {
    await _pumpChart(tester, {
      'type': 'scatter',
      'datasets': [
        {
          'data': [
            {'x': 1, 'y': 2},
            {'x': 'n/a'},
          ],
        },
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('numeric labels render instead of throwing', (tester) async {
    await _pumpChart(tester, {
      'type': 'bar',
      'labels': [2024, 2025],
      'datasets': [
        {
          'data': [1, 2],
        },
      ],
    });

    expect(tester.takeException(), isNull);
    expect(find.text('2024'), findsOneWidget);
  });

  testWidgets('a line with a gap draws, without bridging the hole',
      (tester) async {
    await _pumpChart(tester, {
      'type': 'line',
      'labels': ['a', 'b', 'c'],
      'datasets': [
        {
          'data': [1, null, 3],
        },
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a non-string type does not throw', (tester) async {
    await _pumpChart(tester, {
      'type': 42,
      'labels': ['a'],
      'datasets': [
        {
          'data': [1],
        },
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a pie label that is not a string still renders', (tester) async {
    await _pumpChart(tester, {
      'type': 'pie',
      'data': [
        {'label': 2024, 'value': 1},
      ],
    });

    expect(tester.takeException(), isNull);
    expect(find.text('2024'), findsOneWidget);
  });

  testWidgets('a gap in the first series does not shift tooltip labels',
      (tester) async {
    await _pumpChart(tester, {
      'type': 'bar',
      'labels': ['a', 'b'],
      'datasets': [
        {
          'label': 'first',
          'data': [null, 2],
        },
        {
          'label': 'second',
          'data': [3, 4],
        },
      ],
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('non-string caption and source do not throw', (tester) async {
    await _pumpChart(tester, {
      'rows': [
        {'label': 'a', 'value': 1},
      ],
      'caption': 42,
      'source_url': ['https://example.test'],
      'retrieved_at': null,
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a string height falls back to the default', (tester) async {
    await _pumpChart(tester, {
      'rows': [
        {'label': 'a', 'value': 1},
      ],
      'height': 'tall',
      'max_y': 'lots',
    });

    expect(tester.takeException(), isNull);
  });
}
