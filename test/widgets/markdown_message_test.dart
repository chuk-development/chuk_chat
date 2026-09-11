// Widget tests for the phone chat markdown renderer.
//
// The assertions look at the built `InlineSpan` tree, because that is where
// the bugs lived: `markdown_widget` merges an inline style onto the paragraph
// style with `inlineStyle.merge(parentStyle)`, and `TextStyle.merge` discards
// the receiver whenever the argument carries `inherit: false` — which every
// style taken from a `TextTheme` does.

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import 'package:cowork/widgets/markdown_message.dart';

const Color kAccent = Color(0xFF1565C0);
const Color kText = Color(0xFF111111);
const Color kBubble = Color(0xFFFFFFFF);

ThemeData _theme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: kAccent,
    primary: kAccent,
  ),
);

Future<void> _pumpMarkdown(
  WidgetTester tester,
  String markdown, {
  double width = 360,
  double? fontSize,
  Color textColor = kText,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: MarkdownMessage(
                text: markdown,
                textColor: textColor,
                backgroundColor: kBubble,
                paragraphFontSize: fontSize,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
/// 2 s highlight timeout, so no timer is left pending at the end of a test.
Future<void> _settleCodeBlocks(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 3));
  await tester.pump();
}

/// Every leaf `TextSpan` in the widget tree, with its resolved style.
List<TextSpan> _leafSpans(WidgetTester tester) {
  final List<TextSpan> out = <TextSpan>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null && span.text!.isNotEmpty) out.add(span);
      for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
    final InlineSpan? span = text.textSpan;
    if (span != null) walk(span);
  }
  return out;
}

/// The leaf span whose text is exactly [text].
TextSpan _span(WidgetTester tester, String text) {
  final List<TextSpan> hits = _leafSpans(
    tester,
  ).where((TextSpan s) => s.text == text).toList();
  expect(hits, isNotEmpty, reason: 'no span with text "$text"');
  return hits.first;
}

void main() {
  group('links', () {
    testWidgets('a link is underlined and painted in the accent colour', (
      tester,
    ) async {
      await _pumpMarkdown(tester, 'see [the docs](https://example.com/docs) ok');

      final TextSpan link = _span(tester, 'the docs');
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.style?.color, kAccent);
      expect(link.style?.decorationColor, kAccent);
      expect(link.recognizer, isNotNull);

      // Prose around the link is untouched.
      expect(_span(tester, 'see ').style?.decoration, isNot(
        TextDecoration.underline,
      ));
      expect(_span(tester, 'see ').style?.color, kText);
    });

    testWidgets('a bare URL is linkified and underlined', (tester) async {
      await _pumpMarkdown(tester, 'go to https://example.com/bare now');

      final TextSpan link = _span(tester, 'https://example.com/bare');
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.style?.color, kAccent);
      expect(link.recognizer, isNotNull);
    });

    testWidgets('a link inside a heading keeps the heading size', (
      tester,
    ) async {
      await _pumpMarkdown(tester, '## title [link](https://example.com/h) end');

      final double headingSize = _span(tester, 'title ').style!.fontSize!;
      final TextSpan link = _span(tester, 'link');
      expect(link.style?.fontSize, headingSize);
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.style?.color, kAccent);
    });

    testWidgets('a link inside bold text stays bold and underlined', (
      tester,
    ) async {
      await _pumpMarkdown(tester, '**lead [link](https://example.com/b) tail**');

      final TextSpan link = _span(tester, 'link');
      expect(link.style?.fontWeight, FontWeight.bold);
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.style?.color, kAccent);
    });

    testWidgets('tapping a link asks before it leaves the app', (tester) async {
      await _pumpMarkdown(tester, 'open [click me](https://example.com/x) now');

      await tester.tapOnText(find.textRange.ofSubstring('click me'));
      await tester.pumpAndSettle();

      expect(find.text('Open Link'), findsOneWidget);
      expect(find.text('https://example.com/x'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets('a link with an unsupported scheme is blocked', (tester) async {
      await _pumpMarkdown(tester, 'run [go](javascript:alert(1)) now');

      await tester.tapOnText(find.textRange.ofSubstring('go'));
      await tester.pumpAndSettle();

      expect(find.text('Link blocked'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
    });
  });

  group('inline styles', () {
    testWidgets('bold, italic and strikethrough', (tester) async {
      await _pumpMarkdown(tester, '**bold** and *slanted* and ~~gone~~');

      expect(_span(tester, 'bold').style?.fontWeight, FontWeight.bold);
      expect(_span(tester, 'slanted').style?.fontStyle, FontStyle.italic);
      expect(
        _span(tester, 'gone').style?.decoration,
        TextDecoration.lineThrough,
      );
    });

    testWidgets('inline code in a paragraph is monospace on a chip', (
      tester,
    ) async {
      await _pumpMarkdown(tester, 'call `flutter test` first');

      final TextSpan code = _span(tester, 'flutter test');
      expect(code.style?.fontFamily, 'monospace');
      expect(code.style?.backgroundColor, isNotNull);
      expect(code.style?.color, isNot(kText));
      // Smaller than the prose it sits in, but not tiny.
      expect(code.style!.fontSize!, lessThan(14.0));
      expect(code.style!.fontSize!, greaterThan(11.0));
    });

    testWidgets('inline code keeps its chip inside headings, quotes and lists', (
      tester,
    ) async {
      await _pumpMarkdown(tester, '''
### heading `hcode`

> quote `qcode`

- item `lcode`
''');

      for (final String token in <String>['hcode', 'qcode', 'lcode']) {
        final TextSpan code = _span(tester, token);
        expect(code.style?.fontFamily, 'monospace', reason: token);
        expect(code.style?.backgroundColor, isNotNull, reason: token);
      }

      // Code in a heading follows the heading size.
      final double headingSize = _span(tester, 'heading ').style!.fontSize!;
      expect(_span(tester, 'hcode').style!.fontSize!, greaterThan(14.0));
      expect(_span(tester, 'hcode').style!.fontSize!, lessThan(headingSize + 1));
    });
  });

  group('headings', () {
    testWidgets('h1 to h6 never grow again on the way down', (tester) async {
      await _pumpMarkdown(tester, '''
# one

## two

### three

#### four

##### five

###### six
''');

      final List<double> sizes = <String>[
        'one',
        'two',
        'three',
        'four',
        'five',
        'six',
      ].map((String t) => _span(tester, t).style!.fontSize!).toList();

      for (int i = 1; i < sizes.length; i++) {
        expect(
          sizes[i],
          lessThan(sizes[i - 1]),
          reason: 'h${i + 1} (${sizes[i]}) is not smaller than h$i '
              '(${sizes[i - 1]})',
        );
      }
      expect(_span(tester, 'one').style?.fontWeight, FontWeight.w700);
      expect(_span(tester, 'six').style?.fontWeight, FontWeight.w600);
    });

    testWidgets('heading sizes follow the chat font size', (tester) async {
      await _pumpMarkdown(tester, '## title', fontSize: 14);
      final double small = _span(tester, 'title').style!.fontSize!;

      await _pumpMarkdown(tester, '## title', fontSize: 20);
      final double large = _span(tester, 'title').style!.fontSize!;

      expect(large, greaterThan(small));
    });
  });

  group('blocks', () {
    testWidgets('a fenced block shows its language, a copy button and scrolls', (
      tester,
    ) async {
      await _pumpMarkdown(tester, '''
```python
def f():
    return 1
```
''');
      await _settleCodeBlocks(tester);

      expect(find.text('python'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.textContaining('def f():'), findsOneWidget);

      final Finder scroller = find.descendant(
        of: find.ancestor(
          of: find.text('python'),
          matching: find.byType(Column),
        ).last,
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
        ),
      );
      expect(scroller, findsWidgets);
    });

    testWidgets('a block quote and a horizontal rule render', (tester) async {
      await _pumpMarkdown(tester, '''
> quoted line

---

after
''');

      expect(_span(tester, 'quoted line').style?.color, isNotNull);
      expect(_span(tester, 'after'), isNotNull);
      // The rule is a thin full-width box.
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.constraints?.maxHeight == 1 &&
              w.constraints?.minHeight == 1,
        ),
        findsWidgets,
      );
    });

    testWidgets('inline and block math render as math, not raw LaTeX', (
      tester,
    ) async {
      await _pumpMarkdown(tester, r'''
inline \(a^2 + b^2\) done

$$E = mc^2$$
''');

      expect(find.byType(Math), findsNWidgets(2));
      expect(find.textContaining(r'a^2'), findsNothing);
    });
  });

  group('lists', () {
    testWidgets('nested ordered and unordered lists render every item', (
      tester,
    ) async {
      await _pumpMarkdown(tester, '''
1. first
2. second
   - nested a
   - nested b
     1. deep one
''');

      for (final String t in <String>[
        'first',
        'second',
        'nested a',
        'nested b',
        'deep one',
      ]) {
        expect(_span(tester, t), isNotNull);
      }
      expect(find.text('1.'), findsWidgets);
      expect(find.text('2.'), findsOneWidget);
    });

    testWidgets('list markers use the bubble text colour', (tester) async {
      const Color onDark = Color(0xFFEFEFEF);
      await _pumpMarkdown(
        tester,
        '- bullet item\n\n1. numbered item',
        textColor: onDark,
      );

      final Text number = tester.widget<Text>(find.text('1.'));
      expect(number.style?.color, onDark);

      final Iterable<Container> bullets = tester
          .widgetList<Container>(find.byType(Container))
          .where(
            (Container c) =>
                c.constraints?.maxWidth == 6 && c.constraints?.maxHeight == 6,
          );
      expect(bullets, isNotEmpty);
      final BoxDecoration decoration =
          bullets.first.decoration! as BoxDecoration;
      expect(decoration.color ?? decoration.border?.top.color, onDark);
    });

    testWidgets('a list item can hold a fenced code block', (tester) async {
      await _pumpMarkdown(tester, '''
- step one

  ```dart
  void main() {}
  ```

- step two
''');
      await _settleCodeBlocks(tester);

      expect(_span(tester, 'step one'), isNotNull);
      expect(_span(tester, 'step two'), isNotNull);
      expect(find.text('dart'), findsOneWidget);
      expect(find.textContaining('void main() {}'), findsOneWidget);
    });

    testWidgets('task lists show an empty and a ticked box', (tester) async {
      await _pumpMarkdown(tester, '- [ ] open\n- [x] done');

      expect(findIcon(Icons.check_box_outline_blank), findsOneWidget);
      expect(findIcon(Icons.check_box), findsOneWidget);
      expect(_span(tester, 'open'), isNotNull);
      expect(_span(tester, 'done'), isNotNull);
    });
  });

  group('overflow', () {
    testWidgets('a long URL and a long word stay inside the bubble', (
      tester,
    ) async {
      await _pumpMarkdown(tester, '''
https://example.com/a/very/long/unbrokenurlaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

Unbrokenwordwithnobreakopportunitiesatallxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
''', width: 260);

      for (final Element e in find.byType(RichText).evaluate()) {
        final RenderBox box = e.renderObject! as RenderBox;
        expect(
          box.size.width,
          lessThanOrEqualTo(260.0),
          reason: 'a paragraph is wider than the bubble',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long code line scrolls instead of widening the bubble', (
      tester,
    ) async {
      await _pumpMarkdown(tester, '''
```dart
final x = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
```
''', width: 260);
      await _settleCodeBlocks(tester);

      final RenderBox outer =
          tester.renderObject(find.byType(MarkdownMessage)) as RenderBox;
      expect(outer.size.width, lessThanOrEqualTo(260.0));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('emoji and CJK survive the renderer', (tester) async {
    await _pumpMarkdown(tester, 'Party 🎉 and 日本語のテキストです。');

    expect(_span(tester, 'Party 🎉 and 日本語のテキストです。'), isNotNull);
    expect(tester.takeException(), isNull);
  });
}
