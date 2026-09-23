// Parity guard for beads cowork-b45 / cowork-al2: the SAME host `tool` frames
// must draw the SAME cards whether they arrive live (adapter → ledger → fold)
// or as a replay (loader → cached rows). This test feeds one scripted run
// through both paths and compares what the renderer gets.
//
// Compared: count, order, name, arguments, status, result, and — because the
// host stamps every frame (docs/WIRE_CONTRACT.md, "Tool events and
// timestamps") — the call's own clock, `startedAt` / `completedAt`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/agents/agents_tool_call_handler.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

import '../../support/fake_relay_controller.dart';

/// The fields of a card the reader can see: everything the renderer reads
/// except the per-instance id.
Map<String, dynamic> _visible(Map<String, dynamic> call) => <String, dynamic>{
      'name': call['name'],
      'arguments': call['arguments'],
      'status': call['status'],
      'result': call['result'],
      'startedAt': call['startedAt'],
      'completedAt': call['completedAt'],
    };

/// The host's clock, as a current host sends it: unix seconds.
final DateTime _t0 = DateTime.fromMillisecondsSinceEpoch(1_757_040_000_000);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

/// One run: a command that worked, one that failed, a child agent.
final List<AgentsRelayInbound> _liveRun = <AgentsRelayInbound>[
  const AgentsRelayDelta('Let me look.'),
  AgentsRelayTool(
    'run_command',
    arguments: 'ls /tmp',
    argumentMap: const <String, dynamic>{'command': 'ls /tmp', 'timeout': 30},
    result: 'a\nb',
    detail: 'a\nb',
    exitCode: 0,
    callId: 'call_1',
    startedAt: _at(1),
    completedAt: _at(3),
  ),
  AgentsRelayTool(
    'run_command',
    arguments: 'ls /nope',
    argumentMap: const <String, dynamic>{'command': 'ls /nope'},
    result: 'No such file',
    detail: 'ls: /nope: No such file',
    exitCode: 2,
    failed: true,
    callId: 'call_2',
    startedAt: _at(4),
    completedAt: _at(5),
  ),
  const AgentsRelaySubagent(
    subagentId: 'sa_1',
    title: 'writer',
    state: 'succeeded',
    result: 'the summary',
  ),
  const AgentsRelayDelta(' Done.'),
  AgentsRelayDone(
    reason: 'finished',
    iterations: 3,
    runId: 'run-1',
    startedAt: _at(0),
    finishedAt: _at(26),
    firstMid: 1,
    lastMid: 6,
  ),
];

/// The same run as the host replays it: every frame marked, in row order,
/// closed by the persisted run terminal and the history-end marker.
final List<AgentsRelayInbound> _replayedRun = <AgentsRelayInbound>[
  const AgentsRelayUser('do the thing', mid: 1),
  const AgentsRelayDelta('Let me look.', replay: true, mid: 2),
  AgentsRelayTool(
    'run_command',
    arguments: 'ls /tmp',
    argumentMap: const <String, dynamic>{'command': 'ls /tmp', 'timeout': 30},
    result: 'a\nb',
    detail: 'a\nb',
    exitCode: 0,
    callId: 'call_1',
    startedAt: _at(1),
    completedAt: _at(3),
    replay: true,
    mid: 2,
  ),
  AgentsRelayTool(
    'run_command',
    arguments: 'ls /nope',
    argumentMap: const <String, dynamic>{'command': 'ls /nope'},
    result: 'No such file',
    detail: 'ls: /nope: No such file',
    exitCode: 2,
    failed: true,
    callId: 'call_2',
    startedAt: _at(4),
    completedAt: _at(5),
    replay: true,
    mid: 4,
  ),
  const AgentsRelaySubagent(
    subagentId: 'sa_1',
    title: 'writer',
    state: 'succeeded',
    result: 'the summary',
    replay: true,
    mid: 5,
  ),
  const AgentsRelayDelta(' Done.', replay: true, mid: 6),
  AgentsRelayDone(
    reason: 'finished',
    iterations: 3,
    runId: 'run-1',
    replay: true,
    startedAt: _at(0),
    finishedAt: _at(26),
    firstMid: 1,
    lastMid: 6,
  ),
  const AgentsRelayDone(reason: 'replay', replay: true),
];

void main() {
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  const sessionKey = 'thread-1';
  late FakeRelayController controller;
  final loader = AgentsReplayLoader.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    loader.reset();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await ChatStorageService.reset();
    controller = FakeRelayController();
    AgentsRelayLink.instance.bind(controller);
    AgentsRelayLink.instance.sessionKey.value = sessionKey;
    loader.attach();
  });

  tearDown(() async {
    loader.reset();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await ChatStorageService.reset();
  });

  /// The live path, end to end: the adapter streams the run into the ledger,
  /// the fold hands the renderer its tool calls, as `onComplete` does.
  Future<List<ToolCall>> live(List<AgentsRelayInbound> events) async {
    final seen = <ChatStreamEvent>[];
    final sub = AgentsChatTransport.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
    ).listen(seen.add);
    await _drain();
    for (final event in events) {
      controller.emit(event);
      await _drain();
    }
    await sub.cancel();
    expect(seen.whereType<DoneEvent>(), hasLength(1));

    final handler = AgentsToolCallHandler.instance;
    final session = handler.createSession(
      initialUserMessage: 'do the thing',
      history: const <Map<String, dynamic>>[],
      accessToken: 'token',
      discoveryContextKey: sessionKey,
    );
    final result = await handler.processAssistantResponse(
      session: session,
      content: 'Let me look. Done.',
      reasoning: '',
    );
    return result.toolCalls;
  }

  /// The replay path, end to end: the loader folds the frames into the
  /// cached rows the imported screen paints from.
  Future<List<ToolCall>> replayed(List<AgentsRelayInbound> events) async {
    loader.expect(sessionKey);
    for (final event in events) {
      controller.emit(event);
    }
    await _drain();
    final chat = ChatStorageService.getChatById(sessionKey);
    expect(chat, isNotNull);
    expect(chat!.isFullyLoaded, isTrue);
    final row = chat.messages.last.toJson();
    expect(row['role'], 'ai');
    final raw = jsonDecode(row['toolCalls'] as String) as List<dynamic>;
    return raw
        .map((e) => ToolCall.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  test('the same run draws the same tool cards live and replayed', () async {
    final liveCalls = await live(_liveRun);
    final replayCalls = await replayed(_replayedRun);

    expect(liveCalls, hasLength(3));
    expect(replayCalls, hasLength(3));
    // The two command cards carry the host's clock: equal to the second.
    for (final i in <int>[0, 1]) {
      expect(_visible(replayCalls[i].toJson()), _visible(liveCalls[i].toJson()));
      expect(replayCalls[i].id, liveCalls[i].id, reason: 'call id is the host\'s');
    }
    // The child-agent row carries no host clock on the wire (bead cowork-266
    // persists its state, not its timestamps): everything but its clock must
    // still match.
    final liveChild = _visible(liveCalls[2].toJson())
      ..remove('startedAt')
      ..remove('completedAt');
    final replayChild = _visible(replayCalls[2].toJson())
      ..remove('startedAt')
      ..remove('completedAt');
    expect(replayChild, liveChild);
    // Order and status are what the reader sees at a glance.
    expect(
      replayCalls.map((c) => '${c.name}:${c.status.name}').toList(),
      <String>['run_command:completed', 'run_command:error', 'subagent:completed'],
    );
  });

  test('a failed command carries its exit code on both paths', () async {
    final liveCalls = await live(_liveRun);
    final replayCalls = await replayed(_replayedRun);

    expect(liveCalls[1].arguments['exit_code'], 2);
    expect(replayCalls[1].arguments['exit_code'], 2);
    expect(liveCalls[1].result, replayCalls[1].result);
  });

  test('a replayed answer row carries what the live one carries', () async {
    await live(_liveRun);
    await replayed(_replayedRun);

    final chat = ChatStorageService.getChatById(sessionKey)!;
    final row = chat.messages.last.toJson();
    // The same flat shape the imported screen writes after a live turn:
    // text, reasoning, toolCalls — and no content blocks without a file.
    expect(row['text'], 'Let me look. Done.');
    expect(row.containsKey('toolCalls'), isTrue);
    expect(row['contentBlocks'], isNull);
    // "Worked for 26s": the run's length from the host, on the answer row —
    // and no `startedAt`, which the imported persistence handler would use
    // to re-stamp the row on every save.
    expect(row['generationMs'], '26000');
    expect(row['startedAt'], isNull);
  });

  test('a live done moves the replay cursor past the run', () async {
    await live(_liveRun);
    expect(loader.cursorFor(sessionKey), 6);
  });

  test('the live ledger keeps the host clock for the run', () async {
    final seen = <ChatStreamEvent>[];
    final sub = AgentsChatTransport.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
    ).listen(seen.add);
    await _drain();
    for (final event in _liveRun) {
      controller.emit(event);
      await _drain();
    }
    await sub.cancel();
    final run = AgentsRunLedger.instance.runFor(sessionKey)!;
    expect(run.workedFor, const Duration(seconds: 26));
    expect(run.firstMid, 1);
    expect(run.lastMid, 6);
  });
}

Future<void> _drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
