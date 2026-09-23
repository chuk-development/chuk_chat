import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';

import 'package:chuk_chat/widgets/chat_document_view.dart';
import 'package:chuk_chat/widgets/charts/chuk_chart.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/widgets/chuk_table.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

/// A saved document has to read like a document on the phone it is read on.
///
/// Every case here is a real document out of the host database
/// (`~/.agents/executor-state.db`, table `chat_documents`) rendered at the
/// screen it failed on: a Pixel 7 Pro, 412 x 892 logical, at both the default
/// text scale and the 1.3 an ordinary accessibility setting produces.
///
/// What used to happen, measured inside a 348-pixel content column:
///  * the markdown document's GFM table painted 1133 pixels wide and the
///    fenced code block 898 — three columns and half the code sat off the
///    right edge with nothing to scroll and nothing to say they existed;
///  * the table document's `DataTable` painted 875 pixels wide (963 at a 1.3
///    text scale), so four of its five columns were off screen.

const String _briefText = '''
# Wahlradar

Ein eigener Beobachter für die **Landtagswahl Sachsen-Anhalt 2026** — läuft.

- **Quelle:** https://wahlergebnisse.sachsen-anhalt.de/wahlen/lt26/erg_land.html
- **Monitor:** `monitor_lt26.py` im Workspace-Root, Watcher-Automation-ID **a2f1d3d1**.

## Zwischenstand

| Partei | Zweitstimmen | Anteil (%) | Stand |
| --- | --- | --- | --- |
| CDU | 226622 | 17.2 | 07.09.2026 02:56 Uhr |
| AfD | 576037 | 43.8 | 07.09.2026 02:56 Uhr |

```python
def poll(url: str, *, timeout: float = 30.0) -> dict[str, object]:
    return fetch_the_official_results_page_and_parse_it(url, timeout=timeout)
```
''';

Map<String, dynamic> _markdownDocument() => <String, dynamic>{
  'id': 'election-watch-brief',
  'title': 'Wahlradar · Auftrag',
  'kind': 'markdown',
  'version': 5,
  'text': _briefText,
};

Map<String, dynamic> _tableDocument() => <String, dynamic>{
  'id': 'lt26-results',
  'title': 'Sachsen-Anhalt 2026 · Zweitstimmen',
  'kind': 'table',
  'version': 31,
  'columns': ['Partei', 'Zweitstimmen', 'Anteil (%)', 'Stand', 'Quelle'],
  'rows': [
    for (final party in [
      ['CDU', 226622, 17.2],
      ['AfD', 576037, 43.8],
      ['Die Linke', 112541, 8.6],
    ])
      {
        'Partei': party[0],
        'Zweitstimmen': party[1],
        'Anteil (%)': party[2],
        'Stand': '07.09.2026 02:56 Uhr',
        'Quelle':
            'https://wahlergebnisse.sachsen-anhalt.de/wahlen/lt26/erg_land.html',
      },
  ],
};

Map<String, dynamic> _chartDocument() => <String, dynamic>{
  'id': 'lt26-chart',
  'title': 'Sachsen-Anhalt 2026 · Vier stärkste Parteien',
  'kind': 'bar_chart',
  'version': 12,
  'caption':
      'Vorläufiges amtliches Gesamtergebnis · 2661 von 2661 Wahlbezirken. '
      'Vier stärkste Parteien; vollständige Zahlen in der Ergebnistabelle.',
  'source_url':
      'https://wahlergebnisse.sachsen-anhalt.de/wahlen/lt26/erg_land.html',
  'retrieved_at': '07.09.2026 02:56 Uhr',
  'rows': [
    {'label': 'AfD', 'value': 43.8, 'color': '#80cdec'},
    {'label': 'CDU', 'value': 17.2, 'color': '#576164'},
    {'label': 'SPD', 'value': 9.3, 'color': '#c0003d'},
    {'label': 'GRÜNE', 'value': 8.9, 'color': '#008549'},
  ],
};

/// Puts the tester on a Pixel 7 Pro at [scale], for the lifetime of one test.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412 * 3, 892 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Widget _host(Widget child, {double scale = 1.0}) => MaterialApp(
  builder: (context, inner) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: inner!,
  ),
  home: Scaffold(body: child),
);

/// Opens the document the way a reader does — through the dialog, so the test
/// measures the real content column and not a full-bleed test surface.
Future<void> _open(
  WidgetTester tester,
  Map<String, dynamic> document, {
  double scale = 1.0,
}) async {
  await tester.pumpWidget(
    _host(
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => ChatDocumentView.open(context, document),
            child: const Text('open'),
          ),
        ),
      ),
      scale: scale,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await _settleCodeBlocks(tester);
}

/// Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
/// 2 s highlight timeout inside `markdown_message.dart`, so a document with a
/// fenced block leaves no timer pending at the end of a test. Same helper the
/// chat's own markdown test uses.
Future<void> _settleCodeBlocks(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 3));
  await tester.pump();
}

/// Every box inside [root] that paints past its right edge.
///
/// A horizontally scrolling subtree is allowed to be wider than the column —
/// that is what scrolling is for — so the walk stops at one. Everything else
/// that reaches past the edge is content the reader cannot get to.
List<String> _pastRightEdge(WidgetTester tester, Finder root) {
  final Element rootElement = root.evaluate().single;
  final RenderBox rootBox = rootElement.renderObject! as RenderBox;
  final double edge =
      rootBox.localToGlobal(Offset.zero).dx + rootBox.size.width;
  final List<String> hits = <String>[];

  void walk(Element element) {
    final Widget widget = element.widget;
    if (widget is ScrollView && widget.scrollDirection == Axis.horizontal) {
      return;
    }
    if (widget is Scrollable && widget.axisDirection == AxisDirection.right) {
      return;
    }
    // A FittedBox scales what is inside it: an SVG icon reports the asset's own
    // 24 px box while being drawn at 18. Measuring those boxes says nothing
    // about what is painted, the same reason a horizontal scroller is skipped.
    if (widget is FittedBox) {
      return;
    }
    final RenderObject? object = element.renderObject;
    if (object is RenderBox && object.hasSize && object.attached) {
      final Offset origin = object.localToGlobal(Offset.zero);
      final double right = origin.dx + object.size.width;
      if (right > edge + 0.5) {
        final String text = widget is Text
            ? '("${widget.data}")'
            : widget is RichText
            ? '("${widget.text.toPlainText()}")'
            : '';
        hits.add(
          '${widget.runtimeType}$text w=${object.size.width.toStringAsFixed(0)} '
          'right=${right.toStringAsFixed(0)} edge=${edge.toStringAsFixed(0)}',
        );
      }
    }
    element.visitChildren(walk);
  }

  walk(rootElement);
  return hits;
}

void main() {
  // Chat documents are an Agents feature, and so is the table they draw.
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);

  for (final double scale in <double>[1.0, 1.3]) {
    testWidgets(
      'a markdown document fits the phone column at text scale $scale',
      (tester) async {
        _phone(tester);
        await _open(tester, _markdownDocument(), scale: scale);

        expect(tester.takeException(), isNull);
        expect(
          _pastRightEdge(tester, find.byType(ChatDocumentView)),
          isEmpty,
          reason: 'nothing may paint outside the reading column',
        );
      },
    );

    testWidgets('a table document fits the phone column at text scale $scale', (
      tester,
    ) async {
      _phone(tester);
      await _open(tester, _tableDocument(), scale: scale);

      expect(tester.takeException(), isNull);
      expect(_pastRightEdge(tester, find.byType(ChatDocumentView)), isEmpty);
    });

    testWidgets('a chart document fits the phone column at text scale $scale', (
      tester,
    ) async {
      _phone(tester);
      await _open(tester, _chartDocument(), scale: scale);

      expect(tester.takeException(), isNull);
      expect(_pastRightEdge(tester, find.byType(ChatDocumentView)), isEmpty);
      // The chart paints its own text, so the numbers are read back from the
      // label a screen reader gets rather than from a Text widget.
      final String spoken = tester
          .widget<Semantics>(
            find.descendant(
              of: find.byType(ChukChart),
              matching: find.byType(Semantics),
            ),
          )
          .properties
          .label!;
      for (final String value in ['43.8 %', '17.2 %', '9.3 %', '8.9 %']) {
        expect(spoken, contains(value));
      }
    });
  }

  testWidgets('a table inside a markdown document stacks on a phone', (
    tester,
  ) async {
    _phone(tester);
    await _open(tester, _markdownDocument());

    // The document renderer hands its tables to the chat's table widget, and
    // that widget draws a table: the column name once, in the header.
    expect(find.byType(ChukTable), findsOneWidget);
    expect(find.text('Anteil (%)'), findsOneWidget);
    expect(find.text('Stand'), findsOneWidget);
    // Both data rows are on screen, each on one line.
    expect(find.textContaining('07.09.2026'), findsNWidgets(2));
  });

  testWidgets('a fenced code block scrolls sideways instead of bleeding out', (
    tester,
  ) async {
    _phone(tester);
    await _open(tester, _markdownDocument());

    final Finder code = find.textContaining('def poll');
    expect(code, findsWidgets);
    final Finder scroller = find.ancestor(
      of: code.first,
      matching: find.byWidgetPredicate(
        (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
    );
    expect(scroller, findsWidgets);
    // The scroller itself stays inside the column; only its content is wider.
    final double columnRight = tester
        .getTopRight(find.byType(ChatDocumentView))
        .dx;
    expect(
      tester.getTopRight(scroller.first).dx,
      lessThanOrEqualTo(columnRight + 0.5),
    );
  });

  testWidgets('a table document uses the same table widget as the chat', (
    tester,
  ) async {
    _phone(tester);
    await _open(tester, _tableDocument());

    final ChukTable table = tester.widget<ChukTable>(find.byType(ChukTable));
    expect(table.table.header, [
      'Partei',
      'Zweitstimmen',
      'Anteil (%)',
      'Stand',
      'Quelle',
    ]);
    // Numbers line up on the right so their digits compare; text does not.
    expect(table.table.alignments, [
      TextAlign.left,
      TextAlign.right,
      TextAlign.right,
      TextAlign.left,
      TextAlign.left,
    ]);
    // A bare URL is a link labelled by its host, not 78 characters of column.
    expect(
      table.table.rows.first.last,
      '[wahlergebnisse.sachsen-anhalt.de]'
      '(https://wahlergebnisse.sachsen-anhalt.de/wahlen/lt26/erg_land.html)',
    );
    // On a phone the whole Quelle column is the same hostname three times
    // over — no information, a quarter of the width — so it is drawn as the
    // action it is: one arrow per row, under a header that names the column.
    expect(find.textContaining('wahlergebnisse.sachsen-anhalt.de'), findsNothing);
    expect(find.text('Quelle'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is HugeIcon && w.icon.name == 'arrow-up-right01',
      ),
      findsNWidgets(3),
    );
    // The 78-character URL itself never reaches the column; it lives on the
    // tap target behind the arrow.
    expect(find.textContaining('erg_land.html'), findsNothing);
  });

  testWidgets('prose reads at document size inside a reading measure', (
    tester,
  ) async {
    // A wide desktop dialog: without a measure the lines would run the full
    // 968 pixels, which is past what an eye tracks back from.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _open(tester, _markdownDocument());

    final MarkdownMessage prose = tester
        .widgetList<MarkdownMessage>(find.byType(MarkdownMessage))
        .first;
    expect(prose.paragraphFontSize, 15.5);
    expect(prose.paragraphHeight, 1.7);
    expect(
      tester.getSize(find.byType(MarkdownMessage).first).width,
      lessThanOrEqualTo(720.0),
    );
  });

  testWidgets('a chart document draws its own percentages', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _open(tester, _chartDocument());

    final ChartSpec spec = tester.widget<ChukChart>(find.byType(ChukChart)).spec;
    // The percentages are the document's own; nothing was rescaled to 100.
    expect(spec.series.single.points.map((p) => p.value).toList(), [
      43.8,
      17.2,
      9.3,
      8.9,
    ]);
    expect(spec.unit, '%');
    expect(spec.series.single.points.first.color, const Color(0xff80cdec));
  });

  testWidgets('a chart with no source draws no rule under nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Map<String, dynamic> bare = _chartDocument()
      ..remove('source_url')
      ..remove('retrieved_at');
    await _open(tester, bare);

    expect(find.byTooltip('Copy link'), findsNothing);
    // Only the dialog's own header rule remains.
    expect(find.byType(Divider), findsOneWidget);
  });

  group('documentFileStem', () {
    test('a title that looks like a path cannot become one', () {
      expect(documentFileStem('reports/q3'), 'reports-q3');
      expect(documentFileStem(r'a\b:c*d?e"f<g>h|i'), 'a-b-c-d-e-f-g-h-i');
    });

    test('a reader-facing title keeps the characters a file may hold', () {
      expect(
        documentFileStem('Sachsen-Anhalt 2026 · Zweitstimmen'),
        'Sachsen-Anhalt 2026 · Zweitstimmen',
      );
    });

    test('an empty or missing title still names a file', () {
      expect(documentFileStem(null), 'document');
      expect(documentFileStem('   '), 'document');
      expect(documentFileStem('///'), 'document');
    });

    test('a very long title is cut, not carried whole into a file name', () {
      expect(documentFileStem('x' * 300).length, 80);
    });
  });
}
