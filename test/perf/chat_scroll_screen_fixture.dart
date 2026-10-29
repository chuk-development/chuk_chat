// The real chat screen with one long Agents thread, for the scroll-up speed
// tests: `chat_scroll_real_screen_perf_test.dart` (widget test, debug) and
// `integration_test/chat_scroll_screen_perf_test.dart` (profile, on a
// device). `MessengerShell` with one agent whose thread holds the 300 mixed
// messages of `scrollPerfTranscript`, opened at its bottom.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';

import '../support/fake_relay_controller.dart';
import '../support/test_app.dart';
import 'chat_scroll_fixture.dart';
import 'perf_support.dart';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// A signed-in account, so the shell takes its normal paired path.
class _SignedIn implements AccountSessionSource {
  const _SignedIn();

  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    userId: 'perf-user',
  );

  @override
  Future<AccountSession?> refresh() async => current();
}

/// Resets the singletons the shell reads. Call before and after each test.
Future<void> resetScreenWorld() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await VerboseService.instance.setEnabled(false);
  AgentsRelayLink.instance.reset();
  AgentsRunLedger.instance.reset();
  AgentsReplayLoader.instance.reset();
  NotificationRouter.instance.reset();
  await ChatStorageService.reset();
  await AgentsChatStore.reset();
  await MultiplexSession.shutdown();
}

/// Seeds [disk] with the thread, mounts the shell, opens the thread and
/// returns the [ScrollableState] of its transcript.
Future<ScrollableState> mountRealScreenThread(
  WidgetTester tester,
  FakeDisk disk,
) async {
  const String key = 'host:perf-host';
  final agents = <AgentsAgent>[
    AgentsAgent(
      id: key,
      name: 'Agent',
      onHost: true,
      threads: const <AgentsThreadInfo>[
        AgentsThreadInfo(key: key, title: 'General'),
      ],
    ),
  ];
  await tester.runAsync(() async {
    disk.install();
    AgentsChatStore.userIdProvider = () => 'perf-user';
    await AgentsChatStore.replaceThread(key, scrollPerfTranscript());
    await AgentsChatStore.pending(key);
    await AgentsChatStore.rememberUser('perf-user');
    await AgentsChatStore.reset();
    await ChatStorageService.reset();
    disk.install();
    await drainNotifyDebounce();
  });

  final controller = FakeRelayController();
  final roster = LocalAgentRosterSource(seed: agents);
  await tester.pumpWidget(
    testApp(
      MessengerShell(
        relayControllerBuilder: () async => controller,
        sessionSource: const _SignedIn(),
        pairingStore: AgentsPairingStore(backend: _MemoryStore()),
        rosterSource: roster,
        onSignOut: () {},
      ),
    ),
  );
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  controller.set(
    const AgentsRelayState(
      phase: AgentsRelayPhase.paired,
      peerDeviceId: 'perf-host',
    ),
  );
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }

  // At phone width the shell opens on the inbox: open the thread.
  final Finder tile = find.byKey(const ValueKey<String>('mobile-agent-$key'));
  if (tile.evaluate().isNotEmpty) {
    await tester.tap(tile.first);
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  final Finder list = find.byWidgetPredicate(
    (w) =>
        w is CustomScrollView &&
        w.center == const ValueKey<String>('chat-transcript-center'),
  );
  expect(list, findsWidgets, reason: 'the thread never showed its list');
  final ScrollableState scrollable = tester.state<ScrollableState>(
    find.descendant(of: list.first, matching: find.byType(Scrollable)).first,
  );
  return scrollable;
}
