import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/agent_status.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import '../../support/fake_relay_controller.dart';

import 'mobile_support.dart';

void main() {
  testWidgets("the header floats on chuk's page-colour fade", (tester) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Alex'),
        onBack: () {},
      ),
    );
    final chrome = find.byType(MobileChatChrome);
    final Finder fade = find
        .descendant(
          of: chrome,
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).gradient != null,
          ),
        )
        .first;
    final decoration = tester.widget<DecoratedBox>(fade).decoration
        as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    final Color page = Theme.of(tester.element(chrome)).scaffoldBackgroundColor;

    // chuk's phone top bar, stop for stop: the page colour behind the status
    // bar and the chips, nothing at all by the lower edge.
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors, <Color>[page, page, page.withValues(alpha: 0)]);
    expect(gradient.stops, <double>[0.0, 0.62, 1.0]);

    // And it covers what it has to: behind the status bar at the top, past
    // the bottom of the row at the other end.
    final Rect painted = tester.getRect(fade);
    final Rect back = tester.getRect(findId('mobile_chat_back'));
    expect(painted.top, 0, reason: 'the fade paints behind the status bar');
    expect(
      painted.bottom,
      greaterThan(back.bottom),
      reason: 'it keeps fading below the row',
    );
  });

  testWidgets('offline header reconnect does not open the profile', (
    tester,
  ) async {
    var reconnects = 0;
    var profiles = 0;
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Alex'),
        onBack: () {},
        onOpenProfile: () => profiles++,
        onReconnect: () => reconnects++,
      ),
    );
    await tester.tap(find.text('Offline · Reconnect'));
    await tester.pump();
    expect(reconnects, 1);
    expect(profiles, 0);
  });
  tearDown(() => AgentsRelayLink.instance.reset());

  testWidgets(
    'files and screen remain real48px actions at320px with large text',
    (tester) async {
      int files = 0, screen = 0;
      await pumpPhone(
        tester,
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: MobileChatChrome(
                agent: agent(id: 'alex', name: 'A long coworker name'),
                onBack: () {},
                onOpenProfile: () {},
                onOpenFiles: () => files++,
                onOpenBrowser: () => screen++,
              ),
            ),
          ),
        ),
      );
      for (final id in ['mobile_chat_files', 'mobile_chat_browser']) {
        expect(tester.getSize(findId(id)).width, greaterThanOrEqualTo(48));
        expect(tester.getRect(findId(id)).right, lessThanOrEqualTo(320));
        await tester.tap(findId(id));
      }
      await tester.pumpAndSettle();
      expect((files, screen), (1, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets("the contact pill is chuk's title pill", (tester) async {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: Brightness.dark,
      ),
    );
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Alex'),
        onBack: () {},
      ),
      theme: theme,
    );
    final surface = tester.widget<FloatingChromeSurface>(
      find.byKey(const ValueKey('mobile_contact_surface')),
    );
    // chuk's pill: the chrome surface at radius 18, no outline of its own.
    expect(surface.radius, kMobileChromePillRadius);
    expect(surface.radius, 18);
    expect(surface.shape, isNull);
    // chuk's title type: 15, heavy.
    final Text name = tester.widget<Text>(find.text('Alex'));
    expect(name.style!.fontSize, 15);
    expect(name.style!.fontWeight, FontWeight.w800);
  });

  testWidgets('presence follows the real relay, not roster registration', (
    tester,
  ) async {
    final controller = FakeRelayController();
    AgentsRelayLink.instance.bind(controller);
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Alex', onHost: true),
        onBack: () {},
      ),
    );
    expect(find.text('Offline'), findsOneWidget);
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
    await tester.pump();
    final active = tester.widget<Text>(find.text('Active now'));
    expect(
      active.style!.color,
      Theme.of(tester.element(find.text('Active now'))).colorScheme.primary,
    );
    AgentsRelayLink.instance.unbind();
    await tester.pump();
    expect(find.text('Offline'), findsOneWidget);
    await controller.dispose();
  });
  testWidgets('the presence dot rides the status line, not the face', (
    tester,
  ) async {
    for (final double scale in <double>[1.0, 1.15, 1.3]) {
      final controller = FakeRelayController();
      controller.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
      AgentsRelayLink.instance.bind(controller);
      await pumpPhone(
        tester,
        MediaQuery(
          data: MediaQueryData(
            size: kPhoneSize,
            padding: kPhonePadding,
            textScaler: TextScaler.linear(scale),
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: MobileChatChrome(
              agent: agent(id: 'a1', name: 'Wahlradar', onHost: true),
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final Rect dot = tester.getRect(find.byType(StatusDot));
      final Finder words = find.text('Active now');
      // The baseline of the line as it is really painted. (A RenderBox only
      // answers a baseline query during layout, so the same span is measured
      // again here, with the paragraph's own resolved style and scaler.)
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        words,
      );
      final TextPainter painter = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout();
      final double baseline =
          tester.getTopLeft(words).dy +
          painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);

      // The dot is the x-height of the words next to it, and its bottom rides
      // their baseline — so its centre is the middle of the lower-case
      // letters. Both halves scale with the text, so nothing drifts.
      expect(
        dot.height,
        closeTo(11 * scale * kStatusDotSizeFactor, 0.01),
        reason: 'dot diameter at $scale',
      );
      expect(dot.width, closeTo(dot.height, 0.001));
      expect(
        dot.bottom,
        closeTo(baseline, 0.5),
        reason: 'dot bottom on the baseline at $scale',
      );
      // One even gap, and the dot leads the line.
      expect(
        tester.getTopLeft(words).dx - dot.right,
        closeTo(kStatusDotGap, 0.01),
        reason: 'gap at $scale',
      );
      // It is part of the line, not a badge on the face.
      final Rect face = tester.getRect(find.byType(AgentFace));
      expect(dot.left, greaterThan(face.right));

      AgentsRelayLink.instance.unbind();
      await controller.dispose();
    }
  });

  testWidgets('the face sits inside the pill with even air', (tester) async {
    await pumpPhone(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: MobileChatChrome(
          agent: agent(id: 'a1', name: 'Wahlradar'),
          onBack: () {},
        ),
      ),
    );
    final Rect face = tester.getRect(find.byType(AgentFace));
    final Rect pill = tester.getRect(
      find.byKey(const ValueKey('mobile_contact_surface')),
    );
    expect(face.height, 30);
    expect(face.width, face.height, reason: 'the silhouette is never squashed');
    expect(
      face.top - pill.top,
      closeTo(pill.bottom - face.bottom, 0.01),
      reason: 'even air above and below',
    );
    // The pill stands as tall as chuk's chips beside it, give or take the
    // rounding of two text lines.
    expect(pill.height, closeTo(kMobileChromeChip, 2));
  });

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
      expect(
        size.height,
        greaterThanOrEqualTo(MobileLayout.minTouchTarget),
        reason: '$id height',
      );
      expect(
        size.width,
        greaterThanOrEqualTo(MobileLayout.minTouchTarget),
        reason: '$id width',
      );
    }
  });

  testWidgets("the bar sits where chuk's does: 8 under the status bar, a "
      '48 px row, 6 under it', (tester) async {
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
    // The press is 48 px, the row's height.
    expect(back.top, closeTo(kPhonePadding.top + 8, 0.01));
    expect(back.height, MobileLayout.minTouchTarget);
    // The chip paints chuk's 42, centred in it, 10 in from the edge.
    final Rect chip = tester.getRect(
      find.descendant(
        of: findId('mobile_chat_back'),
        matching: find.byType(Ink),
      ),
    );
    expect(chip.size, const Size(kMobileChromeChip, kMobileChromeChip));
    expect(chip.left, closeTo(10, 0.01));
    expect(chip.center.dy, closeTo(back.center.dy, 0.01));
    expect(
      tester.getSize(find.byType(MobileChatChrome)).height,
      closeTo(kPhonePadding.top + 8 + 48 + 6, 0.01),
    );
  });

  testWidgets('back, pill, browser and more fire their callbacks', (
    tester,
  ) async {
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

  testWidgets('screen remains visible and disabled when its callback is null', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () {},
      ),
    );
    expect(findId('mobile_chat_browser'), findsOneWidget);
    final semantics = tester.widget<Semantics>(findId('mobile_chat_browser'));
    expect(semantics.properties.enabled, isFalse);
    await tester.tap(findId('mobile_chat_browser'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(findId('mobile_chat_call'), findsNothing);
    expect(findId('mobile_chat_more'), findsNothing);
    expect(find.text('Chief of Staff'), findsOneWidget);
  });

  testWidgets('a parked screen target still answers a tap', (tester) async {
    // Bead cowork-egrg: the target used to be rendered with a null callback
    // while the coworker had no screen, so a tap did nothing at all and the
    // user read the button as broken. It is parked now: visibly not ready,
    // and it still calls back so the caller can say why.
    int taps = 0;
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () {},
        onOpenBrowser: () => taps++,
      ),
    );
    expect(
      find.descendant(
        of: findId('mobile_chat_browser'),
        matching: find.byTooltip('No screen open yet'),
      ),
      findsOneWidget,
    );
    // Still enabled for screen readers: a tap explains why there is no
    // screen, and the tooltip carries the parked state.
    final semantics = tester.widget<Semantics>(findId('mobile_chat_browser'));
    expect(semantics.properties.enabled, isTrue);
    await tester.tap(findId('mobile_chat_browser'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('an available screen target reads as ready', (tester) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Chief of Staff'),
        onBack: () {},
        onOpenBrowser: () {},
        browserAvailable: true,
      ),
    );
    expect(
      find.descendant(
        of: findId('mobile_chat_browser'),
        matching: find.byTooltip('Take over the screen'),
      ),
      findsOneWidget,
    );
    final semantics = tester.widget<Semantics>(findId('mobile_chat_browser'));
    expect(semantics.properties.enabled, isTrue);
    // Lit is chuk's accent chip: the primary fill.
    final Ink ink = tester.widget<Ink>(
      find.descendant(
        of: findId('mobile_chat_browser'),
        matching: find.byType(Ink),
      ),
    );
    expect(
      (ink.decoration! as BoxDecoration).color,
      Theme.of(tester.element(findId('mobile_chat_browser'))).colorScheme.primary,
    );
  });

  testWidgets('a long name ellipsises inside the pill, chips stay on screen', (
    tester,
  ) async {
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
    // The 48 px press reaches 3 past chuk's 10 px edge.
    expect(more.right, lessThanOrEqualTo(kPhoneSize.width - 7));
    final Rect pill = tester.getRect(findId('mobile_chat_bot_pill'));
    expect(pill.right, lessThan(more.left));
  });

  testWidgets(
    "the pill hugs its content at the left, as chuk's title does",
    (tester) async {
      await pumpPhone(
        tester,
        MobileChatChrome(
          agent: agent(id: 'a1', name: 'Alex'),
          onBack: () {},
          onOpenProfile: () {},
        ),
      );
      final Rect pill = tester.getRect(
        find.byKey(const ValueKey('mobile_contact_surface')),
      );
      final Rect screen = tester.getRect(findId('mobile_chat_browser'));
      // chuk's gaps: 10 to the first chip, 8 between everything.
      expect(pill.left, closeTo(10 + kMobileChromeChip + 8, 0.01));
      expect(screen.right, closeTo(kPhoneSize.width - 7, 0.01));
      // A short name leaves the rest of the row empty.
      expect(pill.right, lessThan(screen.left - 40));
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Active now'), findsNothing);
    },
  );

  testWidgets(
    'large text grows the chrome and reduced motion keeps dots static',
    (tester) async {
      final controller = FakeRelayController();
      controller.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
      AgentsRelayLink.instance.bind(controller);
      await pumpPhone(
        tester,
        MediaQuery(
          data: const MediaQueryData(
            size: kPhoneSize,
            padding: kPhonePadding,
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: MobileChatChrome(
              agent: agent(
                id: 'a1',
                name: 'A very long coworker name',
                running: true,
              ),
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('…'), findsOneWidget);
      expect(
        tester.getSize(findId('mobile_chat_bot_pill')).height,
        greaterThan(50),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
}
