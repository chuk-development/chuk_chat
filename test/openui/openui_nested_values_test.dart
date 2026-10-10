// Components inside nested arrays and object literals: the renderer
// resolves them to widgets, so `Carousel([[a, b], [c, d]])` and a
// CompositeCardItem footer `{price: BoldText(...), button: Button(...)}`
// draw their contents.
// ignore_for_file: experimental_member_use

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

Finder _rich(String text) => find.textContaining(text, findRichText: true);

Future<void> _pump(WidgetTester tester, String source) async {
  await tester.pumpWidget(
    openUiTestApp(
      OpenUiView(source: source, actionHandler: RecordingOpenUiHandler()),
      width: 720,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Carousel with nested slides, inline and by reference', (
    tester,
  ) async {
    await _pump(
      tester,
      'root = Card([Carousel([[TextContent("Inline A1"), '
      'TextContent("Inline A2")], [TextContent("Inline B1"), '
      'TextContent("Inline B2")]]), Carousel(slides)])\n'
      'slides = [[TextContent("Ref C1"), d], [TextContent("Ref E1"), '
      'TextContent("Ref E2")]]\n'
      'd = TextContent("Ref C2")\n',
    );
    expect(tester.takeException(), isNull);
    for (final s in <String>[
      'Inline A1',
      'Inline A2',
      'Inline B1',
      'Inline B2',
      'Ref C1',
      'Ref C2',
      'Ref E1',
      'Ref E2',
    ]) {
      expect(_rich(s), findsOneWidget, reason: s);
    }
  });

  testWidgets('CompositeCardItem footer with components', (tester) async {
    await _pump(
      tester,
      'root = Card([CompositeCardBlock([CompositeCardItem("p1", '
      'Text("text", "Plan"), [Text("text", "Monthly")], '
      '{price: BoldText("number", "9 €"), button: Button("Buy")})])])\n',
    );
    expect(tester.takeException(), isNull);
    expect(_rich('9 €'), findsOneWidget);
    expect(_rich('Buy'), findsOneWidget);
  });
}
