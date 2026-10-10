// Widget tests for the B1 text blocks: Card sources and citations,
// CardHeader, TextContent, MarkDownRenderer, Callout, TextCallout,
// CodeBlock, InlineHeader, Separator.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'openui_test_helper.dart';

Finder _rich(String text) => find.textContaining(text, findRichText: true);

/// The texts of every tappable span (a link) on screen.
List<String> _linkSpanTexts(WidgetTester tester) {
  final out = <String>[];
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    rt.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        out.add(span.toPlainText());
      }
      return true;
    });
  }
  return out;
}

void main() {
  group('Card and citations', () {
    testWidgets('a citation with a source URL is a link', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([TextContent("[1]")], '
        '[{title: "T", sourceName: "Wiki", url: "https://w.org"}])\n',
      );
      expect(_rich('[1]'), findsWidgets);
      await tester.tap(_rich('[1]').first);
      await tester.pumpAndSettle();
      // The app's markdown asks before it leaves the app.
      expect(find.text('Open Link'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('adjacent citations [1][2] are both links', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([TextContent("Alpha [1][2] beta")], '
        '[{title: "A", sourceName: "A", url: "https://a.org"}, '
        '{title: "B", sourceName: "B", url: "https://b.org"}])\n',
      );
      expect(_linkSpanTexts(tester), containsAll(<String>['[1]', '[2]']));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a reference link [a][1] is not a citation', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([TextContent("See [x][1] now")], '
        '[{title: "A", sourceName: "A", url: "https://a.org"}])\n',
      );
      expect(_linkSpanTexts(tester), isNot(contains('[1]')));
    });

    testWidgets('a marker with no source goes away', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([TextContent("Alpha [1] beta [7] gamma")], '
        '[{title: "T", sourceName: "Wiki", url: "https://w.org"}])\n',
      );
      expect(_rich('[7]'), findsNothing);
      expect(_rich('gamma'), findsOneWidget);
    });

    testWidgets('without sources the text stays as written', (tester) async {
      await pumpOpenUi(tester, 'root = Card([TextContent("Note [2] here")])\n');
      expect(_rich('[2]'), findsOneWidget);
    });

    testWidgets('code spans keep their brackets', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([TextContent("Use `a[1]` and `[9]`")], '
        '[{title: "T", sourceName: "S", url: "https://w.org"}])\n',
      );
      expect(_rich('[9]'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('bad sources do not throw', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([TextContent("x [1] [2]")], '
        '[{title: 3}, "nope", {url: "javascript:alert(1)", title: "J", '
        'sourceName: "J"}])\n',
      );
      expect(tester.takeException(), isNull);
      expect(find.text('J'), findsOneWidget);
    });
  });

  testWidgets('CardHeader and InlineHeader render and skip empty', (
    tester,
  ) async {
    await pumpOpenUi(
      tester,
      'root = Card([h, e, i])\n'
      'h = CardHeader("Paris", "City of Light")\n'
      'e = CardHeader()\n'
      'i = InlineHeader("Numbers", "Key stats")\n',
    );
    expect(find.text('Paris'), findsOneWidget);
    expect(find.text('City of Light'), findsOneWidget);
    expect(find.text('Numbers'), findsOneWidget);
    expect(find.text('Key stats'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MarkDownRenderer draws every variant', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([a, b, c, d])\n'
      'a = MarkDownRenderer("Clear **text**")\n'
      'b = MarkDownRenderer("Card text", "card")\n'
      'c = MarkDownRenderer("Sunk text", "sunk")\n'
      'd = MarkDownRenderer(42, "bogus")\n',
    );
    expect(_rich('Clear'), findsOneWidget);
    expect(_rich('Card text'), findsOneWidget);
    expect(_rich('Sunk text'), findsOneWidget);
    expect(_rich('42'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Callout', () {
    testWidgets('renders every variant, light and dark', (tester) async {
      for (final b in Brightness.values) {
        await pumpOpenUi(
          tester,
          'root = Card([a, b, c, d, e])\n'
          'a = Callout("info", "Info title", "Some *detail*")\n'
          'b = Callout("warning", "Warn", "w")\n'
          'c = Callout("error", "Err", "e")\n'
          'd = Callout("success", "Ok", "s")\n'
          'e = Callout("neutral", "Plain", "n")\n',
          brightness: b,
        );
        expect(find.text('Info title'), findsOneWidget);
        expect(find.text('Plain'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a \$visible binding hides it after 3 s', (tester) async {
      final h = await pumpOpenUi(
        tester,
        '\$visible = true\n'
        'root = Card([c])\n'
        'c = Callout("success", "Saved", "All done", \$visible)\n',
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Saved'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsNothing);
      expect(h.states.last[r'$visible'], false);
    });

    testWidgets('without a binding it stays', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([Callout("info", "Stays", "here")])\n',
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('Stays'), findsOneWidget);
    });

    testWidgets('bad input does not throw', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([Callout("purple", null, ["x"]), Callout()])\n',
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('TextCallout renders and skips empty', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([a, b, c])\n'
      'a = TextCallout("warning", "Heads up", "Check the **date**")\n'
      'b = TextCallout()\n'
      'c = TextCallout("weird", "Fallback")\n',
      brightness: Brightness.light,
    );
    expect(find.text('Heads up'), findsOneWidget);
    expect(find.text('Fallback'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CodeBlock shows the code, also with backticks inside', (
    tester,
  ) async {
    await pumpOpenUi(
      tester,
      'root = Card([a, b, c])\n'
      'a = CodeBlock("python", "print(1)")\n'
      'b = CodeBlock("md", "```js\\nx\\n```")\n'
      'c = CodeBlock(null, "")\n',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(_rich('print(1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The highlighter of the code block keeps a 2 s timer.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Separator draws both orientations', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([Separator(), Separator("vertical", false), '
      'Separator("diagonal", "x"), '
      'Stack([TextContent("L"), Separator("vertical"), TextContent("R")], '
      '"row")])\n',
    );
    expect(tester.takeException(), isNull);
    expect(_rich('L'), findsWidgets);
  });
}
