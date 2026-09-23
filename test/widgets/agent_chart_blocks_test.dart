import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/agent_markdown.dart';
import 'package:chuk_chat/widgets/chart_widget.dart';

const _electionChart = '''
Stand 22:25 Uhr.

<chart>
{"title":"Zweitstimmen","rows":[{"label":"AfD","value":44.8,"color":"#80cdec"},
{"label":"CDU","value":16.8,"color":"#576164"},
{"label":"SPD","value":9.1,"color":"#c0003d"},
{"label":"GRÜNE","value":8.9,"color":"#008549"}],
"caption":"2505 von 2660 Wahlbezirken","source_url":"https://example.test/erg"}
</chart>

Vollständige Zahlen in der Tabelle.
''';

void main() {
  group('splitAgentSegments', () {
    test('splits prose around a chart block', () {
      final segments = splitAgentSegments(_electionChart);

      expect(segments.length, 3);
      expect(segments[0], isA<AgentTextSegment>());
      expect((segments[0] as AgentTextSegment).text, contains('Stand 22:25'));
      expect(segments[1], isA<AgentChartSegment>());
      expect((segments[2] as AgentTextSegment).text, contains('Tabelle'));
    });

    test('keeps the row colors so every bar keeps its own hex', () {
      final chart = splitAgentSegments(_electionChart)
          .whereType<AgentChartSegment>()
          .single
          .data;
      final normalized = normalizeChartData(chart);

      expect(normalized['type'], 'bar');
      expect(normalized['labels'], ['AfD', 'CDU', 'SPD', 'GRÜNE']);
      final dataset = (normalized['datasets'] as List).single as Map;
      expect(dataset['data'], [44.8, 16.8, 9.1, 8.9]);
      expect(dataset['colors'], ['#80cdec', '#576164', '#c0003d', '#008549']);
    });

    test('holds back a block that is still streaming', () {
      final segments = splitAgentSegments('Hier:\n\n<chart>\n{"type":"bar",');

      expect(segments.length, 1);
      expect((segments.single as AgentTextSegment).text.trim(), 'Hier:');
    });

    test('holds back the last block even after an unreadable closed one', () {
      final segments = splitAgentSegments(
        'A\n<chart>not json</chart>\nB\n<chart>{"type":"bar",',
      );

      expect(segments.whereType<AgentChartSegment>(), isEmpty);
      final text = (segments.single as AgentTextSegment).text;
      expect(text, contains('not json'));
      expect(text, isNot(contains('"type":"bar"')));
    });

    test('leaves an undecodable block in the prose instead of dropping it', () {
      const raw = 'A\n<chart>not json</chart>\nB';
      final segments = splitAgentSegments(raw);

      expect(segments.whereType<AgentChartSegment>(), isEmpty);
      expect((segments.single as AgentTextSegment).text, contains('not json'));
    });

    test('keeps prose whitespace so indented code survives', () {
      final segments = splitAgentSegments('    print(1)\n\n<chart>x</chart>');

      expect((segments.single as AgentTextSegment).text, startsWith('    '));
    });

    test('a chart block without numbers stays prose, no empty frame', () {
      final segments = splitAgentSegments(
        '<chart>{"type":"bar","labels":["a"],"datasets":[{"label":"x"}]}</chart>',
      );

      expect(segments.whereType<AgentChartSegment>(), isEmpty);
      expect((segments.single as AgentTextSegment).text, contains('datasets'));
    });

    test('accepts a fenced JSON body and a trailing comma', () {
      final chart = splitAgentSegments(
        '<chart>```json\n{"type":"bar","labels":["a"],'
        '"datasets":[{"data":[1]}],}\n```</chart>',
      ).whereType<AgentChartSegment>().single;

      expect(chart.data['type'], 'bar');
    });
  });

  testWidgets('AgentMarkdown draws the chart, not the raw tag', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: AgentMarkdown(_electionChart),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ChartRenderer), findsOneWidget);
    expect(find.textContaining('<chart>'), findsNothing);
    expect(find.text('2505 von 2660 Wahlbezirken'), findsOneWidget);
  });
}
