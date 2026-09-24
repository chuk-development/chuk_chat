// Widget tests for the static answer blocks drawn by MarkdownMessage:
// `::: steps`, `::: timeline`, `::: scale` and the GitHub alerts.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/markdown_message.dart';

const Color _text = Color(0xFF111111);
const Color _bubble = Color(0xFFFFFFFF);

Future<void> _pump(
  WidgetTester tester,
  String markdown, {
  double width = 360,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 1600),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: MarkdownMessage(
                  text: markdown,
                  textColor: _text,
                  backgroundColor: _bubble,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Every RichText's plain text, joined. Finds text inside nested messages.
String _allText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((RichText r) => r.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('steps: numbers, titles, terminal lines with copy, warning', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      'Do this:\n\n'
      '::: steps\n'
      '1. Find the **partition**\n'
      r'$ lsblk -f'
      '\n'
      'Look for:\n'
      '- crypto_LUKS\n'
      '! Not the login password\n'
      '2. Open it\n'
      ':::\n',
    );
    final String all = _allText(tester);
    expect(all, contains('Find the partition'));
    expect(all, contains('lsblk -f'));
    expect(all, contains('Not the login password'));
    expect(all, isNot(contains(':::')));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text(r'$ '), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Nested Markdown: the bold title keeps its bold span, the list is a list.
    final Iterable<RichText> rich = tester.widgetList<RichText>(
      find.byType(RichText),
    );
    bool boldPartition = false;
    for (final RichText r in rich) {
      r.text.visitChildren((InlineSpan span) {
        if (span is TextSpan &&
            span.text == 'partition' &&
            (span.style?.fontWeight?.value ?? 0) >= 700) {
          boldPartition = true;
        }
        return true;
      });
    }
    expect(boldPartition, isTrue);
    expect(all, isNot(contains('- crypto_LUKS')));

    // The copy button copies the command without the prompt.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'lsblk -f');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('steps abc: lettered recipe, no commands', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: steps abc Pancakes\n'
      'a. Mix flour and milk\n'
      'b. Rest ten minutes\n'
      'c. Fry\n'
      ':::',
    );
    expect(find.text('A'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('PANCAKES'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('steps while streaming: the unclosed block renders', (
    WidgetTester tester,
  ) async {
    await _pump(tester, '::: steps\n1. First\n2. Seco');
    final String all = _allText(tester);
    expect(all, contains('First'));
    expect(all, contains('Seco'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('timeline: labels, texts, highlighted entry', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: timeline Keith Gill\n'
      '2019: buys shares\n'
      '*2021-01: short squeeze\n'
      '2023-09: film release\n'
      ':::',
      textScale: 1.3,
    );
    expect(find.text('2019'), findsOneWidget);
    expect(find.text('2021-01'), findsOneWidget);
    expect(find.text('KEITH GILL'), findsOneWidget);
    expect(_allText(tester), contains('short squeeze'));
    final Text hi = tester.widget<Text>(find.text('2021-01'));
    expect(hi.style?.fontWeight, FontWeight.w700);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scale: ticks, marker, no overflow at 360 and 1.3', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: scale 1800–6500 K\n'
      '2000: Candle\n'
      '2700: Warm white\n'
      '4000: Neutral\n'
      '6500: Daylight\n'
      '@ 2700: your lamp\n'
      ':::',
      textScale: 1.3,
    );
    expect(find.text('YOUR LAMP'), findsOneWidget);
    expect(find.text('Candle'), findsOneWidget);
    expect(find.text('6500 K'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The Kelvin band is a warm-to-cold gradient.
    final Iterable<Container> boxes = tester.widgetList<Container>(
      find.byType(Container),
    );
    final bool hasGradient = boxes.any(
      (Container c) =>
          c.decoration is BoxDecoration &&
          (c.decoration! as BoxDecoration).gradient != null,
    );
    expect(hasGradient, isTrue);

    // Marker pill and labels stay inside the block.
    final Rect block = tester.getRect(find.byType(MarkdownMessage).first);
    for (final String label in <String>['YOUR LAMP', 'Candle', 'Daylight']) {
      final Rect r = tester.getRect(find.text(label));
      expect(r.left, greaterThanOrEqualTo(block.left - 0.5), reason: label);
      expect(r.right, lessThanOrEqualTo(block.right + 0.5), reason: label);
    }
  });

  testWidgets('scale that cannot be drawn shows its lines as text', (
    WidgetTester tester,
  ) async {
    await _pump(tester, '::: scale\nonly: words\n:::');
    expect(_allText(tester), contains('only: words'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown directive renders as plain Markdown', (
    WidgetTester tester,
  ) async {
    await _pump(tester, '::: fancy\nSome **text**\n:::');
    final String all = _allText(tester);
    expect(all, contains('Some text'));
    expect(all, isNot(contains(':::')));
  });

  testWidgets('GitHub alert: label and body, no literal [!NOTE]', (
    WidgetTester tester,
  ) async {
    await _pump(tester, '> [!NOTE]\n> Useful `detail`.');
    final String all = _allText(tester);
    expect(find.text('NOTE'), findsOneWidget);
    expect(all, contains('Useful detail.'));
    expect(all, isNot(contains('[!NOTE]')));
  });

  testWidgets('inline code keeps its monospace font in the default build', (
    WidgetTester tester,
  ) async {
    await _pump(tester, 'Run `ls` now\n\n## Head `code`');
    final List<TextSpan> code = <TextSpan>[];
    for (final RichText r in tester.widgetList<RichText>(
      find.byType(RichText),
    )) {
      r.text.visitChildren((InlineSpan span) {
        if (span is TextSpan && (span.text == 'ls' || span.text == 'code')) {
          code.add(span);
        }
        return true;
      });
    }
    expect(code, hasLength(2));
    for (final TextSpan span in code) {
      expect(span.style?.fontFamily, 'monospace');
      expect(span.style?.backgroundColor, isNotNull);
    }
  });

  testWidgets('heading sizes fall from h1 to h6 in the default build', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '# a1\n\n## a2\n\n### a3\n\n#### a4\n\n##### a5\n\n###### a6',
    );
    double size(String t) {
      double? found;
      for (final RichText r in tester.widgetList<RichText>(
        find.byType(RichText),
      )) {
        r.text.visitChildren((InlineSpan span) {
          if (span is TextSpan && span.text == t) found = span.style?.fontSize;
          return true;
        });
      }
      return found!;
    }

    final List<double> sizes = <String>[
      'a1',
      'a2',
      'a3',
      'a4',
      'a5',
      'a6',
    ].map(size).toList();
    for (int i = 1; i < sizes.length; i++) {
      expect(sizes[i], lessThan(sizes[i - 1]), reason: 'h${i + 1}');
    }
  });
}
