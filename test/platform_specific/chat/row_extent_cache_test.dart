// The chat list's length must not change while the reader scrolls: the
// scrollbar thumb is drawn from it. Flutter's default guess (average of the
// rows laid out right now) moves on every scroll; the measured-height cache
// keeps it put once a row has been seen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/row_extent_cache.dart';

/// Rows of very different heights, as in a chat: short questions, long
/// answers, a code block now and then.
double _height(int i) => switch (i % 7) {
  0 => 48,
  1 => 640,
  2 => 90,
  3 => 1200,
  4 => 60,
  5 => 300,
  _ => 150,
};

const int _rows = 120;

Future<List<double>> _extentsWhileScrolling(
  WidgetTester tester, {
  required bool cached,
  int passes = 2,
}) async {
  final RowExtentCache cache = RowExtentCache();
  final ScrollController controller = ScrollController();
  addTearDown(controller.dispose);
  Widget row(BuildContext context, int i) => RowExtentReporter(
    cache: cache,
    rowKey: 'row-$i',
    child: SizedBox(height: _height(i)),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ListView.custom(
        controller: controller,
        childrenDelegate: cached
            ? CachedExtentChildDelegate(
                row,
                childCount: _rows,
                extentOf: (int i) => cache['row-$i'] ?? 200,
              )
            : SliverChildBuilderDelegate(row, childCount: _rows),
      ),
    ),
  );
  final List<double> extents = <double>[];
  for (int pass = 0; pass < passes; pass++) {
    controller.jumpTo(0);
    await tester.pump();
    while (controller.position.pixels < controller.position.maxScrollExtent) {
      controller.jumpTo(controller.position.pixels + 250);
      await tester.pump();
      if (pass == passes - 1) extents.add(controller.position.maxScrollExtent);
    }
  }
  return extents;
}

void main() {
  test('a new width drops the old heights', () {
    final RowExtentCache cache = RowExtentCache()..record('a', 700, 100);
    expect(cache['a'], 100);
    cache.record('b', 700, 50);
    expect(cache.length, 2);
    cache.record('c', 900, 80);
    expect(cache['a'], isNull);
    expect(cache['c'], 80);
  });

  test('an estimate grows with the text and a tool block', () {
    final double short = estimateChatRowExtent(<String, String>{
      'sender': 'ai',
      'text': 'ok',
    });
    final double long = estimateChatRowExtent(<String, String>{
      'sender': 'ai',
      'text': 'x' * 2000,
    });
    final double tools = estimateChatRowExtent(<String, String>{
      'sender': 'ai',
      'text': 'ok',
      'toolCalls': '[{"id":"a"}]',
    });
    expect(long, greaterThan(short));
    expect(tools, greaterThan(short));
  });

  testWidgets('with the cache, the list length stays put once every row was '
      'seen', (tester) async {
    final List<double> extents = await _extentsWhileScrolling(
      tester,
      cached: true,
    );
    expect(extents, isNotEmpty);
    expect(extents.toSet(), hasLength(1), reason: '$extents');
  });

  testWidgets('without it, the length moves while scrolling (the bug)', (
    tester,
  ) async {
    final List<double> extents = await _extentsWhileScrolling(
      tester,
      cached: false,
    );
    expect(extents.toSet().length, greaterThan(1));
  });
}
