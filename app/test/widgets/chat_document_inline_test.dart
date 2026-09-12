// A document the coworker posted carries its content in the thread.
//
// The block used to be a row — a title, "Version 31 · Saved document" and a
// chevron — so the numbers the user asked for were never in the chat. These
// tests hold the line that they are: the table draws its cells, the markdown
// draws its prose, the chart draws its bars, and a real file keeps its own
// attachment row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/content_block.dart';
import 'package:cowork/widgets/chat_document_inline.dart';
import 'package:cowork/widgets/chuk_table.dart';
import 'package:cowork/widgets/markdown_message.dart';
import 'package:cowork/widgets/sandbox_artifact_block.dart';

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

  testWidgets('a bar chart document draws its bars', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        blockFor(<String, dynamic>{
          'id': 'staerkste',
          'title': 'Sachsen-Anhalt 2026 · Vier stärkste Parteien',
          'kind': 'bar_chart',
          'version': 31,
          'rows': <Map<String, dynamic>>[
            <String, dynamic>{
              'label': 'AfD',
              'value': 40.5,
              'color': '#80cdec',
            },
            <String, dynamic>{
              'label': 'CDU',
              'value': 22.3,
              'color': '#000000',
            },
          ],
        }),
      ),
    );
    await tester.pump();

    expect(find.byType(DocumentBarList), findsOneWidget);
    expect(find.text('AfD'), findsOneWidget);
    expect(find.text('40.5 %'), findsOneWidget);
    expect(find.text('22.3 %'), findsOneWidget);
    expect(find.textContaining('Open all'), findsNothing);
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
