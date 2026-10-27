// Widget tests for the static answer blocks drawn by MarkdownMessage:
// `::: steps`, `::: timeline`, `::: scale` and the GitHub alerts.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

const Color _text = Color(0xFF111111);
const Color _bubble = Color(0xFFFFFFFF);

Future<void> _pump(
  WidgetTester tester,
  String markdown, {
  double width = 360,
  double textScale = 1,
  ValueChanged<String>? onFollowUp,
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
                  onFollowUp: onFollowUp,
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

  testWidgets('bars: labels, values, sublines, note, no overflow at 1.3', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: bars BF16 · nur Modellgewichte\n'
      'Step 5 | ~1.200 GB | 600B Gesamtparameter\n'
      'DeepSeek Flash | ~1.104 GB | 552B Gesamtparameter\n'
      'GLM Flash | ~640 GB | 320B Gesamtparameter\n'
      '! Parameter × 2 Byte — zusätzlicher Laufzeitspeicher nötig\n'
      ':::',
      textScale: 1.3,
    );
    expect(_allText(tester), contains('Step 5'));
    expect(_allText(tester), contains('~1.200 GB'));
    expect(_allText(tester), contains('320B Gesamtparameter'));
    expect(_allText(tester), contains('zusätzlicher Laufzeitspeicher nötig'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('kpi: tiles with value, label and icon', (WidgetTester tester) async {
    await _pump(
      tester,
      '::: kpi\n'
      '82 % | Luftfeuchtigkeit | droplet\n'
      '7 km/h S | Wind aus Süden | wind\n'
      ':::',
    );
    expect(find.text('82 %'), findsOneWidget);
    expect(find.text('Luftfeuchtigkeit'), findsOneWidget);
    expect(find.text('7 km/h S'), findsOneWidget);
    expect(find.byType(HugeIcon), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiles: label tiles render, three per row', (WidgetTester tester) async {
    await _pump(
      tester,
      '::: tiles Bot\n'
      'Chatbot | chat\n'
      'Such-Crawler | search\n'
      'Spiele-Bot | game\n'
      ':::',
      textScale: 1.3,
    );
    expect(find.text('Chatbot'), findsOneWidget);
    expect(find.text('Such-Crawler'), findsOneWidget);
    expect(find.text('Spiele-Bot'), findsOneWidget);
    expect(find.byType(HugeIcon), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards: carousel renders card content and counter', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: cards Hotels\n'
      'Alpenruhe Panorama\n'
      'badge: Für deinen Bergmoment\n'
      'subtitle: Grindelwald, Schweiz\n'
      'meta: 4,8 · 128 Bewertungen\n'
      'chips: Panoramabalkon, Berg-Spa\n'
      'price: 248 CHF / Nacht\n'
      '--\n'
      'Felsenblick\n'
      'price: 219 CHF / Nacht\n'
      ':::',
      textScale: 1.3,
    );
    expect(_allText(tester), contains('Alpenruhe Panorama'));
    expect(_allText(tester), contains('Grindelwald, Schweiz'));
    expect(_allText(tester), contains('248 CHF / Nacht'));
    expect(_allText(tester), contains('Panoramabalkon'));
    expect(_allText(tester), contains('1 / 2 Hotels'));
    // No network access in tests: the image-less cards must not throw, and a
    // card with a broken image URL falls back to its placeholder.
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards: image URL that fails loading falls back, no throw', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: cards\n'
      'Hotel mit Bild\n'
      'image: https://example.invalid/broken.jpg\n'
      ':::',
    );
    expect(_allText(tester), contains('Hotel mit Bild'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards: private-network image URLs are never requested', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: cards\n'
      'Lokales Bild\n'
      'image: https://127.0.0.1/secret.jpg\n'
      ':::',
    );
    expect(_allText(tester), contains('Lokales Bild'));
    // The placeholder renders, but no network image is created for a
    // loopback host — the model must not make the app knock on itself.
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ask: chips tap sends the label', (WidgetTester tester) async {
    final List<String> sent = <String>[];
    await _pump(
      tester,
      '::: ask Welche Rechenbasis möchtest du verstehen?\n'
      'Aktive Parameter\n'
      'BF16 & FP8\n'
      ':::',
      onFollowUp: (String text) => sent.add(text),
    );
    expect(_allText(tester), contains('Welche Rechenbasis möchtest du verstehen?'));
    await tester.tap(find.text('Aktive Parameter'));
    expect(sent, <String>['Aktive Parameter']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ask: without a callback the chips stay visible', (
    WidgetTester tester,
  ) async {
    await _pump(tester, '::: ask\nEin Thema\nNoch eins\n:::');
    expect(find.text('Ein Thema'), findsOneWidget);
    expect(find.text('Noch eins'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source: an old block renders nothing', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: source\n'
      'Notizen zur Tagesplanung | https://example.org/notizen\n'
      ':::',
    );
    expect(_allText(tester), isNot(contains('Notizen zur Tagesplanung')));
    expect(_allText(tester), isNot(contains(':::')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('kpi: two tiles share one row at phone width', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: kpi\n'
      '82 % | Luftfeuchtigkeit | droplet\n'
      '7 km/h S | Wind aus Süden | wind\n'
      ':::',
    );
    // Both tiles side by side: same row (equal tops), second starts after
    // the first ends.
    final Rect first = tester.getRect(find.text('82 %'));
    final Rect second = tester.getRect(find.text('7 km/h S'));
    expect((first.top - second.top).abs(), lessThan(2));
    expect(second.left, greaterThan(first.right));
    expect(tester.takeException(), isNull);
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

  // -------------------------------------------------------------------------
  // Figma visual library ("Bergmomente", "Ruhemodus" and the example chats)

  const String bergmomente =
      '::: cards Hotels\n'
      'Alpenruhe Panorama\n'
      'badge: Für deinen Bergmoment\n'
      'location: Grindelwald, Schweiz\n'
      'rating: 4,8 · 128 Bewertungen\n'
      'chips: Panoramabalkon, Berg-Spa\n'
      'specs: ANC · Adaptiv | sound, 38 Std. Akku | battery\n'
      'price: 248 CHF / Nacht\n'
      'url: https://example.com/a\n'
      'action: Details\n'
      'ask: Vergleichen\n'
      '--\n'
      'Felsenblick\n'
      'badge: Talblick\n'
      'price: 219 CHF / Nacht\n'
      ':::';

  testWidgets('cards: location, rating, specs, price unit, two buttons', (
    WidgetTester tester,
  ) async {
    final List<String> sent = <String>[];
    await _pump(tester, bergmomente, onFollowUp: sent.add, textScale: 1.3);
    final String all = _allText(tester);
    expect(all, contains('Grindelwald, Schweiz'));
    expect(all, contains('4,8 · 128 Bewertungen'));
    expect(all, contains('ANC · Adaptiv'));
    expect(all, contains('38 Std. Akku'));
    expect(all, contains('248 CHF / Nacht'));
    // A card without an image shows its badge as a chip.
    expect(all, contains('Talblick'));
    expect(find.text('Details'), findsWidgets);
    await tester.tap(find.text('Vergleichen').first);
    expect(sent, <String>['Vergleichen: Alpenruhe Panorama']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards: no overflow from 200 to 600 px, text scale 1.3', (
    WidgetTester tester,
  ) async {
    for (final double width in <double>[200, 260, 360, 600]) {
      await _pump(tester, bergmomente, width: width, textScale: 1.3);
      expect(tester.takeException(), isNull, reason: 'width $width');
    }
  });

  testWidgets('ask: icon chips send the label only, button sends too', (
    WidgetTester tester,
  ) async {
    final List<String> sent = <String>[];
    await _pump(
      tester,
      '::: ask Lieber Wellness oder loswandern?\n'
      'Mit Wellness | sparkles\n'
      'Nah am Wanderweg | mountain\n'
      'button: Aktuelle Werte abrufen\n'
      ':::',
      onFollowUp: sent.add,
    );
    expect(find.byType(HugeIcon), findsNWidgets(2));
    await tester.tap(find.text('Mit Wellness'));
    await tester.tap(find.text('Aktuelle Werte abrufen'));
    expect(sent, <String>['Mit Wellness', 'Aktuelle Werte abrufen']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('check: items render, a tap toggles the box', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: check Für den Antrag bereitlegen\n'
      '[x] Alter Ausweis\n'
      '[ ] Digitales biometrisches Foto / Fotocode; Fotoangebot im Amt prüfen\n'
      ':::',
      textScale: 1.3,
    );
    expect(_allText(tester), contains('Für den Antrag bereitlegen'));
    bool? checked(String label) => tester
        .widget<Semantics>(
          find.byWidgetPredicate(
            (Widget w) => w is Semantics && w.properties.label == label,
          ),
        )
        .properties
        .checked;
    expect(checked('Alter Ausweis'), isTrue);
    await tester.tap(find.text('Alter Ausweis'));
    await tester.pump();
    expect(checked('Alter Ausweis'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('term, grid, sizes, quote: render without overflow at 360/1.3', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: term Zwei Namen\n'
      'ARD | Arbeitsgemeinschaft der Rundfunkanstalten\n'
      'De·ge·to | **De**utsche **Ge**sellschaft für **To**n und Bild\n'
      'note: ARD - Degeto Film\n'
      ':::\n'
      '::: grid 11 von 24\n'
      '1* 2 3 4 5* 6*\n'
      '7 8+ 9 10 11 12*\n'
      '* In der Liste\n'
      '- Nicht geprüft\n'
      ':::\n'
      '::: sizes Rauchmelder\n'
      'Normal | 12 cm | fire\n'
      'Mini | 6 cm\n'
      '! Kleiner heißt nicht sicherer\n'
      ':::\n'
      '::: quote NASDAQ: PYPL\n'
      'price: 56,70 USD\n'
      'change: -0,46 USD (-0,80 %)\n'
      'note: Schlusskurs\n'
      'points: 57.16, 56.4, 57.4, 56.7\n'
      'labels: 12.10, 13.10, 14.10, 15.10\n'
      ':::',
      textScale: 1.3,
    );
    final String all = _allText(tester);
    for (final String t in <String>[
      'ARD',
      'De·ge·to',
      'Arbeitsgemeinschaft der Rundfunkanstalten',
      'ARD - Degeto Film',
      '11 von 24',
      '12',
      'In der Liste',
      'Normal',
      '6 cm',
      'Kleiner heißt nicht sicherer',
      'NASDAQ: PYPL',
      '56,70 USD',
      '-0,46 USD (-0,80 %)',
      '15.10',
    ]) {
      expect(all, contains(t), reason: t);
    }
    expect(all, isNot(contains(':::')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('grid: 12 columns fit a 260 px column', (WidgetTester tester) async {
    await _pump(
      tester,
      '::: grid\n${List<String>.generate(12, (int i) => '${i + 10}*').join(' ')}\n:::',
      width: 260,
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('more: body is hidden until the header is tapped', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: more Auf dem Handy fehlt etwas?\n'
      'Lokale Dateien in der mobilen App aktivieren.\n'
      ':::',
    );
    expect(_allText(tester), contains('Auf dem Handy fehlt etwas?'));
    expect(_allText(tester), isNot(contains('Lokale Dateien')));
    await tester.tap(find.text('Auf dem Handy fehlt etwas?'));
    await tester.pumpAndSettle();
    expect(_allText(tester), contains('Lokale Dateien in der mobilen App aktivieren.'));
    expect(tester.takeException(), isNull);
  });
}
