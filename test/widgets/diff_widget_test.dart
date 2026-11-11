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
    // The card stops after kDiffCollapsedRows rows; "Show all" opens it.
    await tester.tap(find.byKey(const ValueKey<String>('diff-show-all')));
    await tester.pump();
    expect(find.textContaining('more removed lines'), findsOneWidget);
    expect(find.textContaining('more added lines'), findsOneWidget);
  });

  testWidgets('a card over 9 rows folds behind Show all', (tester) async {
    final before = List.generate(30, (i) => 'line $i').join('\n');
    final after = List.generate(30, (i) => i.isEven ? 'line $i' : 'LINE $i')
        .join('\n');
    await pump(tester, DiffWidget(before: before, after: after));

    expect(find.byKey(const ValueKey<String>('diff-show-all')), findsOneWidget);
    expect(find.textContaining('Show all'), findsOneWidget);
    expect(find.textContaining('LINE 29'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('diff-show-all')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('diff-show-all')), findsNothing);
    expect(find.textContaining('LINE 29', findRichText: true), findsOneWidget);
  });

  testWidgets('a small card has no Show all row', (tester) async {
    await pump(tester, const DiffWidget(before: 'a\nb', after: 'a\nc'));
    expect(find.byKey(const ValueKey<String>('diff-show-all')), findsNothing);
  });

  test('diffChangeCountInResult sums every diff block', () {
    const String result =
        'Saved.\n<diff>{"before":"a\\nb","after":"a\\nc\\nd"}</diff>';
    final counts = diffChangeCountInResult(result);
    expect(counts, isNotNull);
    expect(counts!.added, 2);
    expect(counts.removed, 1);
    expect(diffChangeCountInResult('no diff here'), isNull);
    expect(diffChangeCountInResult(null), isNull);
  });
}
