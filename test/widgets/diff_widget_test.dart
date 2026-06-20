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
}
