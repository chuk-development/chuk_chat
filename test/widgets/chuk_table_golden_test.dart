// What a TABLE looks like — the thing the user actually sees.
//
// A green test proves nothing about a table; a table is judged by whether the
// eye can run down a column. So these write PNGs and the PNGs get looked at.
//
// Regenerate with
//
//   flutter test test/widgets/chuk_table_golden_test.dart --update-goldens
//
// and then OPEN the files under `test/widgets/goldens/chuk_table/`.
//
// The content is real: the Songs document the coworker wrote, with the
// Instagram reel it came from, the Spotify search it opens, a Cyrillic title
// and an artist name long enough to need cutting.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/chat_document_inline.dart';
import 'package:chuk_chat/widgets/chat_document_view.dart';
import 'package:chuk_chat/widgets/chuk_table.dart';

import 'charts/chart_test_support.dart';

/// Where the shots land: committed next to this file (relative to
/// `test/widgets/`), like the chart goldens, so a plain run compares against
/// the reviewed images instead of failing on a missing file.
const String _shots = 'goldens/chuk_table';

/// The songs table, as the `chat_document` tool stores one: the reel it came
/// from, the song, the artist, and the Spotify search that opens it.
Map<String, dynamic> songs({int rows = 2}) {
  const List<List<String>> all = <List<String>>[
    <String>[
      'https://www.instagram.com/reel/DKx7vQ2sT1a/',
      "I'm God",
      'Clams Casino',
      'https://open.spotify.com/search/I%27m%20God%20Clams%20Casino',
    ],
    <String>[
      'https://www.youtube.com/shorts/9bZkp7q19f0',
      'Детка, я потерял контроль',
      'Три Дня Дождя',
      'https://open.spotify.com/search/%D0%94%D0%B5%D1%82%D0%BA%D0%B0%20%D1%8F%20%D0%BF%D0%BE%D1%82%D0%B5%D1%80%D1%8F%D0%BB%20%D0%BA%D0%BE%D0%BD%D1%82%D1%80%D0%BE%D0%BB%D1%8C',
    ],
    <String>[
      'https://www.instagram.com/reel/DLp2mNQoQ8z/',
      'Sleep Token — Take Me Back to Eden',
      'Sleep Token',
      'https://open.spotify.com/search/Take%20Me%20Back%20To%20Eden',
    ],
    <String>[
      'https://www.instagram.com/reel/DMa4rVvsJ0k/',
      'Nunca Es Suficiente',
      'Los Ángeles Azules, Natalia Lafourcade',
      'https://open.spotify.com/search/Nunca%20Es%20Suficiente',
    ],
    <String>[
      'https://www.instagram.com/reel/DNb8wXysP2q/',
      'Пыяла',
      'АИГЕЛ',
      'https://open.spotify.com/search/%D0%9F%D1%8B%D1%8F%D0%BB%D0%B0',
    ],
    <String>[
      'https://www.instagram.com/reel/DOc1yZzsR4w/',
      'Murder in My Mind',
      'Kordhell',
      'https://open.spotify.com/search/Murder%20In%20My%20Mind',
    ],
    <String>[
      'https://www.instagram.com/reel/DPd5aBcsT6e/',
      'Sweater Weather',
      'The Neighbourhood',
      'https://open.spotify.com/search/Sweater%20Weather',
    ],
    <String>[
      'https://www.instagram.com/reel/DQe9cDesV8r/',
      'Une Barque sur l’Océan',
      'Maurice Ravel',
      'https://open.spotify.com/search/Une%20Barque%20sur%20l%27Ocean',
    ],
  ];
  return <String, dynamic>{
    'id': 'songs',
    'title': 'Songs',
    'kind': 'table',
    'version': 7,
    'updated_at': 1789251300.0,
    'columns': <String>['Reel', 'Song', 'Artist', 'Spotify'],
    'rows': <Map<String, dynamic>>[
      for (final List<String> r in all.take(rows))
        <String, dynamic>{
          'Reel': r[0],
          'Song': r[1],
          'Artist': r[2],
          'Spotify': r[3],
        },
    ],
  };
}

/// A table the coworker labelled itself: the cell carries `[label](url)`, so
/// the label survives and the column is NOT collapsed to an action.
Map<String, dynamic> labelledSongs() {
  final Map<String, dynamic> doc = songs(rows: 3);
  for (final Object? row in doc['rows'] as List) {
    final Map<String, dynamic> r = row as Map<String, dynamic>;
    r['Spotify'] = '[Suche öffnen](${r['Spotify']})';
  }
  return doc;
}

/// A price comparison — numbers on the right, a highlighted cell, prose in the
/// last column that has to be cut.
ParsedTable prices() => ParsedTable(
  header: const <String>['Modell', 'Offizieller Shop', 'Amazon.de'],
  rows: const <List<String>>[
    <String>['Active 2 (Standard)', '99,90 €', 'ab ~74,77 €'],
    <String>[
      '**Active 2 Premium (NFC)**',
      '**129,90 €**',
      'nur noch über Drittanbieter, kein reguläres Angebot',
    ],
    <String>['Active 3 Premium (Nachfolger)', '–', '~128,60–144,18 €'],
  ],
  alignments: const <TextAlign>[
    TextAlign.left,
    TextAlign.right,
    TextAlign.left,
  ],
);

/// Seven columns at phone width: the case that has to pan.
ParsedTable wideGrid() => ParsedTable(
  header: const <String>[
    'Land',
    'Gold',
    'Silber',
    'Bronze',
    'Gesamt',
    'Athleten',
    'Quote',
  ],
  rows: const <List<String>>[
    <String>['Deutschland', '12', '9', '14', '35', '412', '8,5 %'],
    <String>['Frankreich', '16', '26', '22', '64', '573', '11,2 %'],
    <String>['Vereinigtes Königreich', '14', '22', '29', '65', '327', '19,9 %'],
    <String>['Niederlande', '15', '7', '12', '34', '298', '11,4 %'],
  ],
  alignments: const <TextAlign>[
    TextAlign.left,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
  ],
);

Future<void> _shoot(
  WidgetTester tester,
  Widget child,
  String name, {
  Brightness brightness = Brightness.dark,
  double width = 360,
  double height = 620,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final ThemeData theme = chartTheme(brightness);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, height),
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Material(
          color: theme.colorScheme.surface,
          child: RepaintBoundary(
            key: const ValueKey<String>('table-shot'),
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
    find.byKey(const ValueKey<String>('table-shot')),
    matchesGoldenFile('$_shots/$name.png'),
  );
}

void _nothing() {}
void _open(String href) {}

/// The block as the thread draws it, in the bubble it sits in.
Widget inline(Map<String, dynamic> document) => Padding(
  padding: const EdgeInsets.all(12),
  child: SingleChildScrollView(
    child: InlineChatDocument(document: document, onOpen: _nothing),
  ),
);

/// The reader, as the phone screen shows it minus its floating bar.
Widget reader(Map<String, dynamic> document) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  child: ChatDocumentView(document: document),
);

/// A bare table, the way markdown prose puts one in a bubble.
Widget bare(ParsedTable table, {double fontSize = 13.5}) => Builder(
  builder: (BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: ChukTable(
          table: table,
          textColor: scheme.onSurface,
          accentColor: scheme.primary,
          fontSize: fontSize,
          surfaceColor: scheme.surface,
          onTapLink: _open,
        ),
      ),
    );
  },
);

void main() {
  setUpAll(loadChartFonts);

  testWidgets('two rows in the thread, dark', (WidgetTester tester) async {
    await _shoot(tester, inline(songs()), 'table_songs_2_dark');
  });

  testWidgets('two rows in the thread, light', (WidgetTester tester) async {
    await _shoot(
      tester,
      inline(songs()),
      'table_songs_2_light',
      brightness: Brightness.light,
    );
  });

  testWidgets('eight rows in the thread', (WidgetTester tester) async {
    await _shoot(tester, inline(songs(rows: 8)), 'table_songs_8_dark');
  });

  testWidgets('eight rows at 1.3 text scale', (WidgetTester tester) async {
    await _shoot(
      tester,
      inline(songs(rows: 8)),
      'table_songs_8_scale13',
      textScale: 1.3,
      height: 760,
    );
  });

  testWidgets('the coworker wrote its own link labels', (
    WidgetTester tester,
  ) async {
    await _shoot(tester, inline(labelledSongs()), 'table_songs_labelled');
  });

  testWidgets('eight rows in the reader', (WidgetTester tester) async {
    await _shoot(tester, reader(songs(rows: 8)), 'table_songs_reader');
  });

  testWidgets('eight rows in the reader on a desktop', (
    WidgetTester tester,
  ) async {
    await _shoot(
      tester,
      reader(songs(rows: 8)),
      'table_songs_reader_wide',
      width: 900,
      height: 520,
      brightness: Brightness.light,
    );
  });

  testWidgets('a price table on a phone', (WidgetTester tester) async {
    await _shoot(tester, bare(prices()), 'table_prices_phone', height: 300);
  });

  testWidgets('a price table at 1.3 text scale', (WidgetTester tester) async {
    await _shoot(
      tester,
      bare(prices()),
      'table_prices_scale13',
      textScale: 1.3,
      height: 340,
    );
  });

  testWidgets('seven columns have to pan', (WidgetTester tester) async {
    await _shoot(tester, bare(wideGrid()), 'table_wide_pan', height: 300);
  });

  testWidgets('seven columns on a desktop fit', (WidgetTester tester) async {
    await _shoot(
      tester,
      bare(wideGrid(), fontSize: 14),
      'table_wide_desktop',
      width: 900,
      height: 280,
      brightness: Brightness.light,
    );
  });
}
