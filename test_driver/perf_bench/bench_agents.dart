// Crawl of the Agents half: the real shell with a fake relay and a synthetic
// roster, so no host and no account is involved.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';

import '../../test/support/fake_relay_controller.dart';
import '../../test/support/test_app.dart';
import 'bench_crawler.dart';
import 'bench_fixture.dart';

class _Memory implements AgentsSecureKeyValueStore {
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
    accessToken: 'bench',
    refreshToken: 'bench',
    userId: 'bench-user',
  );

  @override
  Future<AccountSession?> refresh() async => current();
}

Future<void> crawlAgents(void Function(Map<String, Object?>) emit) async {
  const String key = 'host:bench';
  SharedPreferences.setMockInitialValues(<String, Object>{});
  AgentsChatStore.userIdProvider = () => 'bench-user';
  AgentsChatStore.keyLoader = () async => false;
  await AgentsChatStore.replaceThread(key, <Map<String, String>>[
    for (final Map<String, dynamic> m in benchMessages(60))
      <String, String>{
        'sender': m['role'] == 'user' ? 'user' : 'ai',
        'text': m['text'] as String,
      },
  ]);
  final FakeRelayController relay = FakeRelayController();
  runApp(
    testApp(
      MessengerShell(
        relayControllerBuilder: () async => relay,
        sessionSource: const _Session(),
        pairingStore: AgentsPairingStore(backend: _Memory()),
        rosterSource: LocalAgentRosterSource(
          seed: <AgentsAgent>[
            AgentsAgent(
              id: key,
              name: 'Agent',
              onHost: true,
              threads: const <AgentsThreadInfo>[
                AgentsThreadInfo(key: key, title: 'General'),
              ],
            ),
          ],
        ),
        appMode: AppModeService(),
        onSignOut: () {},
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 3));
  relay.set(
    const AgentsRelayState(
      phase: AgentsRelayPhase.paired,
      peerDeviceId: 'bench',
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 3));
  final Crawler c = Crawler(budget: const Duration(minutes: 20), emit: emit)
    ..start();
  await c.crawlHere(
    0,
    tag: 'agents inbox',
    rootBudget: const Duration(minutes: 12),
  );
  await c.report();
  emit(<String, Object?>{'done': true});
}
