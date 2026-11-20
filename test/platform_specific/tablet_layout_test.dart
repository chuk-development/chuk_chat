// Phone or tablet: which layout a window gets (CHAT-150).
//
// On Android and iOS the SHORTEST side of the window decides
// (`MobileLayout.isPhoneSize`, Material window size classes): below 600 dp
// is a phone, 600 dp and more is a tablet with the wide, desktop-like
// layout. A rotation never changes the answer. A desktop OS keeps the old
// width rule.
//
// The second half pumps chuk's real `RootWrapper` (the plain build's root)
// on Android and checks that a rotation keeps the open chat screen (the same
// State, the same draft), and that a split-screen window that crosses the
// phone breakpoint carries the draft to the other screen.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/platform_specific/root_wrapper.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_mobile.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/composer_draft_carry.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/theme/theme_presets.dart';

import '../perf/chat_desktop_perf_fixture.dart';
import '../perf/perf_support.dart' show silenceUnrelatedPlugins;
import 'mobile/mobile_support.dart' show loadRealFonts;
import '../support/shell_config.dart';
import '../support/test_app.dart';

/// Window sizes in logical pixels (dp).
const Size _phonePortrait = Size(390, 844);
const Size _phoneLandscape = Size(844, 390);
const Size _tabletPortrait = Size(800, 1280);
const Size _tabletLandscape = Size(1280, 800);

/// A tablet in split screen with a third of the width: a phone window.
const Size _tabletSplit = Size(420, 800);

final TargetPlatformVariant _android = TargetPlatformVariant.only(
  TargetPlatform.android,
);

Future<void> _setWindow(WidgetTester tester, Size dp, {double dpr = 1}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = dp * dpr;
}

/// Runs [body] and swallows the one error a test without a backend must
/// see: opening a chat screen asks services that read the Supabase client.
Future<void> _withoutBackend(Future<void> Function() body) async {
  final Completer<void> done = Completer<void>();
  runZonedGuarded(
    () async {
      await body();
      if (!done.isCompleted) done.complete();
    },
    (Object error, StackTrace stack) {
      if (error is StateError &&
          error.message.contains('SupabaseService.initialize()')) {
        return;
      }
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  await done.future;
}

Future<void> _pumpRoot(WidgetTester tester, Size dp, {double dpr = 1}) async {
  silenceUnrelatedPlugins(tester);
  await _setWindow(tester, dp, dpr: dpr);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RootWrapper(config: testShellConfig()),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The wrapper schedules deferred work at 2 s and 8 s, and a chat screen
/// leaves the chat socket a 60 s idle-close timer.
Future<void> _drain(WidgetTester tester) async {
  await MultiplexSession.shutdown();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 61));
}

void main() {
  group('the rule (MobileLayout.isPhoneSize)', () {
    testWidgets(
      'Android: the shortest side decides, rotation changes nothing',
      (tester) async {
        expect(MobileLayout.isTouchPlatform, isTrue);
        expect(MobileLayout.isPhoneSize(_phonePortrait), isTrue);
        expect(MobileLayout.isPhoneSize(_phoneLandscape), isTrue);
        expect(MobileLayout.isPhoneSize(_tabletPortrait), isFalse);
        expect(MobileLayout.isPhoneSize(_tabletLandscape), isFalse);
        // A Pixel Tablet: 2560x1600 px at 2.0 is 1280x800 dp.
        expect(MobileLayout.isPhoneSize(const Size(2560, 1600) / 2), isFalse);
        expect(MobileLayout.isPhoneSize(_tabletSplit), isTrue);
        // The edge: 600 dp is a tablet already.
        expect(MobileLayout.isPhoneSize(const Size(600, 960)), isFalse);
        expect(MobileLayout.isPhoneSize(const Size(599, 960)), isTrue);
      },
      variant: _android,
    );

    testWidgets('a desktop OS keeps the width rule', (tester) async {
      expect(MobileLayout.isTouchPlatform, isFalse);
      expect(MobileLayout.isPhoneSize(_phonePortrait), isTrue);
      // A short, wide desktop window stays the wide layout.
      expect(MobileLayout.isPhoneSize(_phoneLandscape), isFalse);
      expect(MobileLayout.isPhoneSize(_tabletPortrait), isFalse);
      expect(MobileLayout.isPhoneSize(_tabletLandscape), isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('chuk\'s RootWrapper on Android', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      ChatStorageService.selectedChatId = null;
    });
    tearDown(() => ChatStorageService.selectedChatId = null);

    for (final (String name, Size dp, double dpr, bool phone)
        in <(String, Size, double, bool)>[
          ('phone 390x844', _phonePortrait, 1, true),
          ('phone in landscape 844x390', _phoneLandscape, 1, true),
          ('tablet portrait 800x1280', _tabletPortrait, 1, false),
          ('tablet landscape 1280x800', _tabletLandscape, 1, false),
          ('Pixel Tablet 2560x1600 px at 2.0', const Size(1280, 800), 2, false),
        ]) {
      testWidgets('$name: ${phone ? 'phone' : 'wide'} layout', (tester) async {
        await _withoutBackend(() async {
          await _pumpRoot(tester, dp, dpr: dpr);
          expect(
            find.byType(RootWrapperMobile),
            phone ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(RootWrapperDesktop),
            phone ? findsNothing : findsOneWidget,
          );
          await _drain(tester);
        });
      }, variant: _android);
    }

    testWidgets('a rotation keeps the chat screen and its draft; a split '
        'screen carries the draft to the phone screen and back', (
      tester,
    ) async {
      await _withoutBackend(() async {
        await _pumpRoot(tester, _tabletLandscape);
        final ChukChatUIDesktopState wide = tester.state(
          find.byType(ChukChatUIDesktop),
        );
        wide.composerController.text = 'half a thought';

        // Landscape to portrait: the same screen, nothing rebuilt.
        await _setWindow(tester, _tabletPortrait);
        await _settle(tester);
        expect(find.byType(RootWrapperDesktop), findsOneWidget);
        expect(
          identical(wide, tester.state(find.byType(ChukChatUIDesktop))),
          isTrue,
        );
        expect(wide.composerController.text, 'half a thought');

        // And back.
        await _setWindow(tester, _tabletLandscape);
        await _settle(tester);
        expect(
          identical(wide, tester.state(find.byType(ChukChatUIDesktop))),
          isTrue,
        );

        // A third of the screen in split screen: the phone layout, with the
        // draft in its composer.
        await _setWindow(tester, _tabletSplit);
        await _settle(tester);
        expect(find.byType(RootWrapperMobile), findsOneWidget);
        final ChukChatUIMobileState narrow = tester.state(
          find.byType(ChukChatUIMobile),
        );
        expect(narrow.composerController.text, 'half a thought');

        // Full screen again: the wide layout gets the draft back.
        await _setWindow(tester, _tabletLandscape);
        await _settle(tester);
        final ChukChatUIDesktopState wideAgain = tester.state(
          find.byType(ChukChatUIDesktop),
        );
        expect(wideAgain.composerController.text, 'half a thought');
        await _drain(tester);
      });
    }, variant: _android);
  });

  group('ComposerDraftCarry', () {
    testWidgets('a draft goes only to the same chat, once, in the same frame', (
      tester,
    ) async {
      ComposerDraftCarry.stash('a', const TextEditingValue(text: 'x'));
      expect(ComposerDraftCarry.take('b'), isNull);
      expect(ComposerDraftCarry.take('a')?.text, 'x');
      expect(ComposerDraftCarry.take('a'), isNull);

      ComposerDraftCarry.stash(null, const TextEditingValue(text: 'y'));
      await tester.pump();
      // The frame ended: nobody took it, so it is gone.
      expect(ComposerDraftCarry.take(null), isNull);

      ComposerDraftCarry.stash('a', TextEditingValue.empty);
      expect(ComposerDraftCarry.take('a'), isNull);
    });
  });

  // Set CHUK_TABLET_SHOT=<dir> to write PNGs of the tablet layout there
  // (real fonts, dark theme, a seeded chat). Off by default.
  group('shots', () {
    final String shotDir = Platform.environment['CHUK_TABLET_SHOT'] ?? '';
    setUpAll(loadRealFonts);
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      seedDesktopPerfChat(desktopPerfMessages().take(14).toList());
      ChatStorageService.selectedChatId = desktopPerfChatId;
    });
    tearDown(() {
      ChatStorageService.selectedChatId = null;
      removeDesktopPerfChat();
    });

    Future<void> shot(WidgetTester tester, String name) async {
      final Element root = find.byType(RootWrapper).evaluate().single;
      await tester.runAsync(() async {
        final ui.Image image = await captureImage(root);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return;
        await File('$shotDir/$name.png')
            .writeAsBytes(data.buffer.asUint8List());
      });
    }

    for (final (String name, Size dp) in <(String, Size)>[
      ('chats_landscape', _tabletLandscape),
      ('chats_portrait', _tabletPortrait),
      ('chats_phone_landscape', _phoneLandscape),
    ]) {
      testWidgets(
        '$name',
        (tester) async {
          await _withoutBackend(() async {
            silenceUnrelatedPlugins(tester);
            await _setWindow(tester, dp);
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildAppTheme(
                  accent: kDefaultAccentColor,
                  iconFg: kDefaultIconFgColor,
                  bg: kDefaultBgColor,
                  brightness: Brightness.dark,
                  palette: kPlaneDarkPalette,
                ),
                localizationsDelegates: kTestLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: RootWrapper(config: testShellConfig()),
              ),
            );
            for (int i = 0; i < 30; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            await shot(tester, name);
            if (name != 'chats_phone_landscape') {
              // The sidebar open: the menu button at the top left.
              await tester.tap(
                find.byWidgetPredicate(
                  (Widget w) => w is AppIcon && w.icon == Icons.menu_rounded,
                ),
              );
              for (int i = 0; i < 20; i++) {
                await tester.pump(const Duration(milliseconds: 50));
              }
              await shot(tester, '${name}_sidebar');
            }
            await _drain(tester);
          });
        },
        variant: _android,
        skip: shotDir.isEmpty,
      );
    }
  });
}
