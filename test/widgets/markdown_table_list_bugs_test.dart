// Reproductions of two rendering bugs in AI answers on a phone:
//
// chuk_chat-wvtv: a wide table with three columns of long German text. The
// horizontal scrollbar lay across the last row (over "Sequentiell"), the
// columns were cut off with no hint, and every cell stayed on one line.
//
// chuk_chat-z0q4: `- **Goethe:** Faust ...` inside a `::: timeline` block.
// The bold name went into the narrow, right-aligned date column as plain text
// (literal `**`, broken mid-word) and the rest sat right of the rail.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/chuk_table_classic.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

const String kWideGermanTable =
    'Hier der Vergleich:\n\n'
    '| Ansatz | Ablauf im Detail | Vor- und Nachteile |\n'
    '|---|---|---|\n'
    '| Parallel | Alle Teilaufgaben laufen gleichzeitig auf mehreren Kernen '
    'und werden am Ende wieder zusammengeführt | Schnell bei großen '
    'Datenmengen, aber höherer Speicherverbrauch und schwierigere '
    'Fehlersuche |\n'
    '| Sequentiell | Jede Teilaufgabe wartet, bis die vorherige vollständig '
    'abgeschlossen ist | Einfach nachzuvollziehen und deterministisch, aber '
    'deutlich langsamer bei unabhängigen Aufgaben |\n'
    '\nDanach geht es weiter.';

const String kGoetheItem =
    '- **Goethe:** Faust I & II (Riesengeschichte – Mephisto-Wette, '
    'Gretchentragödie), Der Erlkönig, Die Leiden des jungen Werthers\n'
    '- **Schiller**: Die Räuber, Wilhelm Tell: Freiheitsdrama\n'
    '  - Kabale und Liebe\n';

Future<void> _pump(WidgetTester tester, String text, {double width = 360}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: MarkdownMessage(
                text: text,
                textColor: Colors.black,
                backgroundColor: Colors.white,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Every piece of text on screen, with the bold state of each run.
List<(String, bool)> _runs(WidgetTester tester) {
  final List<(String, bool)> out = <(String, bool)>[];
  for (final Element e in find.byType(RichText).evaluate()) {
    final RichText rt = e.widget as RichText;
    void walk(InlineSpan span, TextStyle? inherited) {
      if (span is! TextSpan) return;
      final TextStyle? style = inherited?.merge(span.style) ?? span.style;
      final String? t = span.text;
      if (t != null && t.isNotEmpty) {
        out.add((
          t,
          (style?.fontWeight?.value ?? 400) >= FontWeight.w600.value,
        ));
      }
      for (final InlineSpan c in span.children ?? const <InlineSpan>[]) {
        walk(c, style);
      }
    }

    walk(rt.text, null);
  }
  return out;
}

final Finder _tableScroller = find.descendant(
  of: find.byType(ChukTableClassic),
  matching: find.byWidgetPredicate(
    (Widget w) =>
        w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
  ),
);

RenderParagraph _paragraphWith(WidgetTester tester, String text) {
  final Finder f = find.descendant(
    of: find.byType(ChukTableClassic),
    matching: find.byWidgetPredicate(
      (Widget w) => w is RichText && w.text.toPlainText() == text,
    ),
  );
  expect(f, findsOneWidget, reason: 'cell "$text"');
  return tester.renderObject<RenderParagraph>(f);
}

/// Lines a laid-out paragraph takes, from its height and one line's height.
int _lines(RenderParagraph p) =>
    (p.size.height / p.getFullHeightForCaret(const TextPosition(offset: 0)))
        .round();

void main() {
  group('chuk_chat-wvtv wide table on a phone', () {
    testWidgets('a phone shows one card per row: nothing pans, no scrollbar', (
      tester,
    ) async {
      await _pump(tester, kWideGermanTable);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(
        find.byKey(const ValueKey<String>('chuk-table-stacked')),
        findsOne,
      );
      expect(_tableScroller, findsNothing);
      expect(
        find.descendant(
          of: find.byType(ChukTableClassic),
          matching: find.byType(Scrollbar),
        ),
        findsNothing,
      );

      // "Sequentiell" stays one word on one line.
      final RenderParagraph seq = _paragraphWith(tester, 'Sequentiell');
      expect(_lines(seq), 1);

      // A long cell wraps inside the card instead of running off.
      final RenderParagraph long = _paragraphWith(
        tester,
        'Jede Teilaufgabe wartet, bis die vorherige vollständig '
        'abgeschlossen ist',
      );
      expect(_lines(long), greaterThan(1));

      // The text after the table is not covered or pushed sideways.
      expect(find.text('Danach geht es weiter.'), findsOneWidget);
    });

    testWidgets('desktop: the scrollbar has its own lane under the card', (
      tester,
    ) async {
      await _pump(tester, kWideGermanTable, width: 660);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final Finder bar = find.descendant(
        of: find.byType(ChukTableClassic),
        matching: find.byType(Scrollbar),
      );
      expect(bar, findsOneWidget);
      final Rect viewport = tester.getRect(_tableScroller);
      final Rect lastRow = tester.getRect(
        find.descendant(
          of: find.byType(ChukTableClassic),
          matching: find.byType(Table),
        ),
      );
      // The thumb is painted in the bottom 12 px of the viewport; the table
      // ends above that lane.
      expect(lastRow.bottom, lessThanOrEqualTo(viewport.bottom - 12 + 0.5));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a table that fits wraps and fills, without a scroller', (
      tester,
    ) async {
      await _pump(
        tester,
        '| A | B |\n|---|---|\n| kurz | auch kurz |\n',
        width: 360,
      );
      await tester.pumpAndSettle();
      expect(_tableScroller, findsNothing);
    });
  });

  group('chuk_chat-z0q4 bold list labels', () {
    testWidgets('plain list: bold label inline, no literal **', (tester) async {
      await _pump(tester, kGoetheItem);
      await tester.pumpAndSettle();
      final List<(String, bool)> runs = _runs(tester);
      expect(runs.any((r) => r.$1.contains('**')), isFalse);
      expect(runs.any((r) => r.$1.trim() == 'Goethe:' && r.$2), isTrue);
      expect(runs.any((r) => r.$1.trim() == 'Schiller' && r.$2), isTrue);
    });

    testWidgets('::: timeline without dates renders as the plain list', (
      tester,
    ) async {
      await _pump(tester, '::: timeline Klassiker\n$kGoetheItem:::\n');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final List<(String, bool)> runs = _runs(tester);
      expect(runs.any((r) => r.$1.contains('**')), isFalse);
      // The name is bold text in the bullet, not a label of its own.
      expect(runs.any((r) => r.$1.trim() == 'Goethe:' && r.$2), isTrue);
      final String all = runs.map((r) => r.$1).join();
      expect(all, contains('Faust I & II (Riesengeschichte'));
      expect(all, contains('Kabale und Liebe'));
      // No right-aligned date column.
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Text && w.textAlign == TextAlign.right,
        ),
        findsNothing,
      );
    });

    testWidgets('a dated timeline keeps its date column, bold stripped', (
      tester,
    ) async {
      await _pump(
        tester,
        '::: timeline\n- **1774**: Werther\n- 1808: Faust I\n- 1832: Faust II\n:::\n',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('1774'), findsOneWidget);
      expect(find.text('1808'), findsOneWidget);
      expect(_runs(tester).any((r) => r.$1.contains('**')), isFalse);
    });
  });
}
