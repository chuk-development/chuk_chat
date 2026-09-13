import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';

import '../support/fake_relay_controller.dart';

/// Every inbound variant the relay can produce, so the "never a ToolCallsEvent"
/// invariant is asserted against the whole surface and not a lucky subset.
List<AgentsRelayInbound> _everyVariant() => <AgentsRelayInbound>[
  const AgentsRelayDelta('hello'),
  const AgentsRelayDelta('history', replay: true, mid: 4),
  const AgentsRelayUser('what the user asked', mid: 3),
  const AgentsRelayReasoning('thinking'),
  const AgentsRelayReasoning('old thinking', replay: true, mid: 4),
  const AgentsRelayTool('run_command', arguments: 'ls', exitCode: 0),
  const AgentsRelayTool('run_command', replay: true, mid: 5),
  AgentsRelayFile(
    name: 'report.csv',
    mimeType: 'text/csv',
    declaredSize: 3,
    bytes: Uint8List.fromList(<int>[1, 2, 3]),
  ),
  const AgentsRelaySubagent(
    subagentId: 'sa_1',
    title: 'writer',
    state: 'succeeded',
    result: 'ok',
  ),
  const AgentsRelayApprovalRequest(
    approvalId: 'ap-1',
    action: 'herenow_publish',
    path: 'site',
    name: 'My Page',
    fileCount: 1,
    totalBytes: 10,
    baseUrl: 'https://here.now',
    public: true,
  ),
  const AgentsRelayRunState(sessionKey: 'thread-1', state: 'idle'),
  const AgentsRelayDebugContext(
    sessionKey: 'thread-1',
    payload: <String, dynamic>{'messages': <dynamic>[]},
  ),
  const AgentsRelayRoomTurn(
    roomId: 'r1',
    round: 1,
    agentId: 'a1',
    handle: 'ann',
    text: 'hi',
  ),
  const AgentsRelayRoomDone(roomId: 'r1', reason: 'stopped'),
  const AgentsRelayRoomHistory(roomId: 'r1', turns: <AgentsRelayRoomTurn>[]),
  const AgentsRelayBrowserView(status: 'started'),
  const AgentsRelayDone(reason: 'replay', replay: true),
  const AgentsRelayDone(reason: 'finished', iterations: 2, tokensSpent: 7),
];

void main() {
  const sessionKey = 'thread-1';
  late FakeRelayController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    controller = FakeRelayController();
    AgentsRelayLink.instance.bind(controller);
    AgentsRelayLink.instance.sessionKey.value = sessionKey;
  });

  tearDown(() async {
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await VerboseService.instance.setEnabled(false);
  });

  /// Starts a run, feeds [events], and returns everything the adapter yielded.
  Future<List<ChatStreamEvent>> run(
    List<AgentsRelayInbound> events, {
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
    await run(const <AgentsRelayInbound>[AgentsRelayDone(reason: 'finished')]);

    expect(controller.tasks, <String>['do the thing']);
    expect(controller.taskSessionKeys, <String>[sessionKey]);
    expect(controller.taskModelIds, <String?>['gpt-5']);
    expect(controller.taskProviderSlugs, <String?>['openai']);
    expect(controller.taskReasoning, <String?>['low']);
    // Quiet by default: no debug echo is asked for.
    expect(controller.taskDebugFlags, <bool>[false]);
  });

  test(
    'task route isolates two chats with the same model and different providers',
    () async {
      final store = ChatModelSelectionService.instance;
      await store.save(
        'a',
        const ChatModelSelection(
          modelId: 'same-model',
          providerSlug: 'provider-a',
        ),
      );
      await store.save(
        'b',
        const ChatModelSelection(
          modelId: 'same-model',
          providerSlug: 'provider-b',
        ),
      );
      await run(const [AgentsRelayDone(reason: 'finished')], chatId: 'a');
      await run(const [AgentsRelayDone(reason: 'finished')], chatId: 'b');
      expect(controller.taskSessionKeys, ['a', 'b']);
      expect(controller.taskModelIds, ['same-model', 'same-model']);
      expect(controller.taskProviderSlugs, ['provider-a', 'provider-b']);
    },
  );

  test('chat switch after send cannot redirect the captured request', () async {
    final store = ChatModelSelectionService.instance;
    await store.save(
      'a',
      const ChatModelSelection(modelId: 'model-a', providerSlug: 'provider-a'),
    );
    AgentsRelayLink.instance.sessionKey.value = 'a';
    final stream = WebSocketChatService.sendStreamingChat(
      accessToken: 'token',
      message: 'test',
      modelId: 'global',
      providerSlug: 'global',
    );
    AgentsRelayLink.instance.sessionKey.value = 'b';
    await store.save(
      'a',
      const ChatModelSelection(modelId: 'changed', providerSlug: 'changed'),
    );
    final sub = stream.listen((_) {});
    await _drain();
    expect(controller.taskSessionKeys, ['a']);
    expect(controller.taskModelIds, ['model-a']);
    expect(controller.taskProviderSlugs, ['provider-a']);
    controller.emit(const AgentsRelayDone(reason: 'finished'));
    await _drain();
    await sub.cancel();
  });

  test(
    'already captured mobile route survives changes during preprocessing',
    () async {
      await ChatModelSelectionService.instance.save(
        'a',
        const ChatModelSelection(
          modelId: 'new-choice',
          providerSlug: 'new-provider',
        ),
      );
      final stream = WebSocketChatService.sendStreamingChat(
        accessToken: 'token',
        message: 'test',
        chatId: 'a',
        modelId: 'captured-model',
        providerSlug: 'captured-provider',
        reasoningEffort: 'low',
        modelSelectionCaptured: true,
      );
      final sub = stream.listen((_) {});
      await _drain();
      expect(controller.taskModelIds, ['captured-model']);
      expect(controller.taskProviderSlugs, ['captured-provider']);
      expect(controller.taskReasoning, ['low']);
      controller.emit(const AgentsRelayDone(reason: 'finished'));
      await _drain();
      await sub.cancel();
    },
  );

  test('a null chatId falls back to the link session key', () async {
    AgentsRelayLink.instance.sessionKey.value = 'other-thread';
    await run(const <AgentsRelayInbound>[
      AgentsRelayDone(reason: 'finished'),
    ], chatId: null);
    expect(controller.taskSessionKeys, <String>['other-thread']);
  });

  test('deltas become content events', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayDelta('Hel'),
      AgentsRelayDelta('lo'),
      AgentsRelayDone(reason: 'finished'),
    ]);

    final content = seen.whereType<ContentEvent>().map((e) => e.text).toList();
    expect(content, <String>['Hel', 'lo']);
  });

  test(
    'terminal answer replaces a truncated streamed prefix before done',
    () async {
      const answer =
          'Spotify: [Search](https://open.spotify.com/search/song/tracks)\nShazam: complete';
      final seen = await run(const <AgentsRelayInbound>[
        AgentsRelayDelta(
          'Spotify: [Search](https://open.spotify.com/search/so',
        ),
        AgentsRelayDone(reason: 'finished', finalAnswer: answer),
      ]);
      expect(seen.whereType<FinalContentEvent>().single.text, answer);
      expect(
        seen.indexWhere((event) => event is FinalContentEvent),
        lessThan(seen.indexWhere((event) => event is DoneEvent)),
      );
    },
  );

  test('reasoning becomes a reasoning event and lands on the ledger', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayReasoning('I will read the log first'),
    ]);

    expect(
      seen.whereType<ReasoningEvent>().map((e) => e.text),
      contains('I will read the log first'),
    );
    expect(
      AgentsRunLedger.instance.runFor(sessionKey)!.modelReasoning,
      'I will read the log first',
    );
  });

  test(
    'reasoning streams chunk by chunk, in order, ahead of the answer',
    () async {
      // Bead cowork-0ia: the host streams the model's thinking as its own
      // `reasoning` frames; each one becomes a ReasoningEvent at once, so the
      // thinking block grows live like the answer text does.
      final seen = await run(const <AgentsRelayInbound>[
        AgentsRelayReasoning('let me '),
        AgentsRelayReasoning('think'),
        AgentsRelayDelta('answer'),
      ]);

      final ordered = seen
          .where((e) => e is ReasoningEvent || e is ContentEvent)
          .map(
            (e) => switch (e) {
              ReasoningEvent(:final text) => 'r:$text',
              ContentEvent(:final text) => 'c:$text',
              _ => '?',
            },
          )
          .toList();
      expect(ordered, <String>['r:let me ', 'r:think', 'c:answer']);
      expect(
        AgentsRunLedger.instance.runFor(sessionKey)!.modelReasoning,
        'let me think',
      );
    },
  );

  test('a replayed reasoning frame never enters a live run', () async {
    // The replay loader owns history. Yesterday's thinking must not land in
    // today's thinking block, exactly like a replayed delta.
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayReasoning('yesterday', replay: true, mid: 9),
      AgentsRelayReasoning('today'),
    ]);

    expect(
      seen.whereType<ReasoningEvent>().map((e) => e.text).toList(),
      <String>['today'],
    );
    expect(
      AgentsRunLedger.instance.runFor(sessionKey)!.modelReasoning,
      'today',
    );
  });

  test(
    'a tool is silent in the quiet view and recorded on the ledger',
    () async {
      final seen = await run(const <AgentsRelayInbound>[
        AgentsRelayTool(
          'run_command',
          arguments: 'ls /nope',
          result: 'No such file',
          exitCode: 2,
          failed: true,
        ),
      ]);

      // Quiet by default: the process detail never reaches the transcript.
      expect(seen.whereType<ReasoningEvent>(), isEmpty);

      final calls = AgentsRunLedger.instance.runFor(sessionKey)!.toolCalls;
      expect(calls, hasLength(1));
      expect(calls.single.name, 'run_command');
      expect(calls.single.status, ToolCallStatus.error);
      expect(calls.single.arguments['command'], 'ls /nope');
      expect(calls.single.arguments['exit_code'], 2);
    },
  );

  test('the full-log view narrates a tool on the reasoning channel', () async {
    await VerboseService.instance.setEnabled(true);
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayTool('run_command', arguments: 'ls', exitCode: 0),
    ]);

    final lines = seen.whereType<ReasoningEvent>().map((e) => e.text).toList();
    expect(lines, <String>['▸ run_command: ls\n', ' ✓ exit 0\n']);
    // And the verbose send asks the executor to echo the model context.
    expect(controller.taskDebugFlags, <bool>[true]);
  });

  test(
    'a file writes bytes to the blob store before its block exists',
    () async {
      final seen = await run(<AgentsRelayInbound>[
        AgentsRelayFile(
          name: 'report.csv',
          mimeType: 'text/csv',
          declaredSize: 3,
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      ]);

      // A file is never a stream event: it is a block on the finished turn.
      expect(seen, isEmpty);
      final blocks = AgentsRunLedger.instance.runFor(sessionKey)!.blocks;
      expect(blocks, hasLength(1));
      expect(blocks.single.sandboxArtifact!.filename, 'report.csv');
    },
  );

  test('a subagent and an approval are ledger-only', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelaySubagent(
        subagentId: 'sa_1',
        title: 'writer',
        state: 'succeeded',
        result: 'the summary',
      ),
      AgentsRelayApprovalRequest(
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
    final calls = AgentsRunLedger.instance.runFor(sessionKey)!.toolCalls;
    expect(calls.map((c) => c.name), <String>['subagent', 'ask_user']);
    expect(calls.last.arguments['options'], <String>['Publish', 'Deny']);
    expect(calls.last.arguments['approvalId'], 'ap-1');
  });

  test('a run error is an error event followed by done', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayRunError('loop failed: ValueError'),
    ]);

    expect(seen, hasLength(2));
    final error = seen.first as ErrorEvent;
    expect(error.message, 'loop failed: ValueError');
    expect(error.code, StreamErrorCodes.streamFailure);
    expect(seen.last, isA<DoneEvent>());
  });

  test('a live done is meta, usage, canonical answer, done', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayDone(
        finalAnswer: 'all set',
        reason: 'finished',
        iterations: 3,
        tokensSpent: 1234,
        runId: 'run-9',
      ),
    ]);

    expect(seen, hasLength(4));
    expect((seen[0] as MetaEvent).meta['stop_reason'], 'finished');
    expect((seen[0] as MetaEvent).meta['iterations'], 3);
    expect((seen[1] as UsageEvent).usage['total_tokens'], 1234);
    expect((seen[2] as FinalContentEvent).text, 'all set');
    expect(seen[3], isA<DoneEvent>());
    // The run_ack is the thread view's (one owner, review F14): the adapter
    // sends none. See agents_thread_view_test "a live done is acknowledged".
    expect(controller.ackedRunIds, isEmpty);
    expect(AgentsRunLedger.instance.runFor(sessionKey)!.finalAnswer, 'all set');
    expect(AgentsRunLedger.instance.isRunning(sessionKey), isFalse);
  });

  test('replayed frames and user turns never enter a live run', () async {
    final seen = await run(<AgentsRelayInbound>[
      const AgentsRelayDelta('yesterday', replay: true, mid: 1),
      const AgentsRelayUser('what I asked yesterday', mid: 2),
      const AgentsRelayTool('run_command', replay: true, mid: 3),
      // The three event kinds bead cowork-266 gave a replay flag (review F3):
      // yesterday's child agent, file and approval stay out of today's turn.
      const AgentsRelaySubagent(
        subagentId: 'sa_old',
        title: 'old writer',
        state: 'succeeded',
        result: 'done',
        replay: true,
        mid: 4,
      ),
      AgentsRelayFile(
        name: 'old.csv',
        mimeType: 'text/csv',
        declaredSize: 3,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        replay: true,
        mid: 5,
      ),
      const AgentsRelayApprovalRequest(
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
      const AgentsRelayDone(reason: 'replay', replay: true),
      const AgentsRelayDone(reason: 'finished', replay: true, whileAway: true),
      const AgentsRelayDelta('today'),
    ]);

    expect(seen.whereType<ContentEvent>().map((e) => e.text), <String>[
      'today',
    ]);
    expect(AgentsRunLedger.instance.runFor(sessionKey)!.toolCalls, isEmpty);
    expect(AgentsRunLedger.instance.runFor(sessionKey)!.blocks, isEmpty);
    // A replayed terminal is not this run's terminal.
    expect(AgentsRunLedger.instance.isRunning(sessionKey), isTrue);
  });

  test('no inbound variant ever produces a ToolCallsEvent', () async {
    final seen = await run(_everyVariant());
    expect(seen.whereType<ToolCallsEvent>(), isEmpty);
  });

  /// A live run, listened to, one token in. The caller then decides how the
  /// subscription goes away.
  Future<StreamSubscription<ChatStreamEvent>> openRun() async {
    final stream = WebSocketChatService.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
    );
    final sub = stream.listen((_) {});
    await _drain();
    controller.emit(const AgentsRelayDelta('half an answ'));
    await _drain();
    return sub;
  }

  // A subscription is cancelled for many reasons that are not the user: the
  // chat page is disposed by a rebuild, the reader leaves the thread, the app
  // goes to the background, the manager replaces one stream with the next.
  // Inferring a stop from any of them killed live runs on the executor — run
  // d1d4ede1, `reason: interrupted`, no answer, nobody having pressed anything
  // (bead cowork-gnr8). The host's rule is the opposite: a controller that
  // disconnects leaves its runs going and the results wait in the store.
  test('a cancelled subscription does NOT stop the host run', () async {
    final sub = await openRun();
    await sub.cancel();
    await _drain();

    expect(controller.stopCalls, 0);
    expect(controller.stopSessionKeys, isEmpty);
  });

  test('the user pressing Stop sends exactly one stop frame', () async {
    final sub = await openRun();
    // What the composer's stop target declares before it cancels.
    WebSocketChatService.declareStopIntent(sessionKey);
    await sub.cancel();
    await _drain();

    expect(controller.stopCalls, 1);
    expect(controller.stopSessionKeys, <String>[sessionKey]);
    expect(WebSocketChatService.hasStopIntent(sessionKey), isFalse);
  });

  test('a withdrawn intent is a page teardown, not a stop', () async {
    final sub = await openRun();
    // The chat screen's dispose: it cancels its stream and then disposes the
    // streaming handler in the same synchronous block.
    WebSocketChatService.declareStopIntent(sessionKey);
    final cancelled = sub.cancel();
    WebSocketChatService.withdrawStopIntent();
    await cancelled;
    await _drain();

    expect(controller.stopCalls, 0);
  });

  test('a stop declared for another thread never stops this one', () async {
    final sub = await openRun();
    WebSocketChatService.declareStopIntent('some-other-thread');
    await sub.cancel();
    await _drain();

    expect(controller.stopCalls, 0);
    WebSocketChatService.withdrawStopIntent();
  });

  test('a run that finished on its own is never stopped', () async {
    await run(const <AgentsRelayInbound>[AgentsRelayDone(reason: 'finished')]);
    expect(controller.stopCalls, 0);
  });

  test('no transport at all is a clean error, not a hang', () async {
    AgentsRelayLink.instance.unbind();
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

  group('a prompt the host could not take', () {
    late Map<String, String> disk;
    late Map<String, List<Map<String, dynamic>>> transcript;

    setUp(() {
      disk = <String, String>{};
      AgentsTaskOutbox.resetForTest();
      AgentsTaskOutbox.read = (key) async => disk[key];
      AgentsTaskOutbox.write = (key, value) async => disk[key] = value;
      AgentsTaskOutbox.delete = (key) async => disk.remove(key);
      transcript = <String, List<Map<String, dynamic>>>{
        sessionKey: <Map<String, dynamic>>[
          <String, dynamic>{'sender': 'user', 'text': 'do the thing'},
        ],
      };
      AgentsQueuedMarks.readRows = (key) => transcript[key];
      AgentsQueuedMarks.writeRows = (key, rows) async => transcript[key] = rows;
    });

    tearDown(() {
      AgentsTaskOutbox.read = null;
      AgentsTaskOutbox.write = null;
      AgentsTaskOutbox.delete = null;
      AgentsQueuedMarks.readRows = null;
      AgentsQueuedMarks.writeRows = null;
    });

    Future<void> sendWithNoHost() async {
      AgentsRelayLink.instance.unbind();
      final sub = WebSocketChatService.sendStreamingChat(
        accessToken: 'token',
        message: 'do the thing',
        modelId: 'gpt-5',
        providerSlug: 'openai',
        chatId: sessionKey,
        reasoningEffort: 'low',
      ).listen((_) {});
      await _drain();
      await sub.cancel();
      await _drain();
    }

    test('waits in the outbox', () async {
      await sendWithNoHost();
      final pending = await AgentsTaskOutbox.pendingFor(sessionKey);
      expect(pending.single.prompt, 'do the thing');
      expect(pending.single.reasoningEffort, 'low');
    });

    test('is marked failed on screen, with the real queue id', () async {
      await sendWithNoHost();
      final pending = await AgentsTaskOutbox.pendingFor(sessionKey);
      final row = transcript[sessionKey]!.single;
      // `failed`, not `pending`: the imported bubble offers Retry only for
      // `failed` (widgets/message_bubble/chrome.dart, imported).
      expect(row['status'], 'failed');
      expect(row['queueId'], pending.single.localId);
      expect(row['queueId'], isNotEmpty);
    });
  });
}

/// Lets the adapter's internal handler chain settle.
Future<void> _drain() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
