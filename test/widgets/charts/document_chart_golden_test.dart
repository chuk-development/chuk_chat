// What a chart DOCUMENT looks like, in the thread and in the reader.
//
// The chart card has its own goldens (`chuk_chart_golden_test.dart`). These
// are the two places a document puts it: the block inside the thread, capped
// at six bars with the "Open" pill under it, and the full-screen reader with
// the whole chart and a source a reader can tap.
//
// Regenerate with
//
//   flutter test test/widgets/charts/document_chart_golden_test.dart \
//     --update-goldens
//
// and then LOOK at the PNGs. A golden that passes and reads badly is still a
// broken screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/chat_document_inline.dart';
import 'package:chuk_chat/widgets/chat_document_view.dart';

import 'chart_test_support.dart';

/// A chart document as the `chat_document` tool writes one now: the spec
/// itself under `chart`, with the document's own title, caption and source
/// around it.
Map<String, dynamic> specDocument() => <String, dynamic>{
  'id': 'lt26',
  'title': 'Landtagswahl Sachsen-Anhalt',
  'kind': 'bar_chart',
  'version': 4,
  'caption': 'Vorläufiges Endergebnis, Zweitstimmen',
  'source_url': 'https://wahlergebnisse.sachsen-anhalt.de/wahlen/lt26/',
  'retrieved_at': '2026-09-12T20:15:00Z',
  'updated_at': 1789251300.0,
  'chart': <String, Object?>{
    'kind': 'bar',
    'unit': '%',
    'decimals': 1,
    'decimal_separator': ',',
    'reference_line': <String, Object?>{'value': 5, 'label': '5 %-Hürde'},
    'source': 'Landeswahlleiter Sachsen-Anhalt',
    'points': <Map<String, Object?>>[
      <String, Object?>{'label': 'AfD', 'value': 43.8, 'color': '#009EE0'},
      <String, Object?>{'label': 'CDU', 'value': 17.2, 'color': '#32302E'},
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

/// A chart document as the tool wrote one before the renderer landed: rows of
/// label, percentage and colour. Nothing in a store had to be migrated.
Map<String, dynamic> legacyDocument() => <String, dynamic>{
  'id': 'staerkste',
  'title': 'Sachsen-Anhalt 2026 · Vier stärkste Parteien',
  'kind': 'bar_chart',
  'version': 31,
  'caption': 'Vorläufiges amtliches Ergebnis, vier stärkste Parteien',
  'source_url': 'https://wahlergebnisse.sachsen-anhalt.de/wahlen/lt26/',
  'retrieved_at': '07.09.2026 02:56 Uhr',
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{'label': 'AfD', 'value': 43.8, 'color': '#80cdec'},
    <String, dynamic>{'label': 'CDU', 'value': 17.2, 'color': '#576164'},
    <String, dynamic>{'label': 'SPD', 'value': 9.3, 'color': '#c0003d'},
    <String, dynamic>{'label': 'GRÜNE', 'value': 8.9, 'color': '#008549'},
  ],
};

/// Shoots [child] on a 360 dp phone column.
Future<void> _shoot(
  WidgetTester tester,
  Widget child,
  String name, {
  Brightness brightness = Brightness.dark,
  double height = 900,
}) async {
  const double width = 360;
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final ThemeData theme = chartTheme(brightness);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(width, height)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Material(
          color: theme.colorScheme.surface,
          child: RepaintBoundary(
            key: const ValueKey<String>('document-shot'),
            // The surface travels INSIDE the boundary: a Material painted
            // around it is not in the shot, and a dark theme would come out
            // as dark text on a transparent, white-looking page.
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: SizedBox(width: width, height: height, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await expectLater(
    find.byKey(const ValueKey<String>('document-shot')),
    matchesGoldenFile('$kChartGoldenDir/$name.png'),
  );
}

/// The thread block: the bubble, the title, the meta line and the chart.
Widget _inline(Map<String, dynamic> document) => Padding(
  padding: const EdgeInsets.all(12),
  child: SingleChildScrollView(
    child: InlineChatDocument(document: document, onOpen: _nothing),
  ),
);

void _nothing() {}

/// The reader, as the phone screen shows it minus its floating bar.
Widget _reader(Map<String, dynamic> document) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  child: ChatDocumentView(document: document),
);

void main() {
  setUpAll(loadChartFonts);

  testWidgets('a chart document in the thread, dark', (tester) async {
    await _shoot(tester, _inline(specDocument()), 'document_chart_inline_dark');
  });

  testWidgets('a chart document in the thread, light', (tester) async {
    await _shoot(
      tester,
      _inline(specDocument()),
      'document_chart_inline_light',
      brightness: Brightness.light,
    );
  });

  testWidgets('a chart document in the reader, dark', (tester) async {
    await _shoot(
      tester,
      _reader(specDocument()),
      'document_chart_reader_dark',
      height: 1000,
    );
  });

  testWidgets('a chart document in the reader, light', (tester) async {
    await _shoot(
      tester,
      _reader(specDocument()),
      'document_chart_reader_light',
      brightness: Brightness.light,
      height: 1000,
    );
  });

  testWidgets('a stored bar_chart document still reads, light', (tester) async {
    await _shoot(
      tester,
      _inline(legacyDocument()),
      'document_chart_legacy_inline_light',
      brightness: Brightness.light,
    );
  });

  testWidgets('a stored bar_chart document in the reader, dark', (
    tester,
  ) async {
    await _shoot(
      tester,
      _reader(legacyDocument()),
      'document_chart_legacy_reader_dark',
      height: 1000,
    );
  });
}
