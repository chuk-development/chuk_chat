
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/models/chat_stream_event.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/settings/verbose_service.dart';
import 'package:cowork/services/websocket_chat_service.dart';

import '../support/fake_relay_controller.dart';

/// Every inbound variant the relay can produce, so the "never a ToolCallsEvent"
/// invariant is asserted against the whole surface and not a lucky subset.
List<CoworkRelayInbound> _everyVariant() => <CoworkRelayInbound>[
      const CoworkRelayDelta('hello'),
      const CoworkRelayDelta('history', replay: true, mid: 4),
      const CoworkRelayUser('what the user asked', mid: 3),
      const CoworkRelayReasoning('thinking'),
      const CoworkRelayReasoning('old thinking', replay: true, mid: 4),
      const CoworkRelayTool('run_command', arguments: 'ls', exitCode: 0),
      const CoworkRelayTool('run_command', replay: true, mid: 5),
      CoworkRelayFile(
        name: 'report.csv',
        mimeType: 'text/csv',
        declaredSize: 3,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      ),
      const CoworkRelaySubagent(
        subagentId: 'sa_1',
        title: 'writer',
        state: 'succeeded',
        result: 'ok',
      ),
      const CoworkRelayApprovalRequest(
        approvalId: 'ap-1',
        action: 'herenow_publish',
        path: 'site',
        name: 'My Page',
        fileCount: 1,
        totalBytes: 10,
        baseUrl: 'https://here.now',
        public: true,
      ),
      const CoworkRelayRunState(sessionKey: 'thread-1', state: 'idle'),
      const CoworkRelayDebugContext(
        sessionKey: 'thread-1',
        payload: <String, dynamic>{'messages': <dynamic>[]},
      ),
      const CoworkRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a1',
        handle: 'ann',
        text: 'hi',
      ),
      const CoworkRelayRoomDone(roomId: 'r1', reason: 'stopped'),
      const CoworkRelayRoomHistory(roomId: 'r1', turns: <CoworkRelayRoomTurn>[]),
      const CoworkRelayBrowserView(status: 'started'),
      const CoworkRelayDone(reason: 'replay', replay: true),
      const CoworkRelayDone(reason: 'finished', iterations: 2, tokensSpent: 7),
    ];

void main() {
  const sessionKey = 'thread-1';
  late FakeRelayController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
    controller = FakeRelayController();
    CoworkRelayLink.instance.bind(controller);
    CoworkRelayLink.instance.sessionKey.value = sessionKey;
  });

  tearDown(() async {
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
    await VerboseService.instance.setEnabled(false);
  });

  /// Starts a run, feeds [events], and returns everything the adapter yielded.
  Future<List<ChatStreamEvent>> run(
    List<CoworkRelayInbound> events, {
    String? chatId = sessionKey,
    bool cancelEarly = false,
  }) async {
    final seen = <ChatStreamEvent>[];
    final stream = WebSocketChatService.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: chatId,
      reasoningEffort: 'low',
      history: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'ignored'},
      ],
      systemPrompt: 'ignored',
      maxTokens: 4096,
      temperature: 0.1,
      tools: const <Map<String, dynamic>>[
        <String, dynamic>{'name': 'ignored'},
      ],
    );
    final sub = stream.listen(seen.add);
    await _drain();
    for (final event in events) {
      controller.emit(event);
      await _drain();
    }
    if (cancelEarly) {
      await sub.cancel();
    } else {
      await _drain();
      await sub.cancel();
    }
    return seen;
  }

  test('the task carries the session key and the composer settings', () async {
    await run(const <CoworkRelayInbound>[
      CoworkRelayDone(reason: 'finished'),
    ]);

    expect(controller.tasks, <String>['do the thing']);
    expect(controller.taskSessionKeys, <String>[sessionKey]);
    expect(controller.taskModelIds, <String?>['gpt-5']);
    expect(controller.taskProviderSlugs, <String?>['openai']);
    expect(controller.taskReasoning, <String?>['low']);
    // Quiet by default: no debug echo is asked for.
    expect(controller.taskDebugFlags, <bool>[false]);
  });

  test('a null chatId falls back to the link session key', () async {
    CoworkRelayLink.instance.sessionKey.value = 'other-thread';
    await run(
      const <CoworkRelayInbound>[CoworkRelayDone(reason: 'finished')],
      chatId: null,
    );
    expect(controller.taskSessionKeys, <String>['other-thread']);
  });

  test('deltas become content events', () async {
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayDelta('Hel'),
      CoworkRelayDelta('lo'),
      CoworkRelayDone(reason: 'finished'),
    ]);

    final content = seen.whereType<ContentEvent>().map((e) => e.text).toList();
    expect(content, <String>['Hel', 'lo']);
  });

  test('reasoning becomes a reasoning event and lands on the ledger', () async {
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayReasoning('I will read the log first'),
    ]);

    expect(
      seen.whereType<ReasoningEvent>().map((e) => e.text),
      contains('I will read the log first'),
    );
    expect(
      CoworkRunLedger.instance.runFor(sessionKey)!.modelReasoning,
      'I will read the log first',
    );
  });

  test('reasoning streams chunk by chunk, in order, ahead of the answer',
      () async {
    // Bead cowork-0ia: the host streams the model's thinking as its own
    // `reasoning` frames; each one becomes a ReasoningEvent at once, so the
    // thinking block grows live like the answer text does.
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayReasoning('let me '),
      CoworkRelayReasoning('think'),
      CoworkRelayDelta('answer'),
    ]);

    final ordered = seen
        .where((e) => e is ReasoningEvent || e is ContentEvent)
        .map((e) => switch (e) {
              ReasoningEvent(:final text) => 'r:$text',
              ContentEvent(:final text) => 'c:$text',
              _ => '?',
            })
        .toList();
    expect(ordered, <String>['r:let me ', 'r:think', 'c:answer']);
    expect(
      CoworkRunLedger.instance.runFor(sessionKey)!.modelReasoning,
      'let me think',
    );
  });

  test('a replayed reasoning frame never enters a live run', () async {
    // The replay loader owns history. Yesterday's thinking must not land in
    // today's thinking block, exactly like a replayed delta.
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayReasoning('yesterday', replay: true, mid: 9),
      CoworkRelayReasoning('today'),
    ]);

    expect(
      seen.whereType<ReasoningEvent>().map((e) => e.text).toList(),
      <String>['today'],
    );
    expect(CoworkRunLedger.instance.runFor(sessionKey)!.modelReasoning, 'today');
  });

  test('a tool is silent in the quiet view and recorded on the ledger',
      () async {
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayTool(
        'run_command',
        arguments: 'ls /nope',
        result: 'No such file',
        exitCode: 2,
        failed: true,
      ),
    ]);

    // Quiet by default: the process detail never reaches the transcript.
    expect(seen.whereType<ReasoningEvent>(), isEmpty);

    final calls = CoworkRunLedger.instance.runFor(sessionKey)!.toolCalls;
    expect(calls, hasLength(1));
    expect(calls.single.name, 'run_command');
    expect(calls.single.status, ToolCallStatus.error);
    expect(calls.single.arguments['command'], 'ls /nope');
    expect(calls.single.arguments['exit_code'], 2);
  });

  test('the full-log view narrates a tool on the reasoning channel', () async {
    await VerboseService.instance.setEnabled(true);
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayTool('run_command', arguments: 'ls', exitCode: 0),
    ]);

    final lines = seen.whereType<ReasoningEvent>().map((e) => e.text).toList();
    expect(lines, <String>['▸ run_command: ls\n', ' ✓ exit 0\n']);
    // And the verbose send asks the executor to echo the model context.
    expect(controller.taskDebugFlags, <bool>[true]);
  });

  test('a file writes bytes to the blob store before its block exists',
      () async {
    final seen = await run(<CoworkRelayInbound>[
      CoworkRelayFile(
        name: 'report.csv',
        mimeType: 'text/csv',
        declaredSize: 3,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    ]);

    // A file is never a stream event: it is a block on the finished turn.
    expect(seen, isEmpty);
    final blocks = CoworkRunLedger.instance.runFor(sessionKey)!.blocks;
    expect(blocks, hasLength(1));
    expect(blocks.single.sandboxArtifact!.filename, 'report.csv');
  });

  test('a subagent and an approval are ledger-only', () async {
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelaySubagent(
        subagentId: 'sa_1',
        title: 'writer',
        state: 'succeeded',
        result: 'the summary',
      ),
      CoworkRelayApprovalRequest(
        approvalId: 'ap-1',
        action: 'herenow_publish',
        path: 'site',
        name: 'My Page',
        fileCount: 2,
        totalBytes: 2048,
        baseUrl: 'https://here.now',
        public: true,
      ),
    ]);

    expect(seen, isEmpty);
    final calls = CoworkRunLedger.instance.runFor(sessionKey)!.toolCalls;
    expect(calls.map((c) => c.name), <String>['subagent', 'ask_user']);
    expect(calls.last.arguments['options'], <String>['Publish', 'Deny']);
    expect(calls.last.arguments['approvalId'], 'ap-1');
  });

  test('a run error is an error event followed by done', () async {
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayRunError('loop failed: ValueError'),
    ]);

    expect(seen, hasLength(2));
    final error = seen.first as ErrorEvent;
    expect(error.message, 'loop failed: ValueError');
    expect(error.code, StreamErrorCodes.streamFailure);
    expect(seen.last, isA<DoneEvent>());
  });

  test('a live done is meta, usage, done — and acks the run', () async {
    final seen = await run(const <CoworkRelayInbound>[
      CoworkRelayDone(
        finalAnswer: 'all set',
        reason: 'finished',
        iterations: 3,
        tokensSpent: 1234,
        runId: 'run-9',
      ),
    ]);

    expect(seen, hasLength(3));
    expect((seen[0] as MetaEvent).meta['stop_reason'], 'finished');
    expect((seen[0] as MetaEvent).meta['iterations'], 3);
    expect((seen[1] as UsageEvent).usage['total_tokens'], 1234);
    expect(seen[2], isA<DoneEvent>());
    // The run_ack is the thread view's (one owner, review F14): the adapter
    // sends none. See cowork_thread_view_test "a live done is acknowledged".
    expect(controller.ackedRunIds, isEmpty);
    expect(CoworkRunLedger.instance.runFor(sessionKey)!.finalAnswer, 'all set');
    expect(CoworkRunLedger.instance.isRunning(sessionKey), isFalse);
  });

  test('replayed frames and user turns never enter a live run', () async {
    final seen = await run(<CoworkRelayInbound>[
      const CoworkRelayDelta('yesterday', replay: true, mid: 1),
      const CoworkRelayUser('what I asked yesterday', mid: 2),
      const CoworkRelayTool('run_command', replay: true, mid: 3),
      // The three event kinds bead cowork-266 gave a replay flag (review F3):
      // yesterday's child agent, file and approval stay out of today's turn.
      const CoworkRelaySubagent(
        subagentId: 'sa_old',
        title: 'old writer',
        state: 'succeeded',
        result: 'done',
        replay: true,
        mid: 4,
      ),
      CoworkRelayFile(
        name: 'old.csv',
        mimeType: 'text/csv',
        declaredSize: 3,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        replay: true,
        mid: 5,
      ),
      const CoworkRelayApprovalRequest(
        approvalId: 'ap-old',
        action: 'herenow_publish',
        path: 'site',
        name: 'Old Page',
        fileCount: 1,
        totalBytes: 10,
        baseUrl: 'https://here.now',
        public: true,
        replay: true,
        mid: 6,
        decision: 'approved',
      ),
      const CoworkRelayDone(reason: 'replay', replay: true),
      const CoworkRelayDone(reason: 'finished', replay: true, whileAway: true),
      const CoworkRelayDelta('today'),
    ]);

    expect(seen.whereType<ContentEvent>().map((e) => e.text), <String>['today']);
    expect(CoworkRunLedger.instance.runFor(sessionKey)!.toolCalls, isEmpty);
    expect(CoworkRunLedger.instance.runFor(sessionKey)!.blocks, isEmpty);
    // A replayed terminal is not this run's terminal.
    expect(CoworkRunLedger.instance.isRunning(sessionKey), isTrue);
  });

  test('no inbound variant ever produces a ToolCallsEvent', () async {
    final seen = await run(_everyVariant());
    expect(seen.whereType<ToolCallsEvent>(), isEmpty);
  });

  test('cancelling the stream stops the run exactly once', () async {
    final seen = <ChatStreamEvent>[];
    final stream = WebSocketChatService.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
    );
    final sub = stream.listen(seen.add);
    await _drain();
    controller.emit(const CoworkRelayDelta('half an answ'));
    await _drain();

    await sub.cancel();
    await _drain();

    expect(controller.stopCalls, 1);
    expect(controller.stopSessionKeys, <String>[sessionKey]);
  });

  test('a run that finished on its own is never stopped', () async {
    await run(const <CoworkRelayInbound>[CoworkRelayDone(reason: 'finished')]);
    expect(controller.stopCalls, 0);
  });

  test('no transport at all is a clean error, not a hang', () async {
    CoworkRelayLink.instance.unbind();
    final seen = <ChatStreamEvent>[];
    final sub = WebSocketChatService.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
    ).listen(seen.add);
    await _drain();
    await sub.cancel();

    expect(seen.first, isA<ErrorEvent>());
    expect((seen.first as ErrorEvent).code, StreamErrorCodes.connectionLost);
    expect(seen.last, isA<DoneEvent>());
  });

  test('a send that never leaves reports it and closes the stream', () async {
    controller.taskError = StateError('Not paired');
    final seen = <ChatStreamEvent>[];
    final sub = WebSocketChatService.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
    ).listen(seen.add);
    await _drain();
    await sub.cancel();

    expect(seen.whereType<ErrorEvent>(), hasLength(1));
    expect(seen.last, isA<DoneEvent>());
    // The send failed, so there is nothing to stop.
    expect(controller.stopCalls, 0);
  });
}

/// Lets the adapter's internal handler chain settle.
Future<void> _drain() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
