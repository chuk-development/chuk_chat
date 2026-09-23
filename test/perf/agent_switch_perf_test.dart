// Speed test for switching between agents in the messenger shell.
//
// The owner reported "everything hangs". The live app spent 555-660 ms of UI
// isolate time on every agent switch. A switch remounts the imported chat
// screen (its key carries the thread key), so every switch pays for the whole
// screen again: the mount itself, the markdown of every visible message and
// the decode of every tool call.
//
// This test mounts the real `MessengerShell` with four agents. Each agent has
// one thread of 80 messages: markdown with headings, lists, tables and code,
// and tool calls on part of the answers. It then switches agents eight times
// and times each switch, from the tap to the first frame that shows the new
// thread. The numbers are wall clock on the test machine, so they are a shape,
// not a phone figure. The ceiling is generous: it catches a regression of
// several times, not a busy machine.
//
// The store's SQLite is replaced by a map, see `perf_support.dart`.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
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
import 'package:chuk_chat/services/storage/chat_origin.dart';

import '../support/fake_relay_controller.dart';
import '../support/icon_finder.dart';
import '../support/test_app.dart';
import 'perf_support.dart';

const Timeout _guard = Timeout(Duration(minutes: 5));

/// Messages per thread.
const int _messagesPerThread = 80;

/// Measured switches.
const int _switches = 24;

/// The median switch must stay under this. On the development machine the
/// median is 60-90 ms, before and after the caches alike: under `flutter test`
/// the frame is dominated by the framework mounting the screen, while the
/// costs the caches remove (catalogue decode, Supabase writes, decrypts) never
/// run here — `agent_switch_data_perf_test.dart` times those. This ceiling is a
/// guard against a switch that gets several times slower, not a target.
const double _switchCeilingMs = 350;

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

/// Marker words, one per agent, so the finder knows which thread is shown.
String _marker(int agent) => 'agentmark$agent';

String _answer(int agent, int i) {
  final marker = _marker(agent);
  switch (i % 4) {
    case 1:
      return '## Step $i for $marker\n\n'
          'The assistant explains **one** step of the plan, with `inline` '
          'code and a [link](https://example.com/$i).\n\n'
          '- first point of the step\n'
          '- second point, a bit longer than the first one\n'
          '  - a nested point\n'
          '1. ordered one\n'
          '2. ordered two\n';
    case 3:
      return '| Column | Value | Note |\n'
          '|---|---|---|\n'
          '| alpha | $i | first row of $marker |\n'
          '| beta | ${i * 2} | second row |\n'
          '| gamma | ${i * 3} | third row |\n\n'
          'After the table comes a paragraph that closes the answer.\n\n'
          '```dart\nvoid main() {\n  print("row $i");\n}\n```\n';
    default:
      return '$marker $i answer. ${"The assistant explains a step. " * 8}';
  }
}

String _toolCalls(int i) => jsonEncode(<Map<String, dynamic>>[
  for (int c = 0; c < 3; c++)
    <String, dynamic>{
      'id': 'call-$i-$c',
      'name': c.isEven ? 'shell' : 'read_file',
      'arguments': <String, dynamic>{
        'command': 'ls -la /home/user/project/$i/$c',
        'path': '/home/user/project/file_$c.dart',
      },
      'result': 'total 42\n${"drwxr-xr-x  2 user user 4096 file\n" * 6}',
      'status': 'completed',
      'startedAt': '2026-09-20T10:00:0$c.000Z',
      'completedAt': '2026-09-20T10:00:0${c + 1}.000Z',
    },
]);

List<Map<String, dynamic>> _transcript(int agent) => <Map<String, dynamic>>[
  for (int i = 0; i < _messagesPerThread; i++)
    if (i.isEven)
      <String, dynamic>{'sender': 'user', 'text': '${_marker(agent)} $i ask'}
    else
      <String, dynamic>{
        'sender': 'ai',
        'text': _answer(agent, i),
        if (i % 3 == 0) 'toolCalls': _toolCalls(i),
      },
];

void main() {
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);
  ChatOrigin.agentsEnabled = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDisk disk;

  Future<void> resetWorld() async {
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

  setUp(() async {
    await resetWorld();
    disk = FakeDisk();
  });

  tearDown(() async {
    await MultiplexSession.shutdown();
    await resetWorld();
  });

  testWidgets('switching between four agents with 80-message threads', (
    tester,
  ) async {
    silenceUnrelatedPlugins(tester);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final agents = <AgentsAgent>[
      for (int a = 0; a < 4; a++)
        AgentsAgent(
          id: a == 0 ? 'host:perf-host' : 'local:agent$a:$a:$a',
          name: 'Agent $a',
          onHost: a == 0,
          threads: <AgentsThreadInfo>[
            AgentsThreadInfo(
              key: a == 0 ? 'host:perf-host' : 'local:agent$a:$a:$a',
              title: 'General',
            ),
          ],
        ),
    ];

    await tester.runAsync(() async {
      disk.install();
      AgentsChatStore.userIdProvider = () => 'perf-user';
      for (int a = 0; a < agents.length; a++) {
        final key = agents[a].threads.single.key;
        await AgentsChatStore.replaceThread(key, _transcript(a));
        await AgentsChatStore.pending(key);
      }
      // What `AgentsChatStorageBootstrap._signedIn` writes on a session.
      await AgentsChatStore.rememberUser('perf-user');
      // The app was closed: memory is gone, the disk is left.
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
    // Open the sidebar that lists the agents, if it is folded.
    if (find.byKey(ValueKey<String>('agent-tile-${agents[1].id}')).evaluate()
        .isEmpty) {
      await tester.tap(findIcon(Icons.menu_rounded));
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Taps the agent, then pumps until its marker is on screen.
    Future<({double ms, int frames})> switchTo(int agent) async {
      final tile = find.byKey(
        ValueKey<String>('agent-tile-${agents[agent].id}'),
      );
      expect(tile, findsOneWidget, reason: 'agent $agent is not listed');
      final shown = find.textContaining(_marker(agent), findRichText: true);
      final watch = Stopwatch()..start();
      await tester.tap(tile);
      double? hit;
      int frames = 0;
      for (int i = 0; i < 40 && hit == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frames = i + 1;
        if (shown.evaluate().isNotEmpty) hit = watch.elapsedMicroseconds / 1000;
      }
      watch.stop();
      expect(hit, isNotNull, reason: 'agent $agent never showed its thread');
      // Let the post-frame work of the mount (model restore, prompt load)
      // finish off the clock, so it does not leak into the next switch.
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return (ms: hit!, frames: frames);
    }

    // Warm up: the first mounts pay for JIT compilation of the chat screen.
    for (int a = 1; a < agents.length; a++) {
      await switchTo(a);
    }
    await switchTo(0);

    final samples = <double>[];
    var frames = 0;
    for (int s = 0; s < _switches; s++) {
      final result = await switchTo((s % (agents.length - 1)) + 1);
      samples.add(result.ms);
      frames = result.frames;
    }

    final table = PerfTable('agent switch: tap -> first frame of the thread')
      ..add(
        'switch, 4 agents x $_messagesPerThread msgs',
        samples,
        note: '$frames frames to the thread',
      );
    table.report();
    // PERF_HOLD=1 keeps the isolate alive after the measurement, so a profiler
    // attached through `--start-paused` can read the CPU samples.
    if (const bool.fromEnvironment('PERF_HOLD')) {
      debugPrint('PERF_HOLD: measurement done');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 40)),
      );
    }

    await releaseIdleTimers(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    // Code highlighting waits on an isolate that a fake-async test never
    // runs; let its two-second timeout expire before the harness checks for
    // pending timers.
    await tester.pump(const Duration(seconds: 3));

    expect(
      median(samples),
      lessThan(_switchCeilingMs),
      reason:
          'an agent switch took ${median(samples).toStringAsFixed(1)} ms '
          '(median) — the switch got several times slower',
    );
  }, timeout: _guard);
}
