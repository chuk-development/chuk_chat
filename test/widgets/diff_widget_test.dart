import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/diff_widget.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );
  }

  testWidgets('shows added/removed counts in header', (tester) async {
    await pump(
      tester,
      const DiffWidget(
        before: 'name: Alice\ncity: Berlin',
        after: 'name: Alice\ncity: Hamburg',
        type: 'user_info',
      ),
    );

    // One line changed → +1 / -1.
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('-1'), findsOneWidget);
    expect(find.text('User Info'), findsOneWidget);
  });

  testWidgets('renders title when provided', (tester) async {
    await pump(
      tester,
      const DiffWidget(
        before: 'a',
        after: 'b',
        title: 'Memory updated',
        type: 'memory',
      ),
    );

    expect(find.text('Memory updated'), findsOneWidget);
  });

  testWidgets('folds long unchanged runs', (tester) async {
    final before = List.generate(20, (i) => 'line $i').join('\n');
    final after = before.replaceFirst('line 10', 'line 10 CHANGED');

    await pump(tester, DiffWidget(before: before, after: after));

    // Context is folded around the single change → fold markers present.
    expect(find.textContaining('unchanged line'), findsWidgets);
  });

  testWidgets('shows unchanged label when identical', (tester) async {
    await pump(
      tester,
      const DiffWidget(before: 'same', after: 'same'),
    );

    expect(find.text('unchanged'), findsOneWidget);
  });

  test('small diff runs the LCS (not coarse)', () {
    final stats = DiffWidget.debugDiffStats('a\nb\nc', 'a\nB\nc');
    expect(stats.coarse, isFalse);
    expect(stats.added, 1);
    expect(stats.removed, 1);
  });

  test('common head/tail is trimmed before the cap is checked', () {
    final body = List.generate(5000, (i) => 'line $i').join('\n');
    final stats = DiffWidget.debugDiffStats(body, '$body\nnew tail');
    expect(stats.coarse, isFalse);
    expect(stats.added, 1);
    expect(stats.removed, 0);
  });

  test(
    'more than kDiffMaxChangedLines changed lines takes the coarse path',
    () {
      final before = List.generate(200, (i) => 'old $i').join('\n');
      final after = List.generate(200, (i) => 'new $i').join('\n');
      final stats = DiffWidget.debugDiffStats(before, after);
      expect(stats.coarse, isTrue);
      expect(stats.removed, 200);
      expect(stats.added, 200);
    },
  );

  testWidgets('huge diff builds quickly, coarse and truncated', (tester) async {
    final before = List.generate(20000, (i) => 'old line $i').join('\n');
    final after = List.generate(20000, (i) => 'new line $i').join('\n');

    final sw = Stopwatch()..start();
    await pump(tester, DiffWidget(before: before, after: after));
    // Rebuilding with the same input must not recompute the diff.
    await pump(tester, DiffWidget(before: before, after: after));
    sw.stop();

    // A full LCS here would be 400M cells (and minutes); the cap keeps it
    // well under a few seconds even on a slow CI box.
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    expect(find.text('+20000'), findsOneWidget);
    expect(find.text('-20000'), findsOneWidget);
    expect(
      find.text('Large change, shown without line matching'),
      findsOneWidget,
    );
    expect(find.textContaining('more removed lines'), findsOneWidget);
    expect(find.textContaining('more added lines'), findsOneWidget);
  });
}
