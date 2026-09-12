import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/agent_status.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/top_veil.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import '../../support/fake_relay_controller.dart';

import 'mobile_support.dart';

void main() {
  testWidgets('the header floats on a veil that ends transparent', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Alex'),
        onBack: () {},
      ),
    );
    final chrome = find.byType(MobileChatChrome);
    final veil = find
        .descendant(of: chrome, matching: find.byType(TopVeil))
        .first;
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(of: veil, matching: find.byType(DecoratedBox))
                      .first,
                )
                .decoration
            as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    final scheme = Theme.of(tester.element(chrome)).colorScheme;

    // No band across the width any more: the veil is heaviest behind the
    // status bar and reaches nothing below the row, so a message scrolls out
    // under it instead of stopping at an edge.
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.first, scheme.surface.withValues(alpha: 0.78));
    expect(gradient.colors.last.a, 0, reason: 'the veil ends transparent');
    expect(gradient.stops!.first, 0);
    expect(gradient.stops!.last, 1);
    for (int i = 1; i < gradient.colors.length; i++) {
      expect(
        gradient.colors[i].a,
        lessThan(gradient.colors[i - 1].a),
        reason: 'the veil only ever thins out, step $i',
      );
      expect(
        gradient.stops![i],
        greaterThan(gradient.stops![i - 1]),
        reason: 'stops rise, step $i',
      );
      expect(
        gradient.colors[i].withValues(alpha: 1),
        scheme.surface,
        reason: 'every stop is the surface colour, step $i',
      );
    }

    // And it really covers what it has to: behind the status bar at the top,
    // past the bottom of the row at the other end.
    final Rect painted = tester.getRect(veil);
    final Rect back = tester.getRect(findId('mobile_chat_back'));
    expect(painted.top, 0, reason: 'the veil paints behind the status bar');
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
  tearDown(() => CoworkRelayLink.instance.reset());

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

  testWidgets('contact surface paints the reference outline and translucency', (
    tester,
  ) async {
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
    final surface = tester.widget<Container>(
      find.byKey(const ValueKey('mobile_contact_surface')),
    );
    final decoration = surface.decoration! as BoxDecoration;
    // Translucent, so the messages travelling under the header stay visible
    // through the pill instead of hitting an opaque block.
    expect(decoration.color, theme.colorScheme.surface.withValues(alpha: 0.72));
    expect(decoration.color!.a, lessThan(1));
    expect(decoration.borderRadius, BorderRadius.circular(30));
    // The outline is what separates the pill from whatever scrolls behind it,
    // since the fill alone no longer does.
    expect(
      decoration.border,
      Border.all(color: theme.colorScheme.outlineVariant, width: 1.2),
    );
  });

  testWidgets('presence follows the real relay, not roster registration', (
    tester,
  ) async {
    final controller = FakeRelayController();
    CoworkRelayLink.instance.bind(controller);
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Alex', onHost: true),
        onBack: () {},
      ),
    );
    expect(find.text('Offline'), findsOneWidget);
    controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
    await tester.pump();
    final active = tester.widget<Text>(find.text('Active now'));
    expect(
      active.style!.color,
      Theme.of(tester.element(find.text('Active now'))).colorScheme.primary,
    );
    CoworkRelayLink.instance.unbind();
    await tester.pump();
    expect(find.text('Offline'), findsOneWidget);
    await controller.dispose();
  });
  testWidgets('the presence dot rides the status line, not the face', (
    tester,
  ) async {
    for (final double scale in <double>[1.0, 1.15, 1.3]) {
      final controller = FakeRelayController();
      controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
      CoworkRelayLink.instance.bind(controller);
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
      expect(dot.width, dot.height);
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

      CoworkRelayLink.instance.unbind();
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
    expect(face.height, 32, reason: 'the app small-face size');
    expect(face.width, face.height, reason: 'the silhouette is never squashed');
    // The two text lines, not the picture, are what the pill is built around:
    // the face is smaller than the text column and floats in the capsule.
    expect(face.height, lessThan(16 * 1.5 + 11 * 1.45));
    expect(
      face.top - pill.top,
      closeTo(pill.bottom - face.bottom, 0.01),
      reason: 'even air above and below',
    );
    // The pill is exactly as tall as the buttons beside it — it used to stand
    // 6 taller and overhang them.
    expect(pill.height, closeTo(MobileLayout.controlHeight, 0.01));
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

  testWidgets('chrome sits below the status bar and is barHeight tall', (
    tester,
  ) async {
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
    // 47 status bar + 8 padding. Nothing to centre any more: every control in
    // the row is [MobileLayout.controlHeight] tall, so they all start there.
    expect(back.top, closeTo(kPhonePadding.top + 8, 0.01));
    expect(back.height, MobileLayout.controlHeight);
    // The whole bar (without its fade) is what the chat reserves.
    expect(MobileLayout.barHeight, 8 + MobileLayout.controlHeight + 10);
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
    final screen = tester.widget<ExpressiveIconButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ExpressiveIconButton &&
            widget.semanticsId == 'mobile_chat_browser',
      ),
    );
    expect(screen.onTap, isNull);
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
    final screen = tester.widget<ExpressiveIconButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ExpressiveIconButton &&
            widget.semanticsId == 'mobile_chat_browser',
      ),
    );
    expect(screen.parked, isTrue);
    expect(screen.tooltip, 'No screen open yet');
    final semantics = tester.widget<Semantics>(findId('mobile_chat_browser'));
    expect(semantics.properties.enabled, isFalse);
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
    final screen = tester.widget<ExpressiveIconButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ExpressiveIconButton &&
            widget.semanticsId == 'mobile_chat_browser',
      ),
    );
    expect(screen.parked, isFalse);
    expect(screen.tooltip, 'Take over the screen');
    final semantics = tester.widget<Semantics>(findId('mobile_chat_browser'));
    expect(semantics.properties.enabled, isTrue);
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
    expect(more.right, lessThanOrEqualTo(kPhoneSize.width - 10));
    final Rect pill = tester.getRect(findId('mobile_chat_bot_pill'));
    expect(pill.right, lessThan(more.left));
  });

  testWidgets(
    'contact fills remaining width beside the persistent screen control',
    (tester) async {
      await pumpPhone(
        tester,
        MobileChatChrome(
          agent: agent(id: 'a1', name: 'Alex'),
          onBack: () {},
          onOpenProfile: () {},
        ),
      );
      final pill = tester.getRect(findId('mobile_chat_bot_pill'));
      expect(
        pill.right,
        kPhoneSize.width - 12 - MobileLayout.controlHeight - 8,
      );
      expect(
        tester.getRect(findId('mobile_chat_browser')).right,
        kPhoneSize.width - 12,
      );
      expect(pill.left, 12 + MobileLayout.controlHeight + 10);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Active now'), findsNothing);
    },
  );

  testWidgets(
    'large text grows the chrome and reduced motion keeps dots static',
    (tester) async {
      final controller = FakeRelayController();
      controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
      CoworkRelayLink.instance.bind(controller);
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
