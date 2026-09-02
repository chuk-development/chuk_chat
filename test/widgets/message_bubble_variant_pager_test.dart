import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // MessageBubble.initState awaits SharedPreferences.getInstance() with no
    // error handling — mock it so these tests don't hit MissingPluginException.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Widget host({
    required int variantIndex,
    required int variantCount,
    VoidCallback? onPrev,
    VoidCallback? onNext,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          message: 'an answer',
          isUser: false,
          variantIndex: variantIndex,
          variantCount: variantCount,
          onPrevVariant: onPrev,
          onNextVariant: onNext,
        ),
      ),
    );
  }

  testWidgets('no pager when there is a single variant', (tester) async {
    await tester.pumpWidget(host(variantIndex: 0, variantCount: 1));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('renders ‹ k/n › and both arrows in the middle', (tester) async {
    await tester.pumpWidget(host(
      variantIndex: 1,
      variantCount: 3,
      onPrev: () {},
      onNext: () {},
    ));
    await tester.pump();

    expect(find.text('2/3'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('prev disabled at first, next disabled at last', (tester) async {
    // At the first variant, prev is disabled, next is enabled.
    var prevTaps = 0;
    var nextTaps = 0;
    await tester.pumpWidget(host(
      variantIndex: 0,
      variantCount: 2,
      onPrev: () => prevTaps++,
      onNext: () => nextTaps++,
    ));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(prevTaps, 0, reason: 'prev disabled at first variant');
    expect(nextTaps, 1);

    // At the last variant, next is disabled, prev is enabled.
    await tester.pumpWidget(host(
      variantIndex: 1,
      variantCount: 2,
      onPrev: () => prevTaps++,
      onNext: () => nextTaps++,
    ));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(prevTaps, 1);
    expect(nextTaps, 1, reason: 'next disabled at last variant');
  });
}
