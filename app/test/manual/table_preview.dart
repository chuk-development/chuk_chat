// A preview entry point, for looking at a table on a real device.
//
// Not shipped: it lives under `test/`, so no build of the app includes it. It
// exists because a green test says nothing about whether a table READS as a
// table, and the widget tests render on a desktop host. This puts the real
// widget on the real Android surface at the real density.
//
//   flutter run -d emulator-5554 -t test/manual/table_preview.dart
//
// Then `scripts/emulator.sh shot _scratch/shots/<name>.png` and LOOK at it.
// The switch at the top changes the text scale, because 1.3 is the size the
// layout suite holds every screen to and the size that breaks tables.

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/chat_document_inline.dart';

/// The Songs document the coworker wrote: the reel it came from, the song,
/// the artist, and the Spotify search that opens it. Real rows, including a
/// Cyrillic title and an artist name too long for a phone column.
Map<String, dynamic> songs({int rows = 2, bool labelled = false}) {
  const List<List<String>> all = <List<String>>[
    <String>[
      'https://www.instagram.com/reel/DKx7vQ2sT1a/',
      "I'm God",
      'Clams Casino',
      'https://open.spotify.com/search/I%27m%20God%20Clams%20Casino',
    ],
    <String>[
      'https://www.instagram.com/reel/DLp2mNQoQ8z/',
      'Детка, я потерял контроль',
      'Три Дня Дождя',
      'https://open.spotify.com/search/%D0%94%D0%B5%D1%82%D0%BA%D0%B0',
    ],
    <String>[
      'https://www.instagram.com/reel/DMa4rVvsJ0k/',
      'Take Me Back to Eden',
      'Sleep Token',
      'https://open.spotify.com/search/Take%20Me%20Back%20To%20Eden',
    ],
    <String>[
      'https://www.instagram.com/reel/DNb8wXysP2q/',
      'Nunca Es Suficiente',
      'Los Ángeles Azules, Natalia Lafourcade',
      'https://open.spotify.com/search/Nunca%20Es%20Suficiente',
    ],
    <String>[
      'https://www.instagram.com/reel/DOc1yZzsR4w/',
      'Пыяла',
      'АИГЕЛ',
      'https://open.spotify.com/search/%D0%9F%D1%8B%D1%8F%D0%BB%D0%B0',
    ],
    <String>[
      'https://www.instagram.com/reel/DPd5aBcsT6e/',
      'Murder in My Mind',
      'Kordhell',
      'https://open.spotify.com/search/Murder%20In%20My%20Mind',
    ],
    <String>[
      'https://www.instagram.com/reel/DQe9cDesV8r/',
      'Sweater Weather',
      'The Neighbourhood',
      'https://open.spotify.com/search/Sweater%20Weather',
    ],
    <String>[
      'https://www.instagram.com/reel/DRf2eFgsX0t/',
      'Une Barque sur l’Océan',
      'Maurice Ravel',
      'https://open.spotify.com/search/Une%20Barque',
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
          'Spotify': labelled ? '[Suche öffnen](${r[3]})' : r[3],
        },
    ],
  };
}

/// A price comparison: a number column, a highlighted cell, and prose in the
/// last column that has to be cut.
Map<String, dynamic> prices() => <String, dynamic>{
  'id': 'preise',
  'title': 'Amazfit Active · Preise',
  'kind': 'table',
  'version': 3,
  'updated_at': 1789251300.0,
  'columns': <String>['Modell', 'Offizieller Shop', 'Amazon.de'],
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{
      'Modell': 'Active 2 (Standard)',
      'Offizieller Shop': '99.90',
      'Amazon.de': 'ab ~74,77 €',
    },
    <String, dynamic>{
      'Modell': 'Active 2 Premium (NFC)',
      'Offizieller Shop': '129.90',
      'Amazon.de': 'nur noch über Drittanbieter, kein reguläres Angebot',
    },
    <String, dynamic>{
      'Modell': 'Active 3 Premium (Nachfolger)',
      'Offizieller Shop': '149.90',
      'Amazon.de': '~128,60–144,18 €',
    },
  ],
};

void main() => runApp(const TablePreviewApp());

class TablePreviewApp extends StatefulWidget {
  const TablePreviewApp({super.key});

  @override
  State<TablePreviewApp> createState() => _TablePreviewAppState();
}

class _TablePreviewAppState extends State<TablePreviewApp> {
  double _scale = 1.0;
  Brightness _brightness = Brightness.dark;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2962FF),
        brightness: _brightness,
      ),
      fontFamily: 'Roboto',
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(_scale)),
          child: Scaffold(
            backgroundColor: theme.colorScheme.surface,
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: () =>
                            setState(() => _scale = _scale == 1.0 ? 1.3 : 1.0),
                        child: Text('scale ${_scale.toStringAsFixed(1)}'),
                      ),
                      TextButton(
                        onPressed: () => setState(
                          () => _brightness = _brightness == Brightness.dark
                              ? Brightness.light
                              : Brightness.dark,
                        ),
                        child: const Text('theme'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      children: <Widget>[
                        InlineChatDocument(
                          document: songs(),
                          onOpen: () {},
                        ),
                        const SizedBox(height: 14),
                        InlineChatDocument(
                          document: songs(rows: 8),
                          onOpen: () {},
                        ),
                        const SizedBox(height: 14),
                        InlineChatDocument(
                          document: songs(rows: 3, labelled: true),
                          onOpen: () {},
                        ),
                        const SizedBox(height: 14),
                        InlineChatDocument(
                          document: prices(),
                          onOpen: () {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
