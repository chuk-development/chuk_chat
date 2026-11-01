// How `::: cards` draws: a list when there is nothing to page through for,
// a carousel that also works with a mouse otherwise.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

Future<void> _pump(WidgetTester tester, String text) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MarkdownMessage(
            text: text,
            textColor: Colors.white,
            backgroundColor: Colors.black,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const String _carousel =
    '::: cards Shops\n'
    'First item\nprice: 10 €\n--\n'
    'Second item\nprice: 20 €\n--\n'
    'Third item\nprice: 30 €\n:::\n';

void main() {
  testWidgets('cards with only text are a list with their whole text', (
    tester,
  ) async {
    final String long = List<String>.filled(30, 'word').join(' ');
    await _pump(
      tester,
      '::: cards Options\nOne\n$long.\n--\nTwo\nShort text.\n:::\n',
    );
    expect(find.byType(PageView), findsNothing);
    expect(find.textContaining(long, findRichText: true), findsOneWidget);
    expect(find.textContaining('Short text.', findRichText: true), findsOneWidget);
  });

  testWidgets('the arrow buttons page through the carousel', (tester) async {
    await _pump(tester, _carousel);
    expect(find.byType(PageView), findsOneWidget);
    expect(find.textContaining('1 / 3'), findsOneWidget);
    await tester.tap(
      find.ancestor(
        of: find.byWidgetPredicate(
          (w) => w is HugeIcon && w.icon == HugeIcons.arrowRight01,
        ),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 3'), findsOneWidget);
  });

  testWidgets('a mouse drag moves the carousel', (tester) async {
    await _pump(tester, _carousel);
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(-400, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 3'), findsNothing);
  });
}
