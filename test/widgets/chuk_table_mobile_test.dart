import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/widgets/chuk_table.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

import 'charts/chart_test_support.dart';

/// Bead cowork-8vqt, then the redesign that followed it.
///
/// A table wider than a phone column used to become a sideways-scrolling grid
/// with the right-hand columns off screen. The first answer was one card per
/// row, every field labelled — which fit, and read as a stack of forms: no two
/// rows lined up, so the one thing a table is for was impossible, and two rows
/// filled a phone.
///
/// It is a table again now: the header once, a row on one line, every column
/// on the same x in every row.
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
  alignments: const [TextAlign.left, TextAlign.right, TextAlign.left],
);

/// Seven columns: more than a phone can honestly hold.
ParsedTable _wide() => ParsedTable(
  header: const ['Land', 'Gold', 'Silber', 'Bronze', 'Gesamt', 'Sportler', 'Quote'],
  rows: const [
    ['Deutschland', '12', '9', '14', '35', '412', '8,5 %'],
    ['Frankreich', '16', '26', '22', '64', '573', '11,2 %'],
  ],
  alignments: const [
    TextAlign.left,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
    TextAlign.right,
  ],
);

Widget _wrap(Widget child, double width) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

ChukTable _table(ParsedTable table, {ValueChanged<String>? onTapLink}) =>
    ChukTable(
      table: table,
      textColor: Colors.black,
      accentColor: Colors.green,
      onTapLink: onTapLink,
    );

/// The left edge of the first Text painting [text].
double _leftOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dx;

void main() {
  // Real glyphs, not the square test font: a layout assertion about what fits
  // in a column is meaningless against a font where every letter is a box.
  setUpAll(loadChartFonts);

  _linkTests();
  _copyControlTests();

  testWidgets('the header is printed once, not on every row', (tester) async {
    await tester.pumpWidget(_wrap(_table(_prices()), 360));
    await tester.pump();

    for (final String label in <String>[
      'Modell',
      'Offizieller Shop',
      'Amazon.de',
    ]) {
      // Once. A label under every value is the noise a header removes.
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same column lands on the same x in every row', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_table(_prices()), 360));
    await tester.pump();

    // The whole point of the format: run the eye down a column.
    expect(
      _leftOf(tester, 'Active 2 (Standard)'),
      moreOrLessEquals(_leftOf(tester, 'Active 3 Premium (Nachfolger)'),
          epsilon: 0.5),
    );
    expect(
      _leftOf(tester, 'ab ~74,77 €'),
      moreOrLessEquals(_leftOf(tester, '~128,60–144,18 €'), epsilon: 0.5),
    );
  });

  testWidgets('a row is one line, so three rows are not a screenful', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_table(_prices()), 360));
    await tester.pump();

    // Header, three rows, rules and the copy button, at a chat font size.
    expect(tester.getSize(find.byType(ChukTable)).height, lessThan(220));
  });

  testWidgets('a number never ellipsises, whatever else has to', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_table(_prices()), 360));
    await tester.pump();

    // A right-aligned column is a number column, and "129,9…" reads as a
    // price and is not one.
    expect(find.text('99,90 €'), findsOneWidget);
    final RenderParagraph price = tester.renderObject<RenderParagraph>(
      find.text('99,90 €'),
    );
    expect(price.didExceedMaxLines, isFalse);
  });

  testWidgets('a table that fits does not pan', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _table(
          ParsedTable(
            header: const ['A', 'B'],
            rows: const [
              ['1', '2'],
            ],
            alignments: const [TextAlign.left, TextAlign.right],
          ),
        ),
        360,
      ),
    );
    await tester.pump();
    expect(find.byType(Scrollbar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide window fits the columns instead of panning', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_table(_prices()), 900));
    await tester.pump();
    expect(find.byType(Scrollbar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('too many columns pan, with the first one pinned', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_table(_wide()), 360));
    await tester.pump();

    // It says it pans: a scrollbar that stays on screen.
    expect(find.byType(Scrollbar), findsOneWidget);
    // And the subject stands still — it is outside the scroller.
    expect(
      find.descendant(
        of: find.byType(Scrollbar),
        matching: find.text('Deutschland'),
      ),
      findsNothing,
    );
    expect(find.text('Deutschland'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty cell draws nothing and takes no room', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _table(
          ParsedTable(
            header: const ['Modell', 'Shop', 'Amazon'],
            rows: const [
              ['Active 3', '', 'nur über Drittanbieter'],
              ['Active 2', '99,90 €', 'ab 74,77 €'],
            ],
            alignments: const [
              TextAlign.left,
              TextAlign.left,
              TextAlign.left,
            ],
          ),
        ),
        360,
      ),
    );
    await tester.pump();
    // The column name still shows — once, in the header.
    expect(find.text('Shop'), findsOneWidget);
    expect(find.text('99,90 €'), findsOneWidget);
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

  testWidgets('with no handler a link is not drawn as one', (tester) async {
    await tester.pumpWidget(_wrap(_table(withLink()), 360));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Amazfit-Shop'), findsOneWidget);

    // A link nothing can open is not a link. It reads as the plain text it
    // behaves like, rather than promising a tap that does nothing.
    TextSpan? span;
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.text == 'Amazfit-Shop') span = s;
        for (final InlineSpan child in s.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    for (final Element element in find.byType(Text).evaluate()) {
      final InlineSpan? text = (element.widget as Text).textSpan;
      if (text != null) walk(text);
    }
    expect(span, isNotNull);
    expect(span!.recognizer, isNull);
    expect(span!.style?.decoration, isNot(TextDecoration.underline));
  });

  // The coworker writes the reel URL and the Spotify search URL into every
  // row. Labelled with their host, the whole column reads "open.spotify.com"
  // three times over: the same string in every row, which is no information
  // at all, taking a quarter of a phone's width. It becomes the action it is.
  ParsedTable sameHost() => ParsedTable(
    header: const ['Song', 'Spotify'],
    rows: const [
      ["I'm God", '[open.spotify.com](https://open.spotify.com/search/god)'],
      ['Пыяла', '[open.spotify.com](https://open.spotify.com/search/pyyala)'],
    ],
    alignments: const [TextAlign.left, TextAlign.left],
  );

  testWidgets('a column of one repeated host becomes one arrow', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      _wrap(_table(sameHost(), onTapLink: (String h) => opened = h), 360),
    );
    await tester.pump();

    expect(find.text('open.spotify.com'), findsNothing);
    // The header, printed once, is what says where the arrow goes.
    expect(find.text('Spotify'), findsOneWidget);
    final Finder arrows = find.byWidgetPredicate(
      (Widget w) => w is HugeIcon && w.icon.name == 'arrow-up-right01',
    );
    expect(arrows, findsNWidgets(2));

    // And it opens the URL of ITS row.
    await tester.tap(arrows.last);
    expect(opened, 'https://open.spotify.com/search/pyyala');
  });

  testWidgets('a label the document wrote survives, repeated or not', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _table(
          ParsedTable(
            header: const ['Song', 'Spotify'],
            rows: const [
              [
                "I'm God",
                '[Suche öffnen](https://open.spotify.com/search/god)',
              ],
              [
                'Пыяла',
                '[Suche öffnen](https://open.spotify.com/search/pyyala)',
              ],
            ],
            alignments: const [TextAlign.left, TextAlign.left],
          ),
          onTapLink: (String h) {},
        ),
        360,
      ),
    );
    await tester.pump();

    // The app collapses what the APP wrote (a bare host). What the coworker
    // wrote is the coworker talking, and it is kept.
    expect(find.textContaining('Suche'), findsNWidgets(2));
  });
}

// The copy control used to be a bare 15 px glyph with no container and no
// label: under the card's bottom-right corner it read as a stray icon rather
// than a button. It is now the app's own button family — a MorphTap at the
// smallest labelled target height — flush with the table's right edge.
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
        _table(small()),
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
      greaterThan(tester.getBottomLeft(find.text('2')).dy),
    );
  });

  testWidgets('in a panning table it clears the table and the scrollbar', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_table(_wide()), 360));
    await tester.pump();

    // Too many columns for the lane, so the table pans.
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
        _table(small()),
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
