// The desktop sidebar's one settings gear.
//
// Folded, it stands at the foot of the rail, in the column and at the size
// of the rail icons above it. Open, it is the right-most item of the account
// line (name, credit, gear). While the panel opens or closes, the same gear
// flies along the bottom between the two places, in step with the panel.
//
// Set SIDEBAR_FOOTER_PNG=1 to also write PNGs (real fonts, Plane dark theme)
// of the folded, half-open and open states into _scratch/sidebar_footer/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

import '../helpers/icon_finder.dart';
import '../support/shell_config.dart';
import '../support/test_app.dart';
import 'mobile/mobile_support.dart';

const Size _window = Size(1200, 800);
final bool _writePngs = Platform.environment['SIDEBAR_FOOTER_PNG'] == '1';

ThemeData _planeDark() => buildAppTheme(
  accent: kDefaultAccentColor,
  iconFg: kDefaultIconFgColor,
  bg: kDefaultBgColor,
  brightness: Brightness.dark,
  palette: kPlaneDarkPalette,
);

Widget _app(Widget home) => MaterialApp(
  theme: _planeDark(),
  darkTheme: _planeDark(),
  themeMode: ThemeMode.dark,
  localizationsDelegates: kTestLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

Future<void> _png(WidgetTester tester, Finder boundary, String name) async {
  if (!_writePngs) return;
  final RenderRepaintBoundary rb = tester.renderObject<RenderRepaintBoundary>(
    boundary,
  );
  await tester.runAsync(() async {
    final ui.Image image = await rb.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final File out = File('_scratch/sidebar_footer/$name.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // The composer creates a recorder on mount; while the PNG is written in
    // real async time its missing plugin would otherwise fail the test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
    ChatStorageState.chatsById.clear();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: const ValueKey<String>('shot'),
          child: RootWrapperDesktop(config: testShellConfig()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  final Finder shot = find.byKey(const ValueKey<String>('shot'));
  final Finder gear = find.byKey(kSbRailSettingsKey);
  double gearX(WidgetTester tester) => tester.getRect(gear).center.dx;
  const double gearY = 800 - kSbFooterSettingsCentreFromBottom;

  testWidgets('folded: the gear stands at the foot of the rail column', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(gear, findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    final Rect settings = tester.getRect(gear);
    final Rect newChat = tester.getRect(find.byTooltip('New chat'));
    expect(settings.center.dx, closeTo(newChat.center.dx, 0.01));
    expect(settings.center.dx, closeTo(kSbNavIconCentre, 0.01));
    expect(settings.size, newChat.size);
    expect(settings.top, greaterThan(newChat.bottom));
    expect(settings.center.dy, closeTo(gearY, 0.01));
    expect(tester.takeException(), isNull);

    await _png(tester, shot, 'collapsed');
    await _drain(tester);
  });

  testWidgets('open: name, credit, then the gear at the right end', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(findIcon(Icons.menu_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final Finder line = find.byType(SbAccountLine);
    expect(line, findsOneWidget);
    // One gear on screen, not one in the rail and one in the row.
    expect(gear, findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    final Rect row = tester.getRect(line);
    final Rect settings = tester.getRect(gear);
    final Rect credit = tester.getRect(
      find.descendant(of: line, matching: find.byType(BalanceBadge)),
    );
    final Rect name = tester.getRect(
      find.descendant(of: line, matching: find.text('Account')),
    );
    expect(name.right, lessThanOrEqualTo(credit.left));
    expect(credit.right, lessThanOrEqualTo(settings.left));
    expect(settings.right, lessThanOrEqualTo(row.right));
    final double panelRight = tester.getRect(find.byType(SidebarDesktop)).right;
    expect(
      settings.center.dx,
      closeTo(panelRight - kSbFooterSettingsCentreFromRight, 0.01),
    );
    expect(settings.center.dy, closeTo(row.center.dy, 0.01));
    expect(settings.center.dy, closeTo(gearY, 0.01));
    expect(tester.takeException(), isNull);

    await _png(tester, shot, 'open');
    await _drain(tester);
  });

  testWidgets('the gear flies with the panel, both ways', (tester) async {
    await pumpShell(tester);
    final double railX = gearX(tester);

    await tester.tap(findIcon(Icons.menu_rounded).first);
    await tester.pump();
    final List<double> opening = <double>[gearX(tester)];
    bool shotTaken = false;
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      opening.add(gearX(tester));
      if (!shotTaken && i == 4) {
        shotTaken = true;
        await _png(tester, shot, 'half-open');
      }
    }
    final double openX = opening.last;
    expect(openX, greaterThan(railX + 100));
    // Mid-way it is strictly between the two places, on the same line.
    final double mid = opening[5];
    expect(mid, greaterThan(railX));
    expect(mid, lessThan(openX));
    expect(tester.getRect(gear).center.dy, closeTo(gearY, 0.01));
    for (int i = 1; i < opening.length; i++) {
      expect(opening[i], greaterThanOrEqualTo(opening[i - 1]));
    }

    await tester.tap(findIcon(Icons.menu_rounded).first);
    await tester.pump();
    final List<double> closing = <double>[gearX(tester)];
    for (int i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      closing.add(gearX(tester));
    }
    expect(closing.any((x) => x > railX && x < openX), isTrue);
    for (int i = 1; i < closing.length; i++) {
      expect(closing[i], lessThanOrEqualTo(closing[i - 1]));
    }
    expect(closing.last, closeTo(railX, 0.01));
    expect(tester.takeException(), isNull);
    await _drain(tester);
  });
}
