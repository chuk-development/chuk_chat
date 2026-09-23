import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';

/// The bottom-anchored transcript (Agents).
///
/// A thread opens at its bottom without laying out the rows above the
/// viewport, and everything that happens after the open — new rows, a
/// streaming answer, a reader who scrolled up, the jump button — behaves like
/// the plain list did.
void main() {
  const double viewportHeight = 300;
  const double rowHeight = 100;
  const double bottomInset = 40;

  Future<_HarnessState> pumpHarness(
    WidgetTester tester, {
    int rows = 200,
    bool anchored = true,
    double height = rowHeight,
    int textLength = 10,
  }) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: _Harness(
                key: key,
                initialRows: rows,
                anchored: anchored,
                rowHeight: height,
                textLength: textLength,
                bottomInset: bottomInset,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  /// The bottom edge of a row relative to the viewport's top edge.
  double rowBottom(WidgetTester tester, int index) {
    final Rect viewport = tester.getRect(find.byType(Scrollable));
    return tester.getRect(find.text('message $index')).bottom - viewport.top;
  }

  testWidgets('a long thread opens at its bottom and builds only the tail', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.built.clear();
    state.open();
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    expect(position.pixels, moveTo(position.maxScrollExtent));
    expect(state.resolveTranscriptSplit(), 200);
    // The last row ends right above the reserved composer space.
    expect(rowBottom(tester, 199), moveTo(viewportHeight - bottomInset));
    // Nothing near the top of the thread was built to get there.
    expect(state.built, isNotEmpty);
    expect(state.built.reduce((a, b) => a < b ? a : b), greaterThan(185));
  });

  testWidgets('new rows go below the line and a reader at the end follows', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.open();
    await tester.pumpAndSettle();

    for (var i = 0; i < 5; i++) {
      state.appendRow(streaming: true);
      await tester.pump();
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    expect(state.isStickyBottom, isTrue);
    expect(position.pixels, moveTo(position.maxScrollExtent));
    expect(rowBottom(tester, 204), moveTo(viewportHeight - bottomInset));
    // The open split stays where it was: the new rows are below the line.
    expect(state.resolveTranscriptSplit(), 200);
  });

  testWidgets('a reader who scrolled up is not moved by new rows', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.open();
    await tester.pumpAndSettle();

    state.scrollController.jumpTo(state.scrollController.position.pixels - 450);
    await tester.pumpAndSettle();
    expect(state.isStickyBottom, isFalse);
    final double before = rowBottom(tester, 194);

    for (var i = 0; i < 4; i++) {
      state.appendRow(streaming: true);
      await tester.pump();
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(rowBottom(tester, 194), moveTo(before));
  });

  testWidgets('a cut history moves the rest of the rows below the line', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.open();
    await tester.pumpAndSettle();

    // An edit-and-resend at row 194: everything after it goes, a fresh
    // answer is appended and streams.
    state.truncateAndAppend(keep: 195);
    await tester.pumpAndSettle();

    expect(state.resolveTranscriptSplit(), 195);
    expect(find.text('message 195'), findsOneWidget);
  });

  testWidgets('a row that starts streaming leaves the history', (tester) async {
    final state = await pumpHarness(tester);
    state.open();
    await tester.pumpAndSettle();

    state.setStreaming(true);
    await tester.pumpAndSettle();
    expect(state.resolveTranscriptSplit(), 199);
  });

  testWidgets('a thread opened mid-stream keeps the streaming row below', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.streaming = true;
    state.open();
    await tester.pumpAndSettle();
    expect(state.resolveTranscriptSplit(), 199);
    final position = state.scrollController.position;
    expect(position.pixels, moveTo(position.maxScrollExtent));
  });

  testWidgets('a short thread stays top-aligned', (tester) async {
    final state = await pumpHarness(tester, rows: 2);
    state.open();
    await tester.pumpAndSettle();

    expect(state.resolveTranscriptSplit(), 0);
    expect(rowBottom(tester, 0), moveTo(10 + rowHeight));
  });

  testWidgets('a thread that only looked long falls back to the plain list', (
    tester,
  ) async {
    // Long text, tiny rows: the estimate says "long", the layout says it
    // fits. The next frame puts it back at the top.
    final state = await pumpHarness(
      tester,
      rows: 4,
      height: 20,
      textLength: 4000,
    );
    state.open();
    await tester.pumpAndSettle();

    expect(state.resolveTranscriptSplit(), 0);
    expect(rowBottom(tester, 0), moveTo(10 + 20));
  });

  testWidgets('the jump button from far up lands at the bottom directly', (
    tester,
  ) async {
    final state = await pumpHarness(tester);
    state.open();
    await tester.pumpAndSettle();

    // Scroll far up in steps, the way a reader would.
    for (var i = 0; i < 10; i++) {
      state.scrollController.jumpTo(
        state.scrollController.position.pixels - 600,
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final int epoch = state.transcriptEpoch;
    state.built.clear();

    state.scrollChatToBottom(force: true);
    await tester.pumpAndSettle();

    final position = state.scrollController.position;
    expect(position.pixels, moveTo(position.maxScrollExtent));
    expect(state.transcriptEpoch, epoch + 1);
    expect(rowBottom(tester, 199), moveTo(viewportHeight - bottomInset));
    // Only the tail was built, not the ~60 rows in between.
    expect(state.built.reduce((a, b) => a < b ? a : b), greaterThan(185));
  });

  testWidgets('flag off keeps the plain list', (tester) async {
    final state = await pumpHarness(tester, anchored: false);
    expect(find.byType(ListView), findsOneWidget);
    expect(state.resolveTranscriptSplit(), 0);
    state.open();
    await tester.pumpAndSettle();
    final position = state.scrollController.position;
    expect(position.minScrollExtent, 0);
    expect(position.pixels, moveTo(position.maxScrollExtent));
  });
}

Matcher moveTo(double target) => closeTo(target, 0.5);

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.initialRows,
    required this.anchored,
    required this.rowHeight,
    required this.textLength,
    required this.bottomInset,
  });

  final int initialRows;
  final bool anchored;
  final double rowHeight;
  final int textLength;
  final double bottomInset;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness> {
  late final List<Map<String, String>> rows = <Map<String, String>>[
    for (var i = 0; i < widget.initialRows; i++) _row(),
  ];
  bool streaming = false;
  final List<int> built = <int>[];

  Map<String, String> _row() => <String, String>{
    'sender': 'ai',
    'text': 'x' * widget.textLength,
  };

  @override
  bool get anchoredTranscript => widget.anchored;

  @override
  List<Map<String, String>> get transcriptRows => rows;

  @override
  bool get transcriptStreaming => streaming;

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

  /// What the chat screens do once a thread's rows are in place.
  void open() {
    setState(() {});
    scrollChatToBottom(force: true, animate: false);
  }

  void appendRow({bool streaming = false}) {
    setState(() {
      rows.add(_row());
      this.streaming = streaming;
    });
    pinToBottomDuringStream();
  }

  void setStreaming(bool value) => setState(() => streaming = value);

  void truncateAndAppend({required int keep}) {
    setState(() {
      rows.removeRange(keep, rows.length);
      rows.add(_row());
      streaming = true;
    });
  }

  Widget _item(BuildContext context, int index) {
    built.add(index);
    return SizedBox(height: widget.rowHeight, child: Text('message $index'));
  }

  @override
  Widget build(BuildContext context) {
    const EdgeInsets padding = EdgeInsets.fromLTRB(0, 10, 0, 0);
    final EdgeInsets withInset = padding.copyWith(bottom: widget.bottomInset);
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        onScrollChanged();
        return false;
      },
      child: widget.anchored
          ? Builder(
              builder: (context) {
                transcriptBottomInset = widget.bottomInset;
                return buildAnchoredTranscript(
                  split: resolveTranscriptSplit(),
                  itemCount: rows.length,
                  padding: withInset,
                  itemBuilder: _item,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(250),
                  addAutomaticKeepAlives: false,
                );
              },
            )
          : ListView.builder(
              controller: scrollController,
              padding: withInset,
              itemCount: rows.length,
              itemBuilder: _item,
            ),
    );
  }
}
