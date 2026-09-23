// A document the coworker posted carries its content in the thread.
//
// The block used to be a row — a title, "Version 31 · Saved document" and a
// chevron — so the numbers the user asked for were never in the chat. These
// tests hold the line that they are: the table draws its cells, the markdown
// draws its prose, the chart draws as the app's chart, and a real file keeps
// its own attachment row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/widgets/chat_document_inline.dart';
import 'package:chuk_chat/widgets/charts/chuk_chart.dart';
import 'package:chuk_chat/widgets/chuk_table.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/sandbox_artifact_block.dart';

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
  ),
);

SandboxArtifactBlock blockFor(Map<String, dynamic> document) =>
    SandboxArtifactBlock(
      payload: SandboxArtifactPayload(
        storagePath: 'cowork://document/${document['id']}',
        filename: '${document['id']}.json',
        mime: 'application/vnd.cowork.document+json',
        sizeBytes: 512,
        document: document,
      ),
    );

Map<String, dynamic> tableDocument({int rows = 3}) => <String, dynamic>{
  'id': 'zweitstimmen',
  'title': 'Sachsen-Anhalt 2026 · Zweitstimmen',
  'kind': 'table',
  'version': 31,
  'columns': <String>['Partei', 'Prozent'],
  'rows': <Map<String, dynamic>>[
    for (int i = 0; i < rows; i++)
      <String, dynamic>{'Partei': 'Partei ${i + 1}', 'Prozent': '${40 - i}.5'},
  ],
};

/// A chart document as the tool wrote it before the renderer landed: rows of
/// {label, value, color}, the value a percentage.
Map<String, dynamic> legacyChartDocument() => <String, dynamic>{
  'id': 'staerkste',
  'title': 'Sachsen-Anhalt 2026 · Vier stärkste Parteien',
  'kind': 'bar_chart',
  'version': 31,
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{'label': 'AfD', 'value': 40.5, 'color': '#80cdec'},
    <String, dynamic>{'label': 'CDU', 'value': 22.3, 'color': '#000000'},
  ],
};

/// A chart document as the tool writes one now: the spec itself, under `chart`.
Map<String, dynamic> specChartDocument() => <String, dynamic>{
  'id': 'lt26',
  'title': 'Landtagswahl Sachsen-Anhalt',
  'kind': 'bar_chart',
  'version': 4,
  'caption': 'Vorläufiges Endergebnis, Zweitstimmen',
  'source_url': 'https://wahlergebnisse.sachsen-anhalt.de/wahlen/lt26/',
  'retrieved_at': '2026-09-12T20:15:00Z',
  'chart': <String, Object?>{
    'kind': 'bar',
    'unit': '%',
    'decimals': 1,
    'decimal_separator': ',',
    'sort': 'desc',
    'reference_line': <String, Object?>{'value': 5, 'label': '5 %-Hürde'},
    'source': 'Landeswahlleiter Sachsen-Anhalt',
    'points': <Map<String, Object?>>[
      <String, Object?>{'label': 'CDU', 'value': 17.2, 'color': '#32302E'},
      <String, Object?>{'label': 'AfD', 'value': 43.8, 'color': '#009EE0'},
      <String, Object?>{'label': 'SPD', 'value': 9.3, 'color': '#E3000F'},
      <String, Object?>{'label': 'Grüne', 'value': 8.9, 'color': '#46962B'},
      <String, Object?>{'label': 'Linke', 'value': 8.6, 'color': '#BE3075'},
      <String, Object?>{'label': 'BSW', 'value': 5.3, 'color': '#792350'},
      <String, Object?>{'label': 'FDP', 'value': 2.6, 'color': '#FFED00'},
      <String, Object?>{'label': 'FW', 'value': 1.2, 'color': '#FF8000'},
      <String, Object?>{'label': 'Tierschutz', 'value': 1.1, 'color': '#00543D'},
      <String, Object?>{'label': 'Sonst.', 'value': 2.1, 'color': '#8C8C8C'},
    ],
  },
};

void main() {
  testWidgets('a table document draws its cells in the thread', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrap(blockFor(tableDocument())));
    await tester.pump();

    expect(find.byType(InlineChatDocument), findsOneWidget);
    expect(find.byType(ChukTable), findsOneWidget);
    // The result itself, in the thread — not a link to it.
    expect(find.textContaining('Partei 1', findRichText: true), findsWidgets);
    expect(find.textContaining('40.5', findRichText: true), findsWidgets);
    // The title is there, the version has stopped shouting.
    expect(find.text('Sachsen-Anhalt 2026 · Zweitstimmen'), findsOneWidget);
    expect(find.textContaining('Saved document'), findsNothing);
    expect(find.textContaining('v31'), findsOneWidget);
    // A short document is whole: no affordance at all.
    expect(find.textContaining('Open all'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long table shows its first rows and offers the rest', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrap(blockFor(tableDocument(rows: 20))));
    await tester.pump();

    // Two short columns still fit a phone column as a grid, so the thread
    // shows the grid cut.
    final ChukTable table = tester.widget<ChukTable>(find.byType(ChukTable));
    expect(table.table.rows.length, kInlineDocumentRows);
    expect(find.text('Open all 20 rows'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a table that has to stack shows fewer rows', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        blockFor(<String, dynamic>{
          'id': 'breit',
          'title': 'Breite Tabelle',
          'kind': 'table',
          'version': 3,
          'columns': <String>['Partei', 'Zweitstimmen', 'Anteil', 'Stand'],
          'rows': <Map<String, dynamic>>[
            for (int i = 0; i < 12; i++)
              <String, dynamic>{
                'Partei': 'Eine Partei mit langem Namen ${i + 1}',
                'Zweitstimmen': '${117498 - i * 1000}',
                'Anteil': '${40 - i}.5 %',
                'Stand': '07.09.2026 02:56 Uhr',
              },
          ],
        }),
      ),
    );
    await tester.pump();

    // One card per row is a paragraph each, so the cut is tighter.
    final ChukTable table = tester.widget<ChukTable>(find.byType(ChukTable));
    expect(table.table.rows.length, kInlineDocumentStackedRows);
    expect(find.text('Open all 12 rows'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a markdown document draws through the app renderer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        blockFor(<String, dynamic>{
          'id': 'plan',
          'title': 'Wahlradar · Plan',
          'kind': null,
          'version': 4,
          'text': '## Stand\n\nDie AfD steht bei 40,5 Prozent.',
        }),
      ),
    );
    await tester.pump();

    expect(find.byType(InlineChatDocument), findsOneWidget);
    expect(find.byType(MarkdownMessage), findsWidgets);
    expect(
      find.textContaining('40,5 Prozent', findRichText: true),
      findsWidgets,
    );
    expect(find.text('Wahlradar · Plan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long markdown document stops at the cut and offers to open', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        blockFor(<String, dynamic>{
          'id': 'lang',
          'title': 'Langer Bericht',
          'version': 9,
          'text': List<String>.generate(
            40,
            (int i) => 'Absatz $i mit genug Text, um die Höhe zu sprengen.',
          ).join('\n\n'),
        }),
      ),
    );
    // The cut is measured during layout and reported after the frame.
    await tester.pump();
    await tester.pump();

    expect(find.text('Open document'), findsOneWidget);
    final Size size = tester.getSize(find.byType(MarkdownMessage).first);
    expect(size.height, greaterThan(kInlineDocumentProseHeight));
    // The block itself stays short: the thread is not flooded.
    expect(
      tester.getSize(find.byType(InlineChatDocument)).height,
      lessThan(kInlineDocumentProseHeight + 200),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a legacy bar chart document draws as a chart', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrap(blockFor(legacyChartDocument())));
    await tester.pump();

    // The stored rows are read as a chart spec — the same widget a spec
    // document draws with, so the two cannot drift apart.
    final ChartSpec spec = tester.widget<ChukChart>(find.byType(ChukChart)).spec;
    expect(spec.kind, ChartKind.bar);
    expect(spec.unit, '%');
    expect(spec.categories, <String>['AfD', 'CDU']);
    expect(spec.series.single.points.first.value, 40.5);
    expect(spec.series.single.points.first.color, const Color(0xff80cdec));
    // The block already carries the title; the card does not repeat it.
    expect(spec.title, isNull);
    expect(find.textContaining('2 bars'), findsOneWidget);
    expect(find.textContaining('Open all'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chart document draws the spec the agent described', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrap(blockFor(specChartDocument())));
    await tester.pump();

    final ChartSpec spec = tester.widget<ChukChart>(find.byType(ChukChart)).spec;
    expect(spec.kind, ChartKind.bar);
    expect(spec.unit, '%');
    expect(spec.decimalSeparator, ',');
    expect(spec.referenceLine?.value, 5);
    expect(spec.referenceLine?.label, '5 %-Hürde');
    // The source line travels with the card in the thread.
    expect(spec.source, 'Landeswahlleiter Sachsen-Anhalt');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long chart stops at six bars and offers the rest', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrap(blockFor(specChartDocument())));
    await tester.pump();

    final ChartSpec spec = tester.widget<ChukChart>(find.byType(ChukChart)).spec;
    expect(spec.categories.length, kInlineDocumentRows);
    // Sorted first, then cut: the six biggest, not the six written first.
    expect(spec.categories.first, 'AfD');
    expect(spec.categories.last, 'BSW');
    expect(find.text('Open all 10 bars'), findsOneWidget);
    // The meta line still names the whole document.
    expect(find.textContaining('10 bars · v4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a line chart keeps every point in the thread', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        blockFor(<String, dynamic>{
          'id': 'btc',
          'title': 'BTC, 10 Tage',
          'kind': 'bar_chart',
          'version': 2,
          'chart': <String, Object?>{
            'kind': 'line',
            'unit': r'$',
            'series': <Map<String, Object?>>[
              <String, Object?>{
                'name': 'BTC',
                'direction': 'up',
                'points': <Map<String, Object?>>[
                  for (int i = 0; i < 10; i++)
                    <String, Object?>{'label': 'T$i', 'value': 60000 + i * 200},
                ],
              },
            ],
          },
        }),
      ),
    );
    await tester.pump();

    // A line is one stroke, not ten rows: cutting it to six days would be a
    // different week, so the cap does not apply to it.
    final ChartSpec spec = tester.widget<ChukChart>(find.byType(ChukChart)).spec;
    expect(spec.kind, ChartKind.line);
    expect(spec.categories.length, 10);
    expect(find.textContaining('Open all'), findsNothing);
    expect(find.textContaining('10 points'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a real file keeps its own attachment row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        const SandboxArtifactBlock(
          payload: SandboxArtifactPayload(
            storagePath: 'user/file.enc',
            filename: 'Ergebnis.txt',
            mime: 'text/plain',
            sizeBytes: 2048,
          ),
        ),
      ),
    );
    await tester.pump();

    // A file is its own message, not a document body.
    expect(find.byType(InlineChatDocument), findsNothing);
    expect(find.byType(ChukTable), findsNothing);
    expect(find.textContaining('Ergebnis', findRichText: true), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reference-only document keeps the compact row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        blockFor(<String, dynamic>{
          'id': 'stub',
          'title': 'Nur eine Referenz',
          'kind': 'table',
          'version': 2,
        }),
      ),
    );
    await tester.pump();

    expect(find.byType(InlineChatDocument), findsNothing);
    expect(find.textContaining('Saved document'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the block survives 360 dp at a 1.3 text scale', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 360,
                child: blockFor(tableDocument(rows: 9)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  test('content detection knows a body from a reference', () {
    expect(inlineDocumentHasContent(tableDocument()), isTrue);
    expect(
      inlineDocumentHasContent(<String, dynamic>{
        'kind': 'table',
        'columns': <String>['A'],
        'rows': <Map<String, dynamic>>[],
      }),
      isFalse,
    );
    expect(
      inlineDocumentHasContent(<String, dynamic>{'kind': 'file', 'size': 4}),
      isFalse,
    );
    expect(
      inlineDocumentHasContent(<String, dynamic>{'text': 'Hallo'}),
      isTrue,
    );
    expect(inlineDocumentHasContent(<String, dynamic>{'text': '  '}), isFalse);
  });
}
