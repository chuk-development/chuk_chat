// The message rail in the real desktop window (`RootWrapperDesktop`) with an
// open long chat and the sidebar folded. The rail stands in the left icon
// column under the folded sidebar's icons: it must be centred in that
// column, measured in pixels on screen:
//
// - across: every strip's centre on the icons' axis (the hamburger, the
//   rail icons and the gear all stand on it);
// - down: the rail's middle halfway between the bottom of the last icon
//   above it and the top of the gear below it.
//
// Before the fix the strips stood at x 12..20 (axis 31) and the rail was
// centred on the window (222..812 in a 1035 px window): 82 px under the
// icons, 178 px over the gear.
//
// Set CHUK_RAIL_SHOT=<dir> to also write a PNG of each case there.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/widgets/chat_turn_rail.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

import '../perf/chat_desktop_perf_fixture.dart';
import '../perf/perf_support.dart';
import '../platform_specific/mobile/mobile_support.dart';
import '../support/shell_config.dart';
import '../support/test_app.dart';

const Timeout _guard = Timeout(Duration(minutes: 3));

ThemeData _dark() => buildAppTheme(
  accent: kDefaultAccentColor,
  iconFg: kDefaultIconFgColor,
  bg: kDefaultBgColor,
  brightness: Brightness.dark,
  palette: kPlaneDarkPalette,
);

Future<void> _shot(WidgetTester tester, String name) async {
  final String? dir = Platform.environment['CHUK_RAIL_SHOT'];
  if (dir == null || dir.isEmpty) return;
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(const ValueKey<String>('shot')),
  );
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    await File('$dir/$name.png').writeAsBytes(data.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadRealFonts);

  for (final Size size in const <Size>[
    Size(1440, 1035),
    Size(1920, 1080),
    Size(1440, 900),
  ]) {
    final String px = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('folded sidebar, long chat, $px: rail centred in the icon '
        'column', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      silenceUnrelatedPlugins(tester);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      seedDesktopPerfChat();
      ChatStorageService.selectedChatId = desktopPerfChatId;
      addTearDown(() {
        ChatStorageService.selectedChatId = null;
        removeDesktopPerfChat();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: _dark(),
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepaintBoundary(
            key: const ValueKey<String>('shot'),
            child: RootWrapperDesktop(config: testShellConfig()),
          ),
        ),
      );
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final List<Rect> strips = desktopRailStrips(tester);
      expect(strips.length, kChatTurnRailMaxTicks);
      final List<Rect> bars = find
          .descendant(
            of: find.byType(ChatTurnRail),
            matching: find.byType(AnimatedContainer),
          )
          .evaluate()
          .map((Element e) => tester.getRect(find.byWidget(e.widget)))
          .toList();
      // The icons of the folded column, top to bottom; the gear is last.
      final List<Rect> icons =
          find
              .byType(SbNavIcon)
              .evaluate()
              .map((Element e) => tester.getRect(find.byWidget(e.widget)))
              .where((Rect r) => r.left < 60)
              .toList()
            ..sort((Rect a, Rect b) => a.top.compareTo(b.top));
      final Rect gear = tester.getRect(find.byKey(kSbRailSettingsKey));
      final double iconsBottom = icons
          .where((Rect r) => r.bottom < size.height / 2)
          .map((Rect r) => r.bottom)
          .reduce((double a, double b) => a > b ? a : b);
      final double railTop = strips.first.center.dy;
      final double railBottom = strips.last.center.dy;
      final double gapAbove = railTop - iconsBottom;
      final double gapBelow = gear.top - railBottom;
      final double axis = icons.first.center.dx;
      debugPrint(
        '$px: icon axis ${axis.toStringAsFixed(1)}, strip axis '
        '${bars.first.center.dx.toStringAsFixed(1)}; icons end '
        '${iconsBottom.toStringAsFixed(1)}, strips '
        '${railTop.toStringAsFixed(1)}..${railBottom.toStringAsFixed(1)}, '
        'gear from ${gear.top.toStringAsFixed(1)}: gap above '
        '${gapAbove.toStringAsFixed(1)}, below ${gapBelow.toStringAsFixed(1)}',
      );
      await _shot(tester, 'root_$px');

      expect(axis, closeTo(kSbNavIconCentre, 0.5));
      for (final Rect bar in bars) {
        expect(bar.center.dx, closeTo(axis, 0.5));
      }
      expect(gear.center.dx, closeTo(axis, 0.5));
      expect((gapAbove - gapBelow).abs(), lessThanOrEqualTo(1.0));
      expect(gapAbove, greaterThan(0));

      await MultiplexSession.shutdown();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    }, timeout: _guard);
  }
}
