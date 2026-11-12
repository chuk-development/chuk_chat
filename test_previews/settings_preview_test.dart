// Preview renders of every settings surface, phone and desktop, so the one
// settings pattern (docs/DESIGN.md §2, "One settings pattern") can be seen
// without the running app.
//
// This directory is outside test/, so a plain `flutter test` does not run it.
// Write the PNGs with:
//   flutter test test_previews/settings_preview_test.dart --update-goldens
// They land in _scratch/agents_ui/<_phase>/settings_*.png (gitignored).

// It reaches test-only seams (the Agents build switch, the fake sources).
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_host_activity_page.dart';
import 'package:chuk_chat/pages/agent_profile_edit_page.dart';
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/mobile_agents_settings_page.dart';
import 'package:chuk_chat/pages/settings/herenow_settings_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/widgets/settings_surface.dart';

import '../test/platform_specific/mobile/mobile_support.dart';
import '../test/support/shell_config.dart';
import '../test/support/test_app.dart';

/// Switch to 'after' once the migration is in.
const String _phase = 'after';
const String _out = '../_scratch/agents_ui/$_phase';

const Size _desk = Size(1400, 900);

ThemeData _theme() {
  final ThemeData base = buildAppTheme(
    accent: const Color(0xFF7C9CF5),
    iconFg: const Color(0xFFE6E6E6),
    bg: const Color(0xFF101012),
    brightness: Brightness.dark,
    uiFont: 'Inter',
  );
  // A few app styles name no family; on a desktop the system font fills in.
  // The test has no system font, so name Inter here.
  return base.copyWith(
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: (base.appBarTheme.titleTextStyle ?? const TextStyle())
          .copyWith(fontFamily: 'Inter'),
    ),
    textButtonTheme: TextButtonThemeData(
      style: (base.textButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle>(
          (base.textButtonTheme.style?.textStyle?.resolve(<WidgetState>{}) ??
                  const TextStyle())
              .copyWith(fontFamily: 'Inter'),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: (base.filledButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle>(
          (base.filledButtonTheme.style?.textStyle?.resolve(<WidgetState>{}) ??
                  const TextStyle())
              .copyWith(fontFamily: 'Inter'),
        ),
      ),
    ),
  );
}

AgentsAgent _amber() => AgentsAgent(
  id: 'amber',
  name: 'Amber Fitzgerald',
  role: 'Research and long-form writing',
  brief: 'Reads the week and writes the Monday memo.',
  running: true,
  onHost: true,
  lastActivity: DateTime(2026, 11, 12, 9, 30),
  threads: <AgentsThreadInfo>[
    AgentsThreadInfo(key: 'amber-main', title: 'General'),
  ],
);

final GlobalKey _shot = GlobalKey();

Future<void> _pumpPhone(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = kPhoneSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: MediaQuery(
        data: const MediaQueryData(
          size: kPhoneSize,
          padding: kPhonePadding,
          viewPadding: kPhonePadding,
        ),
        child: MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          home: page,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// A desktop window: a plain page behind, then [open] runs on it (a modal,
/// a push), as the shell does.
Future<void> _pumpDesk(
  WidgetTester tester, {
  Widget? home,
  Future<void> Function(BuildContext context)? open,
}) async {
  tester.view.physicalSize = _desk;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding.zero;
  addTearDown(tester.view.reset);
  late BuildContext appContext;
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home:
            home ??
            Builder(
              builder: (BuildContext context) {
                appContext = context;
                return const Scaffold(
                  body: Center(child: Text('chat behind the modal')),
                );
              },
            ),
      ),
    ),
  );
  await tester.pump();
  if (open != null && appContext.mounted) {
    open(appContext);
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _save(WidgetTester tester, String name) async {
  debugDisableShadows = false;
  try {
    await expectLater(
      find.byKey(_shot),
      matchesGoldenFile('$_out/settings_$name.png'),
    );
  } finally {
    debugDisableShadows = true;
  }
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsRelayLink.instance.reset();
    debugAgentsChatCoreOverride = true;
  });
  tearDown(() {
    AgentsRelayLink.instance.reset();
    debugAgentsChatCoreOverride = null;
  });

  late LocalAgentRosterSource source;
  late AgentProfileStore profiles;
  late MobileChatPreferences prefs;

  setUp(() {
    source = LocalAgentRosterSource(seed: <AgentsAgent>[_amber()]);
    profiles = AgentProfileStore();
    prefs = MobileChatPreferences();
  });
  tearDown(() {
    source.dispose();
    profiles.dispose();
    prefs.dispose();
  });

  AgentSettingsView agentSettings({bool page = true, VoidCallback? onClose}) {
    void noop() {}
    return page
        ? MobileAgentsSettingsPage(
            agentId: 'amber',
            chatId: null,
            source: source,
            profiles: profiles,
            preferences: prefs,
            onEdit: noop,
            onControls: noop,
            onModel: noop,
            onAutomations: noop,
            onSkills: noop,
            onConnectors: noop,
            onSecrets: noop,
            onRooms: noop,
            onSettings: noop,
            onDocuments: noop,
            onDelete: noop,
            onChat: noop,
          )
        : AgentSettingsView(
            agentId: 'amber',
            source: source,
            profiles: profiles,
            preferences: prefs,
            onClose: onClose ?? noop,
            onEdit: noop,
            onControls: noop,
            onModel: noop,
            onAutomations: noop,
            onSkills: noop,
            onConnectors: noop,
            onSecrets: noop,
            onRooms: noop,
            onSettings: noop,
            onDocuments: noop,
            onDelete: noop,
            onChat: noop,
          );
  }

  testWidgets('phone: Chat settings hub', (WidgetTester tester) async {
    await _pumpPhone(tester, SettingsPage(config: testShellConfig()));
    await _save(tester, 'phone_chat_settings');
  });

  testWidgets('phone: per-agent settings', (WidgetTester tester) async {
    await _pumpPhone(tester, agentSettings());
    await _save(tester, 'phone_agent_settings');
  });

  testWidgets('phone: Agents section page (here.now)', (
    WidgetTester tester,
  ) async {
    await _pumpPhone(tester, const HereNowSettingsPage());
    await _save(tester, 'phone_agents_herenow');
  });

  testWidgets('phone: agent profile', (WidgetTester tester) async {
    await _pumpPhone(
      tester,
      AgentProfileEditPage(
        agent: _amber(),
        source: source,
        profiles: profiles,
        onRename: (_) {},
      ),
    );
    await _save(tester, 'phone_agent_profile');
  });

  testWidgets('phone: host & activity', (WidgetTester tester) async {
    final FakeAgentControlSource control = FakeAgentControlSource();
    addTearDown(control.dispose);
    await _pumpPhone(
      tester,
      AgentHostActivityPage(agent: _amber(), source: control),
    );
    await _save(tester, 'phone_agent_host');
  });

  testWidgets('desktop: Chat settings modal', (WidgetTester tester) async {
    await _pumpDesk(
      tester,
      open: (BuildContext context) =>
          showDesktopSettingsModal(context, config: testShellConfig()),
    );
    await _save(tester, 'desktop_chat_settings');
  });

  testWidgets('desktop: Chat settings modal, Agents section', (
    WidgetTester tester,
  ) async {
    await _pumpDesk(
      tester,
      open: (BuildContext context) => showDesktopSettingsModal(
        context,
        config: testShellConfig(),
        initialSectionId: 'herenow',
      ),
    );
    await _save(tester, 'desktop_agents_herenow');
  });

  testWidgets('desktop: per-agent settings', (WidgetTester tester) async {
    await _pumpDesk(
      tester,
      open: (BuildContext context) =>
          openSettingsSurface(context, (_) => agentSettings()),
    );
    await _save(tester, 'desktop_agent_settings');
  });

  testWidgets('desktop: details pane settings', (WidgetTester tester) async {
    await _pumpDesk(
      tester,
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Expanded(child: Center(child: Text('thread'))),
            const VerticalDivider(width: 1),
            SizedBox(width: 380, child: agentSettings(page: false)),
          ],
        ),
      ),
    );
    await _save(tester, 'desktop_details_pane');
  });

  testWidgets('desktop: agent profile', (WidgetTester tester) async {
    await _pumpDesk(
      tester,
      open: (BuildContext context) => openSettingsSurface(
        context,
        (_) => AgentProfileEditPage(
          agent: _amber(),
          source: source,
          profiles: profiles,
          onRename: (_) {},
        ),
      ),
    );
    await _save(tester, 'desktop_agent_profile');
  });
}
