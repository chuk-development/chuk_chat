import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/chat/chat_scroll_mixin.dart';

/// Auto-scroll during streaming.
///
/// The message list is not reversed, so a streaming answer grows the scroll
/// extent on every frame. The question each test asks is who wins when the
/// reader and the growing message disagree: the reader always does, and a
/// reader who is already at the end still gets carried along.
void main() {
  const double viewportHeight = 300;

  /// A minimal stand-in for the chat screen: the same mixin, the same
  /// non-reversed [ListView], the same two hooks (`onScrollChanged` from the
  /// controller and from layout-metric changes, `pinToBottomDuringStream` on
  /// each new token). `rows` grows the way a streaming answer does.
  Future<_HarnessState> pumpHarness(WidgetTester tester, {int rows = 20}) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: _Harness(key: key, initialRows: rows),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets('a reader at the end is carried along by a streaming answer',
      (tester) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    expect(state.isStickyBottom, isTrue);
    expect(position.pixels, position.maxScrollExtent);

    for (var i = 0; i < 5; i++) {
      state.streamOneMoreRow();
      await tester.pump();
      await tester.pump();
    }

    expect(state.isStickyBottom, isTrue);
    expect(position.pixels, moveTo(position.maxScrollExtent));
  });

  testWidgets('a small pull towards history is not undone by the next token',
      (tester) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();

    // 60px up: inside the old 100px "still sticky" band, which is exactly the
    // case that used to snap back on the next token.
    await tester.drag(find.byType(ListView), const Offset(0, 60));
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    expect(state.isStickyBottom, isFalse,
        reason: 'one pull towards history lets go of the bottom, at any distance');
    final settled = position.pixels;
    expect(position.maxScrollExtent - settled, greaterThan(8));

    for (var i = 0; i < 5; i++) {
      state.streamOneMoreRow();
      await tester.pump();
      await tester.pump();
    }

    expect(position.pixels, settled,
        reason: 'the reader stays where they put the list');
  });

  testWidgets('one wheel tick towards history also holds the list still',
      (tester) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();

    // A wheel tick is not a drag: it never opens a drag activity, so the
    // isScrollingNotifier guard alone does not see it.
    final Offset centre = tester.getCenter(find.byType(ListView));
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(centre);
    await tester.sendEventToBinding(
      pointer.scroll(const Offset(0, -40)),
    );
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    final settled = position.pixels;
    expect(state.isStickyBottom, isFalse);
    expect(position.maxScrollExtent - settled, greaterThan(8));

    for (var i = 0; i < 5; i++) {
      state.streamOneMoreRow();
      await tester.pump();
      await tester.pump();
    }

    expect(position.pixels, settled);
  });

  testWidgets('scrolling back to the end pins the list again', (tester) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(state.isStickyBottom, isFalse);

    // All the way back down, the way a fling to the end ends.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    expect(position.pixels, position.maxScrollExtent);
    expect(state.isStickyBottom, isTrue,
        reason: 'back at the end, new content should arrive in view again');

    state.streamOneMoreRow();
    await tester.pump();
    await tester.pump();
    expect(position.pixels, moveTo(position.maxScrollExtent));
  });
}

/// `pixels` lands on the extent within a sub-pixel of it.
Matcher moveTo(double target) => closeTo(target, 0.5);

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.initialRows});

  final int initialRows;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness> {
  late int rows = widget.initialRows;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(onScrollChanged);
  }

  @override
  void dispose() {
    scrollController.removeListener(onScrollChanged);
    scrollController.dispose();
    super.dispose();
  }

  /// One more token's worth of content, then the same pin the chat screens do.
  void streamOneMoreRow() {
    setState(() => rows += 1);
    pinToBottomDuringStream();
  }

  void jumpToEnd() {
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        onScrollChanged();
        return false;
      },
      child: ListView.builder(
        controller: scrollController,
        itemCount: rows,
        itemBuilder: (context, index) =>
            SizedBox(height: 50, child: Text('message $index')),
      ),
    );
  }
}
