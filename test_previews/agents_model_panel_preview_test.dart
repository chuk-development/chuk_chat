// Headless preview of CHAT-54: the Agents composer without a model picker
// (phone and desktop) and the agent's settings in the desktop right pane.
// Not part of `flutter test` (this folder is outside test/). Writes PNGs with
//
//   PREVIEW_OUT=after flutter test test_previews/agents_model_panel_preview_test.dart --update-goldens
//
// into _scratch/agents_ui/<PREVIEW_OUT>/ (gitignored). Default: "after".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/env_loader.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/widgets/text_shimmer.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/agents/roster_pins.dart';
import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';

import '../test/platform_specific/mobile/mobile_support.dart';
import '../test/support/fake_relay_controller.dart';
import '../test/support/test_app.dart';

final String _out =
    '../_scratch/agents_ui/${Platform.environment['PREVIEW_OUT'] ?? 'after'}';

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
}

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _Session implements AccountSessionSource {
  const _Session();
  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    userId: 'user-1',
  );
  @override
  Future<AccountSession?> refresh() async => current();
}

/// The chat screen builds an AudioRecorder on mount; there is no plugin
/// under `flutter test`. Answer that one channel with a null.
void _silenceRecorder(WidgetTester tester) {
  const MethodChannel record = MethodChannel('com.llfbandit.record/messages');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    record,
    (MethodCall call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      record,
      null,
    ),
  );
}

void main() {
  setUpAll(() async {
    // What test/flutter_test_config.dart does for test/: no .env, no
    // endless shimmer, read marks written at once.
    EnvLoader.skipFileForTests();
    AgentReadMarks.persistDelay = Duration.zero;
    TextShimmer.enabled = false;
    await loadRealFonts();
  });
  setUp(() async {
    debugAgentsChatCoreOverride = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    RosterPins.instance.reset();
    await ChatStorageService.reset();
  });
  tearDown(() async {
    debugAgentsChatCoreOverride = null;
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    RosterPins.instance.reset();
    await ChatStorageService.reset();
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 600));
    await expectLater(
      find.byType(MaterialApp).first,
      matchesGoldenFile('$_out/$name.png'),
    );
  }

  testWidgets('phone thread composer', (tester) async {
    _silenceRecorder(tester);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        AgentsThreadView(
          phoneLayout: true,
          controllerBuilder: () async => FakeRelayController(),
          sessionSource: const _Session(),
          threadKey: 'preview-phone',
          fileSaver: _NoopSaver(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await shoot(tester, 'model_panel_phone_composer');
  });

  Future<void> pumpDesktop(WidgetTester tester) async {
    _silenceRecorder(tester);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final LocalAgentRosterSource roster = LocalAgentRosterSource();
    for (final String name in <String>['Amber', 'Cobalt', 'Jade']) {
      roster.addAgent(name: name);
    }
    final AppModeService mode = AppModeService(initial: AppMode.agents)
      ..show(AppMode.agents);
    await tester.pumpWidget(
      testApp(
        MessengerShell(
          appMode: mode,
          relayControllerBuilder: () async => FakeRelayController(),
          sessionSource: const _Session(),
          pairingStore: AgentsPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          roomSource: LocalRoomSource(),
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('desktop thread composer', (tester) async {
    await pumpDesktop(tester);
    await shoot(tester, 'model_panel_desktop_thread');
  });

  testWidgets('desktop thread, agent pill tapped', (tester) async {
    await pumpDesktop(tester);
    // The details pane may come up open on a fresh launch; the pill is what
    // the owner taps to see the agent's settings.
    final Finder pane = find.byKey(const ValueKey<String>('desk-right-pane'));
    if (pane.evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Close (Esc)'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(AgentChromePill));
    await tester.pumpAndSettle();
    await shoot(tester, 'model_panel_desktop_pill_settings');
  });

  testWidgets('desktop pane, a settings row opened inside it', (tester) async {
    await pumpDesktop(tester);
    final Finder pane = find.byKey(const ValueKey<String>('desk-right-pane'));
    if (pane.evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Close (Esc)'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(AgentChromePill));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: pane, matching: find.text('Profile & preferences')),
    );
    await tester.pumpAndSettle();
    await shoot(tester, 'model_panel_desktop_pane_subpage');
  });
}
