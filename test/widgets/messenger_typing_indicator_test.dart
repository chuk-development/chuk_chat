import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';

void main() {
  Widget app({bool reduced = false}) => MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: const Align(
          alignment: Alignment.centerLeft,
          child: MessengerTypingIndicator(),
        ),
      ),
    ),
  );

  testWidgets('small three-dot pill animates independently of message text', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final pill = find.byKey(const ValueKey('messenger-typing-pill'));
    expect(tester.getSize(pill), const Size(60, 38));
    expect(tester.getTopLeft(pill).dx, 0);
    expect(find.text('…'), findsNothing);
    final dot = find.byKey(const ValueKey('messenger-typing-dot-0'));
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('messenger-typing-dot-$i')), findsOneWidget);
    }
    final before = tester.getTopLeft(dot);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(dot), isNot(before));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion keeps dots still with no running ticker', (
    tester,
  ) async {
    await tester.pumpWidget(app(reduced: true));
    await tester.pumpAndSettle();
    final dot = find.byKey(const ValueKey('messenger-typing-dot-0'));
    final before = tester.getTopLeft(dot);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(dot), before);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
