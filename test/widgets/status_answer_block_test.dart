// Widget tests for the `::: status` answer block (open payments, invoices,
// orders): rows with logo, amount, status chip, date and an action, plus the
// collapsed footer. Phone (390) and desktop (900) widths, no overflow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/markdown_message.dart';

const String _payments = '''
Erledigt, Posteingang ist auf 0.

::: status 4 offene Zahlungen · 122,20 € + 50 \$
Hetzner | Kartenzahlung für Rechnung 089001286347 fehlgeschlagen | 102,20 € | failed Fehlgeschlagen | 16.10. | hetzner.com | Bezahlen https://accounts.hetzner.com/invoice
CodeRabbit | Seit 22.09. überfällig, Karte abgelehnt | 30 \$ | overdue Überfällig | 01.10. | coderabbit.ai | Mail öffnen https://app.coderabbit.ai/settings/billing
Abliteration AI | Abbuchung fehlgeschlagen, Zahlungsmethode aktualisieren | 20 \$ | failed Fehlgeschlagen | 01.10. | abliteration.ai
Mobbin | Zahlungsmethode aktualisieren, sonst endet das Abo | | due Letzte Chance | 18.10. | mobbin.com | https://mobbin.com/settings
more: Ältere Erinnerungen (Tailscale, Lebara …)
Tailscale | Zahlungserinnerung | 6 \$ | ok Bezahlt | 02.09. | tailscale.com
Lebara | Rechnung September | 10 € | ok | 05.09. | lebara.de
:::
''';

Future<void> _pump(
  WidgetTester tester,
  String markdown, {
  required double width,
  double textScale = 1,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width + 40, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width + 40, 2400),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: MarkdownMessage(
                  text: markdown,
                  textColor: dark
                      ? const Color(0xFFEEE6DA)
                      : const Color(0xFF111111),
                  backgroundColor: dark
                      ? const Color(0xFF2A2421)
                      : const Color(0xFFFFFFFF),
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

String _allText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((RichText r) => r.text.toPlainText())
    .join('\n');

void main() {
  for (final double width in <double>[390, 900]) {
    for (final double scale in <double>[1, 1.3, 2]) {
      testWidgets('status at $width px, text x$scale: rows, no overflow', (
        WidgetTester tester,
      ) async {
        await _pump(tester, _payments, width: width, textScale: scale, dark: true);
        // Favicons fail in tests and fall back; let the retries settle.
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        final String all = _allText(tester);
        expect(all, contains('4 offene Zahlungen'));
        expect(all, contains('122,20 € + 50 \$'));
        expect(all, contains('Hetzner'));
        expect(all, contains('102,20 €'));
        expect(all, contains('Fehlgeschlagen'));
        expect(all, contains('Überfällig'));
        expect(all, contains('Letzte Chance'));
        expect(all, contains('16.10.'));
        expect(all, contains('Bezahlen'));
        expect(all, contains('Ältere Erinnerungen'));
        // The footer rows stay collapsed.
        expect(all, isNot(contains('Tailscale | ')));
        expect(find.text('Zahlungserinnerung'), findsNothing);
        expect(all, isNot(contains(':::')));
      });
    }
  }

  testWidgets('narrow status row grows at text x2 and keeps name and amount', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _payments, width: 390, textScale: 2);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    // The name and amount row is taller than its 28 px floor now, so the
    // text is not clipped.
    final Size name = tester.getSize(find.text('Hetzner').first);
    expect(name.height, greaterThan(28));
    expect(find.text('102,20 €'), findsOneWidget);
  });

  testWidgets('status footer opens and shows the older rows', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _payments, width: 390);
    await tester.tap(find.textContaining('Ältere Erinnerungen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Zahlungserinnerung'), findsOneWidget);
    expect(find.text('Bezahlt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status action asks before it opens the link', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _payments, width: 390);
    await tester.tap(find.text('Bezahlen'));
    await tester.pumpAndSettle();
    expect(find.text('Open Link'), findsOneWidget);
    expect(find.textContaining('accounts.hetzner.com'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Open Link'), findsNothing);
  });

  testWidgets('status at 390 px in light theme with long values', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: status\n'
      'Ein sehr langer Firmenname der nicht in die Zeile passt GmbH & Co. KG | '
      'Eine lange Beschreibung die über mehrere Zeilen laufen würde wenn man sie liesse | '
      '12.345.678,90 € | overdue Seit drei Wochen überfällig und gemahnt | 01.01.2026 | '
      'example.com | Rechnung jetzt bezahlen https://example.com/pay\n'
      ':::',
      width: 390,
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
  });
}
