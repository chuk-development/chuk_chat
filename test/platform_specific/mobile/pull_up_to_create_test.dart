import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/mobile/pull_up_to_create.dart';

void main() {
  final Finder hint = find.byKey(
    const ValueKey<String>('pull_up_to_create_hint'),
  );

  Future<List<int>> pump(
    WidgetTester tester, {
    bool reverse = false,
    bool enabled = true,
    ScrollPhysics? physics,
  }) async {
    final List<int> created = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PullUpToCreate(
            enabled: enabled,
            label: 'New chat',
            onCreate: () => created.add(1),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ListView.builder(
                    reverse: reverse,
                    physics: physics,
                    itemCount: 40,
                    itemBuilder: (BuildContext context, int i) =>
                        SizedBox(height: 60, child: Text('row $i')),
                  ),
                ),
                const TextField(maxLines: 2),
              ],
            ),
          ),
        ),
      ),
    );
    return created;
  }

  /// Scrolls the list to its visual bottom.
  Future<void> toEnd(WidgetTester tester, {bool reverse = false}) async {
    if (reverse) return; // A reversed list starts at its bottom.
    final ScrollableState list = tester.state(find.byType(Scrollable).first);
    list.position.jumpTo(list.position.maxScrollExtent);
    await tester.pump();
  }

  for (final bool reverse in <bool>[false, true]) {
    testWidgets('a long pull up at the end creates on release '
        '(reverse: $reverse)', (WidgetTester tester) async {
      final List<int> created = await pump(tester, reverse: reverse);
      await toEnd(tester, reverse: reverse);
      expect(hint, findsNothing);

      final TestGesture finger = await tester.startGesture(
        const Offset(200, 300),
      );
      await finger.moveBy(const Offset(0, -30));
      await finger.moveBy(const Offset(0, -60));
      await tester.pump();
      // The hint shows and names what a release does; nothing ran yet.
      expect(hint, findsOneWidget);
      expect(find.text('New chat'), findsOneWidget);
      expect(created, isEmpty);

      await finger.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(created, isEmpty);
      await finger.up();
      await tester.pumpAndSettle();
      expect(created, hasLength(1));
      expect(hint, findsNothing);
    });
  }

  testWidgets('a short pull does nothing', (WidgetTester tester) async {
    final List<int> created = await pump(tester);
    await toEnd(tester);
    final TestGesture finger = await tester.startGesture(
      const Offset(200, 300),
    );
    await finger.moveBy(const Offset(0, -30));
    await finger.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(hint, findsOneWidget);
    await finger.up();
    await tester.pumpAndSettle();
    expect(created, isEmpty);
    expect(hint, findsNothing);
  });

  testWidgets('a pull in the middle of the chat only scrolls', (
    WidgetTester tester,
  ) async {
    final List<int> created = await pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(created, isEmpty);
    expect(hint, findsNothing);
  });

  testWidgets('a pull down at the top does nothing', (
    WidgetTester tester,
  ) async {
    final List<int> created = await pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(created, isEmpty);
  });

  testWidgets('bouncing physics: the pull past the end counts too', (
    WidgetTester tester,
  ) async {
    final List<int> created = await pump(
      tester,
      physics: const BouncingScrollPhysics(),
    );
    await toEnd(tester);
    final TestGesture finger = await tester.startGesture(
      const Offset(200, 300),
    );
    for (int i = 0; i < 12; i++) {
      await finger.moveBy(const Offset(0, -40));
    }
    await tester.pump();
    expect(hint, findsOneWidget);
    await finger.up();
    await tester.pumpAndSettle();
    expect(created, hasLength(1));
  });

  testWidgets('disabled, a pull does nothing', (WidgetTester tester) async {
    final List<int> created = await pump(tester, enabled: false);
    await toEnd(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(created, isEmpty);
    expect(hint, findsNothing);
  });
}
