import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cowork/models/content_block.dart';
import 'package:cowork/widgets/chat_document_view.dart';
import 'package:cowork/widgets/charts/chuk_chart.dart';
import 'package:cowork/widgets/chuk_table.dart';

void main() {
  final document = <String, dynamic>{
    'id': 'songs',
    'title': 'Songs',
    'kind': 'table',
    'version': 2,
    'columns': ['Reel', 'Song', 'Artist', 'Spotify'],
    'rows': [
      {
        'Reel': 'https://instagram.com/reels/test',
        'Song': 'Song title',
        'Artist': 'Artist name',
        'Spotify': 'https://open.spotify.com/search/song',
      },
    ],
  };

  testWidgets(
    'a table document draws through the chat table, with URLs as host links',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatDocumentView(document: document)),
        ),
      );
      expect(find.text('Song title'), findsOneWidget);
      expect(find.text('Artist name'), findsOneWidget);
      // One table widget, the same one the chat renders — not a second,
      // half-built grid that cannot stack on a phone.
      expect(find.byType(ChukTable), findsOneWidget);
      // A URL cell reads as its host and opens on a tap. The whole table is
      // copyable as markdown, with the full URLs in it, from ChukTable's own
      // control — which is why the per-cell copy buttons are gone.
      expect(find.textContaining('instagram.com', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('open.spotify.com', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('/reels/test', findRichText: true),
          findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'chat payload roundtrip contains full document independently of a local blob',
    () {
      final block = ContentBlock.sandboxArtifact(
        SandboxArtifactPayload(
          storagePath: 'cowork://blob/local',
          filename: 'songs.json',
          mime: 'application/vnd.cowork.document+json',
          sizeBytes: 200,
          document: document,
        ),
      );
      final recovered = ContentBlock.fromJson(
        jsonDecode(jsonEncode(block.toJson())),
      );
      expect(recovered.sandboxArtifact!.document, document);
    },
  );
  testWidgets(
    'a legacy chart document draws through ChukChart and keeps its source',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(760, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final chart = <String, dynamic>{
        'id': 'election',
        'title': 'Test election',
        'kind': 'bar_chart',
        'caption': 'Four strongest parties — test data',
        'source_url': 'https://example.org/results',
        'retrieved_at': '2026-09-06T18:00:00Z',
        'rows': [
          {'label': 'Party A', 'value': 32.1, 'color': '#112233'},
          {'label': 'Party B', 'value': 24.5, 'color': '#ee2200'},
          {'label': 'Party C', 'value': 18.0, 'color': '#33aa55'},
          {'label': 'Party D', 'value': 8.3, 'color': '#aa22cc'},
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatDocumentView(document: chart)),
        ),
      );

      // The rows a document was written with in 2026 map onto the chart
      // contract: nothing in the store had to change to be drawn.
      final ChartSpec spec = tester.widget<ChukChart>(
        find.byType(ChukChart),
      ).spec;
      expect(spec.kind, ChartKind.bar);
      expect(spec.unit, '%');
      expect(spec.categories, ['Party A', 'Party B', 'Party C', 'Party D']);
      expect(
        spec.series.single.points.map((p) => p.value).toList(),
        [32.1, 24.5, 18.0, 8.3],
      );
      // The party colours survive the mapping — they are the only thing that
      // tells two bars apart.
      expect(
        spec.series.single.points.map((p) => p.color).toList(),
        const [
          Color(0xff112233),
          Color(0xffee2200),
          Color(0xff33aa55),
          Color(0xffaa22cc),
        ],
      );
      // The caption becomes the chart's subtitle, so it is printed once.
      expect(spec.subtitle, 'Four strongest parties — test data');
      // The source keeps the block a reader can actually tap.
      expect(spec.source, isNull);
      expect(find.byTooltip('Copy link'), findsOneWidget);
      expect(find.byTooltip('Open in browser'), findsOneWidget);
      // The chart keeps the reading measure rather than the whole surface.
      expect(
        tester.getSize(find.byType(ChukChart)).width,
        lessThanOrEqualTo(720.0),
      );
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(const Size(320, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(body: ChatDocumentView(document: chart)),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  group('documentFreshness', () {
    test('a document written today is a bare clock, with no seconds', () {
      final today = DateTime.now().copyWith(hour: 0, minute: 6, second: 41);
      expect(
        documentFreshness({
          'version': 17,
          'updated_at': today.millisecondsSinceEpoch / 1000,
        }, now: today),
        'v17 · 00:06',
      );
    });

    test('an older document carries its date, so the clock cannot mislead', () {
      final then = DateTime(2026, 1, 5, 14, 3);
      expect(
        documentFreshness({
          'version': 2,
          'updated_at': then.millisecondsSinceEpoch / 1000,
        }, now: DateTime(2026, 3, 9, 8, 0)),
        'v2 · 05.01. 14:03',
      );
    });

    test('a workspace file has no version, only a time', () {
      final then = DateTime(2026, 1, 5, 9, 30);
      expect(
        documentFreshness({
          'updated_at': then.millisecondsSinceEpoch / 1000,
        }, now: DateTime(2026, 1, 5, 10, 0)),
        '09:30',
      );
    });

    test('nothing is invented when the document carries no stamp', () {
      expect(documentFreshness({'title': 'x'}), isNull);
      expect(documentFreshness({'version': 0, 'updated_at': 0}), isNull);
      expect(documentFreshness({'updated_at': 'yesterday'}), isNull);
      expect(documentFreshness({'updated_at': double.nan}), isNull);
    });
  });

  testWidgets('the reader header states the version and the time', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final then = DateTime(2026, 1, 5, 14, 3);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatDocumentView(
            document: {
              ...document,
              'updated_at': then.millisecondsSinceEpoch / 1000,
            },
          ),
        ),
      ),
    );
    expect(find.text('1 rows · v2 · 05.01. 14:03'), findsOneWidget);
  });
}
