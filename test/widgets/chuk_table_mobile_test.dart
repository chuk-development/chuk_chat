import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cowork/widgets/chuk_table.dart';
import 'package:flutter/services.dart';
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:cowork/ui/expressive/motion.dart';

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
    body: SingleChildScrollView(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  _linkTests();
  _copyControlTests();

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
    expect(
      find.byType(SingleChildScrollView),
      findsOneWidget,
    ); // the test's own
    // Each header past the first labels its field, once per row.
    expect(find.text('Offizieller Shop'), findsNWidgets(3));
    expect(find.text('Amazon.de'), findsNWidgets(3));
    // The value that used to be off the right edge is on screen.
    expect(find.textContaining('nur noch über Drittanbieter'), findsOneWidget);
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
            alignments: const [TextAlign.left, TextAlign.left, TextAlign.left],
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

// The copy control used to be a bare 15 px glyph with no container and no
// label: under the card's bottom-right corner it read as a stray icon rather
// than a button. It is now the app's own button family — a MorphTap at the
// smallest labelled target height — flush with the card's right edge.
void _copyControlTests() {
  ParsedTable small() => ParsedTable(
    header: const ['A', 'B'],
    rows: const [
      ['1', '2'],
    ],
    alignments: const [TextAlign.left, TextAlign.left],
  );

  testWidgets('the copy control is a labelled 38 px button on the card edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: small(),
          textColor: Colors.black,
          accentColor: Colors.green,
        ),
        360,
      ),
    );
    await tester.pump();

    // It says what it does, and it is the expressive press surface, not a
    // bare InkWell floating on nothing.
    expect(find.text('Copy'), findsOneWidget);
    final Finder button = find.ancestor(
      of: find.text('Copy'),
      matching: find.byType(MorphTap),
    );
    expect(button, findsOneWidget);
    expect(tester.getSize(button).height, 38);

    // The app's own glyph, not a Material one.
    final HugeIcon glyph = tester.widget<HugeIcon>(
      find.descendant(of: button, matching: find.byType(HugeIcon)),
    );
    expect(glyph.icon.name, 'copy01');

    // Right edge of the control lines up with the right edge of the table.
    expect(
      tester.getBottomRight(button).dx,
      moreOrLessEquals(
        tester.getBottomRight(find.byType(ChukTable)).dx,
        epsilon: 0.5,
      ),
    );
    // And it hangs below the table, never over it.
    expect(
      tester.getTopLeft(button).dy,
      greaterThan(tester.getBottomLeft(find.byType(Table)).dy),
    );
  });

  testWidgets('in the scrolling grid it clears the table and the scrollbar', (
    tester,
  ) async {
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

    // Wide enough to scroll sideways rather than stack.
    expect(find.byType(Scrollbar), findsOneWidget);
    final Finder button = find.ancestor(
      of: find.text('Copy'),
      matching: find.byType(MorphTap),
    );
    // Below the scroller, so it covers neither a cell nor the scrollbar.
    expect(
      tester.getTopLeft(button).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byType(Scrollbar)).dy),
    );
    // Still on the right edge of the lane the table fills.
    expect(
      tester.getBottomRight(button).dx,
      moreOrLessEquals(
        tester.getBottomRight(find.byType(ChukTable)).dx,
        epsilon: 0.5,
      ),
    );
  });

  testWidgets('a tap copies the markdown and says so, then goes back', (
    tester,
  ) async {
    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _wrap(
        ChukTable(
          table: small(),
          textColor: Colors.black,
          accentColor: Colors.green,
        ),
        360,
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Copy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final MethodCall copy = calls.firstWhere(
      (MethodCall c) => c.method == 'Clipboard.setData',
    );
    expect(
      (copy.arguments as Map)['text'],
      '| A | B |\n| --- | --- |\n| 1 | 2 |',
    );

    // The confirmation is legible: a tick and the word, in the accent.
    expect(find.text('Copied'), findsOneWidget);
    final HugeIcon glyph = tester.widget<HugeIcon>(
      find.descendant(
        of: find.ancestor(
          of: find.text('Copied'),
          matching: find.byType(MorphTap),
        ),
        matching: find.byType(HugeIcon),
      ),
    );
    expect(glyph.icon.name, 'tick02');

    // And then it goes back.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Copied'), findsNothing);
  });
}
