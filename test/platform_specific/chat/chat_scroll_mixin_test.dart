import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';

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
  Future<_HarnessState> pumpHarness(
    WidgetTester tester, {
    int rows = 20,
  }) async {
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

  testWidgets('a reader at the end is carried along by a streaming answer', (
    tester,
  ) async {
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

  testWidgets('a small pull towards history is not undone by the next token', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();

    // 60px up: inside the old 100px "still sticky" band, which is exactly the
    // case that used to snap back on the next token.
    await tester.drag(find.byType(ListView), const Offset(0, 60));
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    expect(
      state.isStickyBottom,
      isFalse,
      reason: 'one pull towards history lets go of the bottom, at any distance',
    );
    final settled = position.pixels;
    expect(position.maxScrollExtent - settled, greaterThan(8));

    for (var i = 0; i < 5; i++) {
      state.streamOneMoreRow();
      await tester.pump();
      await tester.pump();
    }

    expect(
      position.pixels,
      settled,
      reason: 'the reader stays where they put the list',
    );
  });

  testWidgets('one wheel tick towards history also holds the list still', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();

    // A wheel tick is not a drag: it never opens a drag activity, so the
    // isScrollingNotifier guard alone does not see it.
    final Offset centre = tester.getCenter(find.byType(ListView));
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(centre);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
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
    expect(
      state.isStickyBottom,
      isTrue,
      reason: 'back at the end, new content should arrive in view again',
    );

    state.streamOneMoreRow();
    await tester.pump();
    await tester.pump();
    expect(position.pixels, moveTo(position.maxScrollExtent));
  });

  testWidgets(
    'the end of an answer settles at the bottom while it still grows',
    (tester) async {
      final state = await pumpHarness(tester);
      state.jumpToEnd();
      await tester.pumpAndSettle();

      // The last token has arrived; the layout has not finished. Code blocks and
      // images keep growing the extent for a few more frames.
      state.finishStream();
      for (int i = 0; i < 4; i++) {
        state.growWithoutPinning();
        await tester.pump();
      }
      await tester.pumpAndSettle();

      final position = state.scrollController.position;
      expect(
        position.pixels,
        moveTo(position.maxScrollExtent),
        reason: 'a reader who followed the answer should end at its end',
      );
    },
  );

  testWidgets('a reader who scrolled up is not dragged down at the end', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(state.isStickyBottom, isFalse);
    final double held = state.scrollController.position.pixels;

    state.finishStream();
    await tester.pumpAndSettle();

    expect(state.scrollController.position.pixels, moveTo(held));
  });
  testWidgets(
    'a reader at the end stays at the end when the composer or keyboard '
    'takes more room',
    (tester) async {
      final state = await pumpHarness(tester);
      state.jumpToEnd();
      await tester.pumpAndSettle();
      expect(state.isStickyBottom, isTrue);

      // More than the 100 px that used to read as "scrolled up".
      state.reserveBottom(220);
      await tester.pump();
      await tester.pump();

      final position = state.scrollController.position;
      expect(state.isStickyBottom, isTrue);
      expect(position.pixels, position.maxScrollExtent);
    },
  );

  testWidgets('a reader who scrolled up is not moved by a taller composer', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.jumpToEnd();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final double before = state.scrollController.position.pixels;
    expect(state.isStickyBottom, isFalse);

    state.reserveBottom(220);
    await tester.pump();
    await tester.pump();

    expect(state.scrollController.position.pixels, before);
  });

  testWidgets('a composer that grows a lot keeps the end in view', (
    tester,
  ) async {
    // An attached picture adds about 110 px, more than the 100 px that
    // scrollChatToBottom still calls "near the bottom". The last message
    // (its sources row) used to end up behind the composer.
    final state = await pumpHarness(tester);
    state.onComposerHeightChanged(const Size(300, 60));
    await tester.pumpAndSettle();
    state.jumpToEnd();
    await tester.pumpAndSettle();
    expect(state.isStickyBottom, isTrue);

    state.onComposerHeightChanged(const Size(300, 180));
    await tester.pump();
    await tester.pump();

    final position = state.scrollController.position;
    expect(position.pixels, moveTo(position.maxScrollExtent));
    expect(state.isStickyBottom, isTrue);
  });

  testWidgets('a growing composer leaves a reader up in the history alone', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.onComposerHeightChanged(const Size(300, 60));
    await tester.pumpAndSettle();
    state.scrollController.jumpTo(100);
    await tester.pumpAndSettle();
    expect(state.isStickyBottom, isFalse);

    state.onComposerHeightChanged(const Size(300, 180));
    await tester.pump();
    await tester.pump();

    expect(state.scrollController.position.pixels, 100);
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

  /// Room under the last row, as the chat screens reserve it for the
  /// composer. Grows when the keyboard opens or the composer gets taller.
  double bottomPadding = 0;

  void reserveBottom(double value) => setState(() => bottomPadding = value);

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

  /// More content without the streaming pin — what async-sized children do
  /// after the last token.
  void growWithoutPinning() {
    setState(() => rows += 1);
  }

  /// The end of the answer, as the chat screens handle it.
  void finishStream() {
    settleScrollToBottomIfSticky();
  }

  void jumpToEnd() {
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      // The same hook as the chat screens: a layout change is handled after
      // the frame, through the layout-change path.
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) onScrollMetricsChanged();
        });
        return false;
      },
      child: ListView.builder(
        controller: scrollController,
        // The room held for the composer, as the chat screens reserve it,
        // plus what the keyboard or a taller bar takes ([reserveBottom]).
        padding: EdgeInsets.only(bottom: composerHeight + bottomPadding),
        itemCount: rows,
        itemBuilder: (context, index) =>
            SizedBox(height: 50, child: Text('message $index')),
      ),
    );
  }
}
