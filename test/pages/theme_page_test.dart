// Renders ThemePage to prove the preset dropdown, contrast slider and
// font pickers build without errors, and that selecting a preset drives the
// shell-config setters.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/theme/theme_presets.dart';

class _State {
  Brightness themeMode = Brightness.dark;
  Color accent = kDefaultAccentColor;
  Color iconFg = kDefaultIconFgColor;
  Color bg = kDefaultBgColor;
  double contrast = kDefaultContrast;
  String uiFont = kDefaultUiFontFamily;
  String chatFont = kDefaultChatFontFamily;
  bool dynamicColor = false;
}

AppShellConfig _config(_State s) => AppShellConfig(
  currentThemeMode: s.themeMode,
  currentAccentColor: s.accent,
  currentIconFgColor: s.iconFg,
  currentBgColor: s.bg,
  setThemeMode: (m) => s.themeMode = m,
  setAccentColor: (c) => s.accent = c,
  setIconFgColor: (c) => s.iconFg = c,
  setBgColor: (c) => s.bg = c,
  dynamicColorEnabled: s.dynamicColor,
  setDynamicColorEnabled: (v) async => s.dynamicColor = v,
  contrast: s.contrast,
  setContrast: (v) async => s.contrast = v,
  uiFontFamily: s.uiFont,
  setUiFontFamily: (v) async => s.uiFont = v,
  showReasoningTokens: false,
  setShowReasoningTokens: (_) {},
  showModelInfo: false,
  setShowModelInfo: (_) {},
  showTps: false,
  setShowTps: (_) {},
  autoSendVoiceTranscription: false,
  setAutoSendVoiceTranscription: (_) {},
  imageGenEnabled: false,
  setImageGenEnabled: (_) {},
  imageGenDefaultSize: 'landscape_4_3',
  setImageGenDefaultSize: (_) {},
  imageGenCustomWidth: 1024,
  setImageGenCustomWidth: (_) {},
  imageGenCustomHeight: 768,
  setImageGenCustomHeight: (_) {},
  imageGenUseCustomSize: false,
  setImageGenUseCustomSize: (_) {},
  includeRecentImagesInHistory: true,
  setIncludeRecentImagesInHistory: (_) {},
  includeAllImagesInHistory: false,
  setIncludeAllImagesInHistory: (_) {},
  includeReasoningInHistory: false,
  setIncludeReasoningInHistory: (_) {},
  includeToolResultsInHistory: true,
  setIncludeToolResultsInHistory: (_) {},
  toolCallingEnabled: true,
  setToolCallingEnabled: (_) {},
  toolDiscoveryMode: true,
  setToolDiscoveryMode: (_) {},
  showToolCalls: true,
  setShowToolCalls: (_) {},
  uiLocale: 'en',
  setUiLocale: (_) {},
  chatFontSize: kDefaultChatFontSize,
  setChatFontSize: (_) {},
  chatFontFamily: s.chatFont,
  setChatFontFamily: (v) => s.chatFont = v,
  uiScale: kDefaultUiScale,
  setUiScale: (_) async {},
);

Widget _host(AppShellConfig config) => MaterialApp(
  localizationsDelegates: const [AppLocalizations.delegate],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: ThemePage(config: config),
);

void main() {
  testWidgets('renders the preset, contrast and font controls',
      (tester) async {
    // Tall viewport so the whole lazy ListView is built in one pass.
    tester.view.physicalSize = const Size(400, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(_config(_State())));
    await tester.pumpAndSettle();

    expect(find.text('Presets'), findsOneWidget); // section header
    expect(find.text('Contrast'), findsOneWidget);
    expect(find.text('Fonts'), findsOneWidget);
    expect(find.text('Interface font'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget); // the contrast slider
  });

  testWidgets('has no layout overflow at a narrow width', (tester) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(_config(_State())));
    await tester.pumpAndSettle();

    // Drive the lazy ListView to the end so every lower card is laid out and
    // would report an overflow if one existed.
    await tester.dragUntilVisible(
      find.text('Chat font'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a preset from the dropdown applies it to the config',
      (tester) async {
    final state = _State();
    await tester.pumpWidget(_host(_config(state)));
    await tester.pumpAndSettle();

    // Open the preset dropdown and pick a light pack (GitHub). The menu is
    // scrollable now, so scroll the item into view before tapping it.
    final github = kThemePresets.firstWhere((p) => p.name == 'GitHub');
    await tester.tap(find.byType(DropdownButton<ThemePreset>));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('GitHub'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub').last);
    await tester.pumpAndSettle();

    expect(state.themeMode, github.brightness);
    expect(state.accent, github.accent);
    expect(state.iconFg, github.iconFg);
    expect(state.bg, github.bg);
    expect(state.contrast, github.contrast);
    expect(state.uiFont, github.uiFont);
  });
}
