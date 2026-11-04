import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/chat_turn_rail.dart';

List<Map<String, String>> _chat(int turns) => <Map<String, String>>[
  for (int i = 0; i < turns; i++) ...<Map<String, String>>[
    <String, String>{'sender': 'user', 'text': '\nQuestion $i\nmore'},
    <String, String>{'sender': 'ai', 'text': 'Answer $i\n' * 20},
  ],
];

void main() {
  test('ticks: one per user row, first non-empty line', () {
    final List<ChatTurnRailTick> ticks = chatTurnRailTicks(_chat(3));
    expect(ticks.map((t) => t.index), <int>[0, 2, 4]);
    expect(ticks.first.label, 'Question 0');
    expect(firstLineOf('x' * 200).length, 80);
  });

  Future<void> pumpRail(
    WidgetTester tester, {
    required double width,
    required List<Map<String, String>> messages,
    ValueChanged<int>? onTap,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTurnRail(messages: messages, onTickTap: onTap ?? (_) {}),
        ),
      ),
    );
  }

  testWidgets('one tick per user message, tooltip is the first line', (
    tester,
  ) async {
    await pumpRail(tester, width: 1200, messages: _chat(4));
    expect(find.byType(Tooltip), findsNWidgets(4));
    final Tooltip tip = tester.widget<Tooltip>(find.byType(Tooltip).first);
    expect(tip.message, 'Question 0');
  });

  testWidgets('hidden under 900 px', (tester) async {
    await pumpRail(tester, width: 899, messages: _chat(4));
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('tap reports the row index', (tester) async {
    int? tapped;
    await pumpRail(
      tester,
      width: 1200,
      messages: _chat(4),
      onTap: (i) => tapped = i,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('turn-rail-tick-4')),
      warnIfMissed: false,
    );
    expect(tapped, 4);
  });

  testWidgets('controller scrolls a lazy list to an unbuilt row', (
    tester,
  ) async {
    final ChatTurnRailController rail = ChatTurnRailController();
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: 200,
            itemBuilder: (_, int i) => KeyedSubtree(
              key: rail.keyFor(i),
              child: SizedBox(height: 100, child: Text('row $i')),
            ),
          ),
        ),
      ),
    );
    expect(find.text('row 150'), findsNothing);
    final Future<void> done = rail.scrollTo(
      index: 150,
      itemCount: 200,
      controller: controller,
    );
    await tester.pumpAndSettle();
    await done;
    expect(find.text('row 150'), findsOneWidget);
  });
}
