// Widget tests for the B1 layout components: Stack, Tabs, Accordion,
// Steps, Carousel, SectionBlock, Modal.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';

import 'openui_test_helper.dart';

Finder _rich(String text) => find.textContaining(text, findRichText: true);

/// Pumps [source] at [width] (phone 360, desktop chat 720).
Future<void> _pumpAt(
  WidgetTester tester,
  String source, {
  double width = 360,
  bool isStreaming = false,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    openUiTestApp(
      OpenUiView(
        source: source,
        isStreaming: isStreaming,
        actionHandler: RecordingOpenUiHandler(),
      ),
      width: width,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  group('Stack', () {
    testWidgets('row, column and wrap render at 360 and 720', (tester) async {
      for (final w in <double>[360, 720]) {
        await _pumpAt(
          tester,
          'root = Card([r, c, wr])\n'
          'r = Stack([TextContent("Left side with a long text that wraps"), '
          'TextContent("Right")], "row", "l", "center", "between")\n'
          'c = Stack([TextContent("Top"), TextContent("Bottom")], "column", '
          '"xs", "center")\n'
          'wr = Stack([Button("A"), Button("B"), Button("C")], "row", "s", '
          '"stretch", "between", true)\n',
          width: w,
        );
        expect(tester.takeException(), isNull, reason: 'width $w');
        expect(_rich('Right'), findsOneWidget);
        expect(find.text('C'), findsOneWidget);
      }
    });

    testWidgets('a row with stretch and baseline does not throw', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        'root = Card([Stack([TextContent("a"), TextContent("b")], "row", '
        '"bogus", "stretch"), Stack([TextContent("c")], "row", "m", '
        '"baseline"), Stack(), Stack("x")])\n',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Tabs', () {
    const program =
        'root = Card([tabs])\n'
        'tabs = Tabs([t1, t2])\n'
        't1 = TabItem("spring", "Spring", [TextContent("Blossoms")])\n'
        't2 = TabItem("summer", "Summer", [TextContent("Swimming")])\n';

    testWidgets('shows the first tab and switches on tap', (tester) async {
      await _pumpAt(tester, program);
      expect(find.byType(ConnectedGroup), findsOneWidget);
      expect(_rich('Blossoms'), findsOneWidget);
      expect(_rich('Swimming'), findsNothing);
      await tester.tap(find.text('Summer'));
      await tester.pumpAndSettle();
      expect(_rich('Swimming'), findsOneWidget);
      expect(_rich('Blossoms'), findsNothing);
    });

    testWidgets('many or long labels scroll instead of squeezing', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        'root = Card([Tabs([a, b, c, d, e])])\n'
        'a = TabItem("a", "A very long first label", [TextContent("one")])\n'
        'b = TabItem("b", "Second", [TextContent("two")])\n'
        'c = TabItem("c", "Third", [TextContent("three")])\n'
        'd = TabItem("d", "Fourth", [TextContent("four")])\n'
        'e = TabItem("e", "Fifth", [TextContent("five")])\n',
      );
      expect(find.byType(ConnectedGroup), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(_rich('two'), findsOneWidget);
    });

    testWidgets('while streaming it follows the newest tab', (tester) async {
      const partial =
          'root = Card([tabs])\n'
          'tabs = Tabs([t1, t2])\n'
          't1 = TabItem("spring", "Spring", [TextContent("Blossoms")])\n';
      await _pumpAt(tester, partial, isStreaming: true, settle: false);
      await _pumpAt(tester, program, isStreaming: true, settle: false);
      await tester.pumpAndSettle();
      expect(_rich('Swimming'), findsOneWidget);
      // The stream ends: back to the first tab.
      await _pumpAt(tester, program);
      expect(_rich('Blossoms'), findsOneWidget);
    });

    testWidgets('bad items do not throw', (tester) async {
      await _pumpAt(
        tester,
        'root = Card([Tabs(), Tabs([]), Tabs(["x", TabItem()]), '
        'Tabs([TabItem("same", "A", []), TabItem("same", "B", "text")])])\n',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Accordion', () {
    const program =
        'root = Card([acc])\n'
        'acc = Accordion([a1, a2])\n'
        'a1 = AccordionItem("q1", "What is it?", [TextContent("Answer one")])\n'
        'a2 = AccordionItem("q2", "How much?", [TextContent("Answer two")])\n';

    testWidgets('opens the first item; a tap switches and closes', (
      tester,
    ) async {
      await _pumpAt(tester, program);
      expect(_rich('Answer one'), findsOneWidget);
      expect(_rich('Answer two'), findsNothing);
      await tester.tap(find.text('How much?'));
      await tester.pumpAndSettle();
      expect(_rich('Answer two'), findsOneWidget);
      expect(_rich('Answer one'), findsNothing);
      await tester.tap(find.text('How much?'));
      await tester.pumpAndSettle();
      expect(_rich('Answer two'), findsNothing);
    });

    testWidgets('bad items do not throw', (tester) async {
      await _pumpAt(
        tester,
        'root = Card([Accordion(), Accordion([AccordionItem()]), '
        'Accordion("x")])\n',
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Steps numbers each step and skips empty ones', (tester) async {
    for (final b in Brightness.values) {
      await pumpOpenUi(
        tester,
        'root = Card([Steps([s1, s2, s3, StepsItem()])])\n'
        's1 = StepsItem("Book", "Pick **dates**")\n'
        's2 = StepsItem("Pack", "Light bag")\n'
        's3 = StepsItem("Go", "")\n',
        brightness: b,
      );
      expect(find.text('1'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsNothing);
      expect(find.text('Book'), findsOneWidget);
      expect(_rich('Light bag'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  group('Carousel', () {
    // One slide per child. The nested form `[[a, b], [c]]` through the
    // renderer is tested in openui_nested_values_test.dart.
    const program =
        'root = Card([Carousel([TextContent("Slide one"), '
        'TextContent("Slide two has more text in it"), '
        'TextContent("Slide three")], "sunk")])\n';

    testWidgets('slides scroll by the arrow buttons', (tester) async {
      await _pumpAt(tester, program);
      expect(_rich('Slide one'), findsOneWidget);
      final scroll = find.byType(SingleChildScrollView).last;
      double offset() =>
          tester.widget<SingleChildScrollView>(scroll).controller!.offset;
      final before = offset();
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(offset(), greaterThan(before));
      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();
      expect(offset(), before);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the builder makes one slide per inner list', (tester) async {
      final def = chukOpenUiLibrary['Carousel']!;
      await tester.pumpWidget(
        openUiTestApp(
          Builder(
            builder: (context) => def.builder!(
              context,
              OpenUiProps(
                component: 'Carousel',
                def: def,
                values: <String, Object?>{
                  'children': <Object?>[
                    <Object?>[const Text('A1'), const Text('A2')],
                    <Object?>[const Text('B1')],
                    <Object?>[null],
                  ],
                },
              ),
            ),
          ),
          width: 720,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A1'), findsOneWidget);
      expect(find.text('A2'), findsOneWidget);
      expect(find.text('B1'), findsOneWidget);
      // The two slides share the height of the taller one.
      final a = tester.getSize(
        find
            .ancestor(of: find.text('A1'), matching: find.byType(DecoratedBox))
            .first,
      );
      final b = tester.getSize(
        find
            .ancestor(of: find.text('B1'), matching: find.byType(DecoratedBox))
            .first,
      );
      expect(a.height, b.height);
      expect(tester.takeException(), isNull);
    });

    testWidgets('bad input does not throw', (tester) async {
      await _pumpAt(
        tester,
        'root = Card([Carousel([TextContent("a"), TextContent("b")]), '
        'Carousel(), Carousel([[]]), Carousel("x", "weird")])\n',
        width: 720,
      );
      expect(tester.takeException(), isNull);
      expect(_rich('b'), findsWidgets);
    });
  });

  group('SectionBlock', () {
    const program =
        'root = Card([sb])\n'
        'sb = SectionBlock([s1, s2])\n'
        's1 = SectionItem("a", "Landmarks", [TextContent("Eiffel")])\n'
        's2 = SectionItem("b", "Food", [TextContent("Bistros")])\n';

    testWidgets('opens the first section; a tap toggles', (tester) async {
      await _pumpAt(tester, program);
      expect(_rich('Eiffel'), findsOneWidget);
      expect(_rich('Bistros'), findsNothing);
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();
      expect(_rich('Bistros'), findsOneWidget);
      expect(_rich('Eiffel'), findsOneWidget);
    });

    testWidgets('opens sections while they stream in', (tester) async {
      const partial =
          'root = Card([sb])\n'
          'sb = SectionBlock([s1, s2])\n'
          's1 = SectionItem("a", "Landmarks", [TextContent("Eiffel")])\n';
      await _pumpAt(tester, partial, isStreaming: true, settle: false);
      await _pumpAt(tester, program, isStreaming: true, settle: false);
      await tester.pumpAndSettle();
      expect(_rich('Eiffel'), findsOneWidget);
      expect(_rich('Bistros'), findsOneWidget);
      // At the end only the first stays open.
      await _pumpAt(tester, program);
      expect(_rich('Eiffel'), findsOneWidget);
      expect(_rich('Bistros'), findsNothing);
    });

    testWidgets('isFoldable false shows every section', (tester) async {
      await _pumpAt(
        tester,
        program.replaceFirst(
          'SectionBlock([s1, s2])',
          'SectionBlock([s1, s2], false)',
        ),
      );
      expect(_rich('Eiffel'), findsOneWidget);
      expect(_rich('Bistros'), findsOneWidget);
    });

    testWidgets('bad input does not throw', (tester) async {
      await _pumpAt(
        tester,
        'root = Card([SectionBlock(), SectionBlock([SectionItem()], "x")])\n',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Modal', () {
    const program =
        '\$open = false\n'
        'root = Card([Button("Show", @Set(\$open, true)), m])\n'
        'm = Modal("Details", \$open, [TextContent("Inside the modal")], '
        '"sm")\n';

    testWidgets('opens on the binding and closes by the X', (tester) async {
      final h = await pumpOpenUi(tester, program);
      expect(_rich('Inside the modal'), findsNothing);
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsOneWidget);
      expect(_rich('Inside the modal'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(_rich('Inside the modal'), findsNothing);
      expect(h.states.last[r'$open'], false);
    });

    testWidgets('Escape and the scrim close it', (tester) async {
      await pumpOpenUi(tester, program);
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_rich('Inside the modal'), findsNothing);
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(_rich('Inside the modal'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(_rich('Inside the modal'), findsNothing);
    });

    testWidgets('a button inside keeps the action scope', (tester) async {
      final h = await pumpOpenUi(
        tester,
        '\$open = true\n'
        'root = Card([Modal("Ask", \$open, [Button("Send it", '
        'Action([@ToAssistant("from modal")]))])])\n',
      );
      await tester.tap(find.text('Send it'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'from modal');
    });

    testWidgets('bad input does not throw', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([Modal(), Modal("t", "yes", "x", "huge")])\n',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
