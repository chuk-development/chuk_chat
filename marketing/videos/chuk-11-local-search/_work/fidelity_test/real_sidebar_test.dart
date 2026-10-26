// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the REAL sidebars (SidebarDesktop, SidebarMobile) in the Clawed dark theme
// to PNG, with the episode's fictional chats, idle and with "landlord" typed into the
// real search field. These are the reference halves of the fidelity sheets of
// episode 11. Not part of the app's test suite.
// Run from the repo root:
//   flutter test marketing/videos/chuk-11-local-search/_work/fidelity_test/real_sidebar_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

const String work = 'marketing/videos/chuk-11-local-search/_work';
const double ratio = 2.0;

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

ThemeData _theme() {
  final t = buildAppTheme(
    accent: const Color(0xFFD97757),
    iconFg: const Color(0xFFE8E4D8),
    bg: const Color(0xFF262624),
    brightness: Brightness.dark,
    contrast: 0.55,
  );
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: 'Ubuntu'),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Ubuntu'),
  );
}

/// The episode's chats: fictional, harmless, private-feeling. Same list as
/// episode.py CHATS (days before today, title).
const List<(int, String)> chats = <(int, String)>[
  (0, 'Salary talk prep'),
  (1, "Landlord won't return deposit"),
  (2, 'Rash on my arm'),
  (4, 'Letter to my landlord about mould'),
  (9, 'Sleep after night shifts'),
  (17, 'Is this mole normal?'),
  (35, 'Can my landlord enter without asking?'),
  (42, 'Splitting rent with Sam'),
  (57, 'Therapist or GP first?'),
];

void _seed() {
  ChatStorageState.chatsById.clear();
  final now = DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day);
  for (var i = 0; i < chats.length; i++) {
    final (days, title) = chats[i];
    final at = days == 0
        ? midnight.add(const Duration(hours: 9, minutes: 41))
        : midnight.subtract(Duration(days: days)).add(const Duration(hours: 20));
    ChatStorageState.chatsById['c$i'] = StoredChat.forSidebar(
      id: 'c$i',
      createdAt: at,
      updatedAt: at,
      isStarred: false,
      title: title,
    );
  }
}

Future<void> _save(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: ratio);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  File('$work/fidelity/real-$name.png').writeAsBytesSync(png!);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Widget _app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'Ubuntu'),
        child: Scaffold(body: child),
      ),
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _font('Ubuntu', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    await _font('JetBrains Mono', ['assets/fonts/JetBrainsMono-wght.ttf']);
    final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
    await _font('MaterialIcons', ['$sdk/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    debugSbChatTimeOfDayOverride = '9:41 AM';
    AppThemeService.instance.setChatFontFamily(kChatFontFamilyJetBrainsMono);
  });
  setUp(_seed);
  tearDown(ChatStorageState.chatsById.clear);

  // The theme values the rebuild needs (colours and text styles), as JSON.
  testWidgets('theme tokens', (tester) async {
    late ThemeData theme;
    await tester.pumpWidget(_app(Builder(builder: (context) {
      theme = Theme.of(context);
      return const SizedBox();
    })));
    await _settle(tester);
    String c(Color x) => '#${x.toARGB32().toRadixString(16).padLeft(8, '0')}';
    Map<String, Object?> st(TextStyle? s) => {
          'size': s?.fontSize, 'weight': s?.fontWeight?.value, 'ls': s?.letterSpacing,
          'height': s?.height, 'family': s?.fontFamily,
        };
    File('$work/fidelity/real-tokens.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
      'onSurface': c(theme.colorScheme.onSurface),
      'onSurfaceVariant': c(theme.m3.onSurfaceVariant),
      'surfaceContainer': c(theme.m3.surfaceContainer),
      'surfaceContainerHigh': c(theme.m3.surfaceContainerHigh),
      'surfaceContainerHighest': c(theme.m3.surfaceContainerHighest),
      'scaffold': c(theme.scaffoldBackgroundColor),
      'card': c(theme.cardColor),
      'primary': c(theme.colorScheme.primary),
      'accentInk': c(theme.accentForegroundOn(theme.m3.surfaceContainer)),
      'iconFg': c(theme.resolvedIconColor),
      'bodyLarge': st(theme.textTheme.bodyLarge),
      'bodySmall': st(theme.textTheme.bodySmall),
      'labelLarge': st(theme.textTheme.labelLarge),
      'labelMedium': st(theme.textTheme.labelMedium),
    }));
  });

  // root_wrapper_desktop.dart: the sidebar is 320 wide, the hamburger sits on top of it.
  testWidgets('desktop sidebar', (tester) async {
    tester.view.physicalSize = const Size(320, 540) * ratio;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(_app(RepaintBoundary(
      key: key,
      child: Builder(builder: (context) {
        final iconFg = Theme.of(context).resolvedIconColor;
        return Stack(children: [
          Positioned.fill(
            child: SidebarDesktop(
              onChatSelected: (_) {},
              onSettingsTapped: () {},
              onWorkspacesTapped: () {},
              onMediaTapped: () {},
              onNewChatTapped: () {},
              selectedChatId: null,
              isCompactMode: false,
              showWorkspacesButton: true,
            ),
          ),
          // copied from root_wrapper_desktop.dart (hamburger, never moves)
          Positioned(
            top: kTopInitialSpacing + (kMenuButtonHeight - kButtonVisualHeight) / 2,
            left: kSbNavIconCentre - kMenuButtonHeight / 2,
            child: SizedBox(
              width: kMenuButtonHeight,
              height: kButtonVisualHeight,
              child: IconButton(
                icon: AppIcon(Icons.menu_rounded, color: iconFg, size: 24),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: kMenuButtonHeight,
                  height: kButtonVisualHeight,
                ),
                onPressed: () {},
              ),
            ),
          ),
        ]);
      }),
    )));
    await _settle(tester);
    await _save(tester, key, 'desktop-idle');
    await tester.tap(find.text('Search'));
    await _settle(tester);
    await _save(tester, key, 'desktop-open');
    await tester.enterText(find.byType(TextField), 'landlord');
    await _settle(tester);
    await _save(tester, key, 'desktop-search');
    File('$work/fidelity/real-dates.json').writeAsStringSync(jsonEncode({
      for (final t in tester.widgetList<SbChatTile>(find.byType(SbChatTile))) t.title: t.dateLine,
    }));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

  // root_wrapper_mobile.dart: the sidebar fills the screen; 360 wide (a common Android width).
  testWidgets('mobile sidebar', (tester) async {
    tester.view.physicalSize = const Size(360, 470) * ratio;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(_app(RepaintBoundary(
      key: key,
      child: SidebarMobile(
        onChatSelected: (_) {},
        onSettingsTapped: () {},
        onWorkspacesTapped: () {},
        onMediaTapped: () {},
        onNewChatTapped: () {},
        selectedChatId: null,
        isCompactMode: true,
      ),
    )));
    await _settle(tester);
    await _save(tester, key, 'mobile-idle');
    await tester.tap(find.text('Search'));
    await _settle(tester);
    await _save(tester, key, 'mobile-open');
    await tester.enterText(find.byType(TextField), 'landlord');
    await _settle(tester);
    await _save(tester, key, 'mobile-search');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
