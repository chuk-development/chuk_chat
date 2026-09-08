import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';

import 'mobile_support.dart';

void main() {
  testWidgets('every chip is at least a 48 dp touch target', (tester) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Chief of Staff', role: 'ops'),
        onBack: () {},
        onOpenProfile: () {},
        onOpenBrowser: () {},
        onMore: () {},
      ),
    );

    for (final id in <String>[
      'mobile_chat_back',
      'mobile_chat_browser',
      'mobile_chat_more',
      'mobile_chat_bot_pill',
    ]) {
      final finder = findId(id);
      expect(finder, findsOneWidget, reason: id);
      final Size size = tester.getSize(finder);
      expect(size.height, greaterThanOrEqualTo(MobileLayout.minTouchTarget),
          reason: '$id height');
      expect(size.width, greaterThanOrEqualTo(MobileLayout.minTouchTarget),
          reason: '$id width');
    }
  });

  testWidgets('chrome sits below the status bar and is barHeight tall',
      (tester) async {
    await pumpPhone(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: MobileChatChrome(
          agent: agent(id: 'a1', name: 'Chief of Staff'),
          onBack: () {},
        ),
      ),
    );
    final Rect back = tester.getRect(findId('mobile_chat_back'));
    // 47 status bar + 8 padding.
    expect(back.top, kPhonePadding.top + 8);
    expect(back.height, MobileLayout.chipDiameter);
    // The whole bar (without its fade) is what the chat reserves.
    expect(MobileLayout.barHeight, 8 + MobileLayout.chipDiameter + 6);
  });

  testWidgets('back, pill, browser and more fire their callbacks',
      (tester) async {
    int back = 0, profile = 0, browser = 0, more = 0;
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () => back++,
        onOpenProfile: () => profile++,
        onOpenBrowser: () => browser++,
        onMore: () => more++,
      ),
    );
    await tester.tap(findId('mobile_chat_back'));
    await tester.tap(findId('mobile_chat_bot_pill'));
    await tester.tap(findId('mobile_chat_browser'));
    await tester.tap(findId('mobile_chat_more'));
    await tester.pump();
    expect((back, profile, browser, more), (1, 1, 1, 1));
  });

  testWidgets('optional chips are hidden when their callback is null',
      (tester) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () {},
      ),
    );
    // The screen target keeps its place (it is the video-call slot) but is
    // parked while the coworker has none open; "more" is genuinely optional.
    expect(findId('mobile_chat_browser'), findsOneWidget);
    expect(find.byTooltip('No screen open right now'), findsOneWidget);
    expect(findId('mobile_chat_more'), findsNothing);
    expect(find.text('Chief of Staff'), findsOneWidget);
  });

  testWidgets('a long name ellipsises inside the pill, chips stay on screen',
      (tester) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(
          id: 'a1',
          name: 'An extraordinarily long coworker name that never ends',
        ),
        onBack: () {},
        onOpenBrowser: () {},
        onMore: () {},
      ),
    );
    final Rect more = tester.getRect(findId('mobile_chat_more'));
    expect(more.right, lessThanOrEqualTo(kPhoneSize.width - 10));
    final Rect pill = tester.getRect(findId('mobile_chat_bot_pill'));
    expect(pill.right, lessThan(more.left));
  });
}
