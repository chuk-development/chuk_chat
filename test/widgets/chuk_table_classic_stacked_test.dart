import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/widgets/chuk_table.dart';
import 'package:chuk_chat/widgets/chuk_table_classic.dart';

const List<String> _shopTable = <String>[
  '| Produkt | Preis | Bewertung |',
  '|---|---|---|',
  '| [CAMWAY DA-Wandler 192 kHz, optisch auf 3,5 mm, mit Lautstärkeregler, Kabel inklusive](https://www.amazon.de/dp/B0BFHFSX4C) | 13,99 € (5 %-Coupon) | 4,4 (2.865) |',
  '| [AUTOUTLET DA-Wandler 192 kHz, Toslink auf 3,5 mm/RCA, Kabel inklusive](https://www.amazon.de/dp/B0BRFVMCJV) | 12,59 € | 4,5 (3.555) |',
];

Future<void> _pump(
  WidgetTester tester,
  double width, {
  ValueChanged<String>? onTapLink,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: ChukTableClassic(
                table: parseTable(_shopTable)!,
                textColor: Colors.black,
                accentColor: Colors.orange,
                onTapLink: onTapLink,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps the link span whose text contains [needle].
bool _tapLink(WidgetTester tester, String needle) {
  for (final RichText rt in tester.widgetList<RichText>(
    find.byType(RichText),
  )) {
    bool hit = false;
    rt.text.visitChildren((InlineSpan span) {
      if (span is TextSpan &&
          (span.text ?? '').contains(needle) &&
          span.recognizer is TapGestureRecognizer) {
        (span.recognizer! as TapGestureRecognizer).onTap!();
        hit = true;
        return false;
      }
      return true;
    });
    if (hit) return true;
  }
  return false;
}

void main() {
  testWidgets('a wide table on a phone becomes one card per row', (
    tester,
  ) async {
    await _pump(tester, 360);
    expect(find.byKey(const ValueKey<String>('chuk-table-stacked')), findsOne);
    expect(find.byType(Table), findsNothing);
    expect(find.byType(Scrollbar), findsNothing);
    // Every value is on screen, each with its column header as label.
    expect(find.text('Preis'), findsNWidgets(2));
    expect(find.text('Bewertung'), findsNWidgets(2));
    expect(find.text('12,59 €'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide window keeps the table', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, 1200);
    expect(
      find.byKey(const ValueKey<String>('chuk-table-stacked')),
      findsNothing,
    );
    expect(find.byType(Table), findsOne);
  });

  testWidgets('links in cells open through onTapLink', (tester) async {
    final List<String> opened = <String>[];
    await _pump(tester, 360, onTapLink: opened.add);
    expect(_tapLink(tester, 'AUTOUTLET'), isTrue);
    expect(opened, <String>['https://www.amazon.de/dp/B0BRFVMCJV']);

    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, 1200, onTapLink: opened.add);
    expect(_tapLink(tester, 'CAMWAY'), isTrue);
    expect(opened.last, 'https://www.amazon.de/dp/B0BFHFSX4C');
  });

  testWidgets('without onTapLink a link is not tappable', (tester) async {
    await _pump(tester, 360);
    expect(_tapLink(tester, 'AUTOUTLET'), isFalse);
  });
}
