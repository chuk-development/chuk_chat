import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';

import 'mobile_support.dart';

void main() {
  testWidgets('hands the body the chrome inset: status bar + bar height', (
    tester,
  ) async {
    double? seen;
    await pumpPhone(
      tester,
      MobileChatScreen(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () {},
        bodyBuilder: (context, topInset) {
          seen = topInset;
          return const SizedBox.expand();
        },
      ),
    );
    expect(seen, kPhonePadding.top + MobileLayout.barHeight);
  });

  testWidgets('the body fills the page and the chrome floats over it', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MobileChatScreen(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () {},
        bodyBuilder: (context, topInset) =>
            const SizedBox.expand(key: Key('body')),
      ),
    );
    final Rect body = tester.getRect(find.byKey(const Key('body')));
    expect(body.top, 0);
    expect(body.height, kPhoneSize.height);
    // The back chip is on top of the body, not above it.
    final Rect back = tester.getRect(findId('mobile_chat_back'));
    expect(back.top, greaterThan(body.top));
  });

  testWidgets('a system back turns into onBack (PopScope)', (tester) async {
    int back = 0;
    await pumpPhone(
      tester,
      MobileChatScreen(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () => back++,
        bodyBuilder: (context, topInset) => const SizedBox.expand(),
      ),
    );
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    final bool popped = await navigator.maybePop();
    await tester.pump();
    // "Handled": the PopScope swallowed the pop and forwarded it.
    expect(popped, isTrue);
    expect(back, 1);
    expect(
      find.byType(MobileChatScreen),
      findsOneWidget,
      reason: 'still there',
    );
  });

  testWidgets(
    'a swipe from the left edge goes back; a swipe from the middle does not',
    (tester) async {
      int back = 0;
      await pumpPhone(
        tester,
        MobileChatScreen(
          agent: agent(id: 'a1', name: 'Chief of Staff'),
          onBack: () => back++,
          bodyBuilder: (context, topInset) => const SizedBox.expand(),
        ),
      );
      await tester.pumpAndSettle();
      // Middle of the screen: a horizontal fling in a table must not pop.
      await tester.flingFrom(
        const Offset(195, 400),
        const Offset(240, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(back, 0);

      // From the left edge.
      await tester.flingFrom(const Offset(8, 400), const Offset(240, 0), 1500);
      await tester.pumpAndSettle();
      expect(back, 1);

      // From the edge but slowly: a drag, not a swipe.
      await tester.dragFrom(const Offset(8, 400), const Offset(240, 0));
      await tester.pumpAndSettle();
      expect(back, 1);
    },
  );

  testWidgets('entrance animates then settles and respects reduced motion', (
    tester,
  ) async {
    Widget screen({bool reduced = false}) => MediaQuery(
      data: MediaQueryData(size: kPhoneSize, disableAnimations: reduced),
      child: MobileChatScreen(
        agent: agent(id: 'a1', name: 'Alex'),
        onBack: () {},
        bodyBuilder: (_, inset) =>
            const SizedBox.expand(key: Key('animated-body')),
      ),
    );
    await pumpPhone(tester, screen());
    expect(
      tester.getTopLeft(find.byKey(const Key('animated-body'))).dx,
      greaterThan(0),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const Key('animated-body'))).dx, 0);
    await pumpPhone(tester, screen(reduced: true));
    expect(tester.getTopLeft(find.byKey(const Key('animated-body'))).dx, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
