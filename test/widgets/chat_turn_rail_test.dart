import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/chat_turn_rail.dart';

List<Map<String, String>> _chat(int turns) => <Map<String, String>>[
  for (int i = 0; i < turns; i++) ...<Map<String, String>>[
    <String, String>{'sender': 'user', 'text': '\nQuestion   $i\nmore'},
    <String, String>{'sender': 'ai', 'text': 'Draft $i'},
    <String, String>{'sender': 'ai', 'text': 'Answer $i\n' * 3},
  ],
];

Finder _strip(int row) => find.byKey(ValueKey<String>('turn-rail-tick-$row'));

double _stripWidth(WidgetTester tester, int row) => tester
    .getSize(
      find.descendant(
        of: _strip(row),
        matching: find.byType(AnimatedContainer),
      ),
    )
    .width;

void main() {
  group('geometry, as T3 MessagesTimeline.logic.ts', () {
    test(
      'ticks: one per user row, collapsed text, last answer of the turn',
      () {
        final List<ChatTurnRailTick> ticks = chatTurnRailTicks(_chat(3));
        expect(ticks.map((t) => t.index), <int>[0, 3, 6]);
        expect(ticks.first.userText, 'Question 0 more');
        expect(ticks.first.assistantText, 'Answer 0 Answer 0 Answer 0');
      },
    );

    test('height: 8 px per gap, capped at window - 288', () {
      expect(chatTurnRailHeight(5, 1000), 32);
      expect(chatTurnRailHeight(500, 800), 512);
      expect(chatTurnRailHeight(1, 800), 1);
    });

    test('index from pointer rounds to the nearest strip', () {
      expect(
        chatTurnRailIndexFromPointer(count: 5, railHeight: 32, pointerY: 0),
        0,
      );
      expect(
        chatTurnRailIndexFromPointer(count: 5, railHeight: 32, pointerY: 13),
        2,
      );
      expect(
        chatTurnRailIndexFromPointer(count: 5, railHeight: 32, pointerY: 99),
        4,
      );
      expect(
        chatTurnRailIndexFromPointer(count: 0, railHeight: 32, pointerY: 5),
        isNull,
      );
    });

    test('gutter and hit strip never reach into the text column', () {
      expect(chatTurnRailGutter(1200, 760), 220);
      expect(chatTurnRailHitStripWidth(220), 40);
      expect(chatTurnRailHitStripWidth(30), 18);
      expect(chatTurnRailHitStripWidth(10), 0);
    });

    test('strip widths by distance: 24 / 16 / 10 / 8', () {
      expect(chatTurnRailStripWidth(0), 24);
      expect(chatTurnRailStripWidth(1), 16);
      expect(chatTurnRailStripWidth(2), 10);
      expect(chatTurnRailStripWidth(3), 8);
      expect(chatTurnRailStripWidth(null), 8);
    });
  });

  Future<void> pumpRail(
    WidgetTester tester, {
    double width = 1400,
    required List<Map<String, String>> messages,
    ValueChanged<int>? onTap,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned.fill(
                child: ChatTurnRail(
                  messages: messages,
                  onTickTap: onTap ?? (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one strip per user message on the left, none under two', (
    tester,
  ) async {
    await pumpRail(tester, messages: _chat(4));
    expect(_strip(0), findsOneWidget);
    expect(_strip(9), findsOneWidget);
    expect(tester.getTopLeft(_strip(0)).dx, 12);

    await pumpRail(tester, messages: _chat(1));
    expect(_strip(0), findsNothing);
  });

  testWidgets('hover grows the strip and its neighbours, shows the card, '
      'a click reports the row', (tester) async {
    int? tapped;
    await pumpRail(tester, messages: _chat(6), onTap: (i) => tapped = i);
    final Offset third = tester.getCenter(_strip(6));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(600, 10));
    await mouse.moveTo(third);
    await tester.pumpAndSettle();

    expect(_stripWidth(tester, 6), 24);
    expect(_stripWidth(tester, 3), 16);
    expect(_stripWidth(tester, 9), 16);
    expect(_stripWidth(tester, 0), 10);
    expect(_stripWidth(tester, 15), 8);
    expect(
      find.byKey(const ValueKey<String>('turn-rail-preview')),
      findsOneWidget,
    );
    expect(find.text('Question 2 more'), findsOneWidget);
    expect(find.text('Answer 2 Answer 2 Answer 2'), findsOneWidget);

    await mouse.down(third);
    await mouse.up();
    await tester.pump();
    expect(tapped, 6);

    // Moving onto the card keeps it open and does not change the strip.
    final Offset card = tester.getCenter(
      find.byKey(const ValueKey<String>('turn-rail-preview')),
    );
    await mouse.moveTo(card);
    await tester.pumpAndSettle();
    expect(find.text('Question 2 more'), findsOneWidget);

    await mouse.moveTo(const Offset(900, 10));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('turn-rail-preview')),
      findsNothing,
    );
  });

  testWidgets('keys move the selection, Enter jumps', (tester) async {
    int? tapped;
    await pumpRail(tester, messages: _chat(4), onTap: (i) => tapped = i);
    final Focus focus = tester.widget<Focus>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('turn-rail-hit-strip')),
            matching: find.byType(Focus),
          )
          .first,
    );
    focus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(find.text('Question 0 more'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Question 2 more'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(tapped, 9);
  });

  testWidgets('narrow pane: no hit strip over the text', (tester) async {
    await pumpRail(tester, width: 770, messages: _chat(4));
    final IgnorePointer ignore = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('turn-rail-hit-strip')),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('strips of rows on screen are bright and follow the scroll', (
    tester,
  ) async {
    final ChatTurnRailController rail = ChatTurnRailController();
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<Map<String, String>> messages = _chat(20);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              ListView.builder(
                controller: controller,
                itemCount: messages.length,
                itemBuilder: (_, int i) {
                  final Widget row = SizedBox(
                    height: 300,
                    child: Text('row $i'),
                  );
                  return messages[i]['sender'] == 'user'
                      ? KeyedSubtree(key: rail.keyFor(i), child: row)
                      : row;
                },
              ),
              Positioned.fill(
                child: ChatTurnRail(
                  messages: messages,
                  rail: rail,
                  scrollController: controller,
                  onTickTap: (int i) => scrollToTurn(
                    rail,
                    index: i,
                    itemCount: messages.length,
                    controller: controller,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color colorOf(int row) {
      final AnimatedContainer box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: _strip(row),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return (box.decoration! as BoxDecoration).color!;
    }

    final Color brightTop = colorOf(0);
    expect(colorOf(30), isNot(brightTop));

    final Future<void> done = rail.scrollTo(
      index: 30,
      itemCount: messages.length,
      controller: controller,
    );
    await tester.pumpAndSettle();
    await done;
    await tester.pumpAndSettle();
    expect(find.text('row 30'), findsOneWidget);
    // The jump leaves 24 px above the row.
    expect(tester.getTopLeft(find.text('row 30')).dy, closeTo(24, 1));
    expect(colorOf(30), brightTop);
    expect(colorOf(0), isNot(brightTop));
  });
}
