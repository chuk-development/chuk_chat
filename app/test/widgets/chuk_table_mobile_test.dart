import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cowork/widgets/chuk_table.dart';

/// Bead cowork-8vqt: a table wider than a phone column used to become a
/// sideways-scrolling grid with 160-pixel columns. The right-hand columns sat
/// off screen and nothing said they were there, so the answer read as broken.
/// Narrow now means stacked: one card per row, every field labelled.
ParsedTable _prices() => ParsedTable(
  header: const ['Modell', 'Offizieller Shop', 'Amazon.de'],
  rows: const [
    ['Active 2 (Standard)', '99,90 €', 'ab ~74,77 €'],
    [
      '**Active 2 Premium (NFC)**',
      '**129,90 €**',
      'nur noch über Drittanbieter, kein reguläres Angebot',
    ],
    ['Active 3 Premium (Nachfolger)', '–', '~128,60–144,18 €'],
  ],
  alignments: const [TextAlign.left, TextAlign.left, TextAlign.left],
);

Widget _wrap(Widget child, double width) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: width, child: child)),
  ),
);

void main() {
  _linkTests();

  testWidgets('a wide table stacks on a phone instead of scrolling sideways', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: _prices(),
          textColor: Colors.black,
          accentColor: Colors.green,
        ),
        360,
      ),
    );
    await tester.pump();

    // No grid, and nothing to pan: every value is in the column.
    expect(find.byType(Table), findsNothing);
    expect(find.byType(SingleChildScrollView), findsOneWidget); // the test's own
    // Each header past the first labels its field, once per row.
    expect(find.text('Offizieller Shop'), findsNWidgets(3));
    expect(find.text('Amazon.de'), findsNWidgets(3));
    // The value that used to be off the right edge is on screen.
    expect(
      find.textContaining('nur noch über Drittanbieter'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty cell contributes no field', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: ParsedTable(
            header: const ['Modell', 'Shop', 'Amazon'],
            rows: const [
              [
                'Active 3 Premium (Nachfolger)',
                '',
                'nur noch über Drittanbieter, kein reguläres Angebot',
              ],
            ],
            alignments: const [
              TextAlign.left,
              TextAlign.left,
              TextAlign.left,
            ],
          ),
          textColor: Colors.black,
          accentColor: Colors.green,
        ),
        360,
      ),
    );
    await tester.pump();
    expect(find.text('Shop'), findsNothing);
    expect(find.text('Amazon'), findsOneWidget);
  });

  testWidgets('a narrow table that fits still renders as a grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: ParsedTable(
            header: const ['A', 'B'],
            rows: const [
              ['1', '2'],
            ],
            alignments: const [TextAlign.left, TextAlign.right],
          ),
          textColor: Colors.black,
          accentColor: Colors.green,
        ),
        360,
      ),
    );
    await tester.pump();
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('a wide layout keeps the scrolling grid', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: _prices(),
          textColor: Colors.black,
          accentColor: Colors.green,
        ),
        900,
      ),
    );
    await tester.pump();
    expect(find.byType(Table), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

// Bead cowork-94s9: the coworker puts its source links in comparison tables.
// They used to be accent-coloured text with no underline and no recognizer, so
// they read as links and did nothing.
void _linkTests() {
  ParsedTable withLink() => ParsedTable(
    header: const ['Modell', 'Quelle'],
    rows: const [
      ['Active 2', '[Amazfit-Shop](https://de.amazfit.com/products/active-2)'],
    ],
    alignments: const [TextAlign.left, TextAlign.left],
  );

  testWidgets('a link in a cell is underlined and opens', (tester) async {
    String? opened;
    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: withLink(),
          textColor: Colors.black,
          accentColor: Colors.green,
          onTapLink: (href) => opened = href,
        ),
        360,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Amazfit-Shop'), findsOneWidget);

    TextSpan? link;
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text == 'Amazfit-Shop') link = span;
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    for (final element in find.byType(Text).evaluate()) {
      final Text widget = element.widget as Text;
      final InlineSpan? span = widget.textSpan;
      if (span != null) walk(span);
    }
    expect(link, isNotNull);
    expect(link!.style?.decoration, TextDecoration.underline);
    expect(link!.style?.color, Colors.green);
    expect(link!.recognizer, isA<TapGestureRecognizer>());
    (link!.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, 'https://de.amazfit.com/products/active-2');
  });

  testWidgets('with no handler a link still reads as one', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: withLink(),
          textColor: Colors.black,
          accentColor: Colors.green,
        ),
        360,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Amazfit-Shop'), findsOneWidget);
  });
}
