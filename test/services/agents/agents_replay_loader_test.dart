import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/image_storage_service.dart';

import '../../support/fake_relay_controller.dart';

void main() {
  // Agents delivers files as file blocks; decode them as the Agents build
  // does (the default follows FEATURE_AGENTS, which tests leave off).
  ContentBlock.decodesFileBlocks = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  const sessionKey = 'thread-1';
  final loader = AgentsReplayLoader.instance;
  late FakeRelayController controller;

  setUp(() async {
    // The one-time repeat repair (bead cowork-4rpt) is a migration, not
    // the steady state these tests describe: mark it done.
    SharedPreferences.setMockInitialValues(<String, Object>{
      kReplayRepeatRepairKey: true,
    });
    loader.reset();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    // Hermetic: replayed file bytes land in the local blob store, never
    // Supabase.
    AgentsRunLedger.storeFileBytes = ImageStorageService.uploadLocalBlob;
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
    AgentsRunLedger.storeFileBytes = ImageStorageService.uploadEncryptedImage;
    await ChatStorageService.reset();
  });

  Future<void> replay(
    List<AgentsRelayInbound> events, {
    String session = sessionKey,
    int afterId = 0,
  }) async {
    loader.expect(session, afterId: afterId);
    for (final event in events) {
      controller.emit(event);
    }
    await _drain();
  }

  List<Map<String, dynamic>> rowsFor(String session) {
    final chat = ChatStorageService.getChatById(session);
    if (chat == null || !chat.isFullyLoaded) return const [];
    return chat.messages.map((m) => m.toJson()).toList();
  }

  test('a scripted replay becomes user and assistant rows', () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayRunState(sessionKey: sessionKey, state: 'idle'),
      AgentsRelayUser('do the thing', mid: 1),
      AgentsRelayDelta('all ', replay: true, mid: 2),
      AgentsRelayDelta('set', replay: true, mid: 3),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final rows = rowsFor(sessionKey);
    expect(rows, hasLength(2));
    expect(rows[0]['role'], 'user');
    expect(rows[0]['text'], 'do the thing');
    expect(rows[1]['role'], 'ai');
    expect(rows[1]['text'], 'all set');
    expect(rows.every((row) => row['sentAt'] == null), isTrue);
  });

  test('replay preserves real host timestamps independently of run duration', () async {
    final userTime = DateTime.utc(2026, 9, 8, 12, 30);
    final answerTime = userTime.add(const Duration(seconds: 5));
    await replay(<AgentsRelayInbound>[
      AgentsRelayUser('hello', mid: 1, sentAt: userTime),
      AgentsRelayReasoning('checking', mid: 2, replay: true, sentAt: answerTime),
      AgentsRelayDelta('hi', mid: 2, replay: true, sentAt: answerTime),
      const AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    final rows = rowsFor(sessionKey);
    expect(rows[0]['sentAt'], userTime.toIso8601String());
    expect(rows[1]['sentAt'], answerTime.toIso8601String());
    expect(rows[1]['startedAt'], isNull);
    expect(rows[1]['generationMs'], isNull);
  });

  test('a replayed tool lands as a completed tool call on the answer',
      () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('do the thing', mid: 1),
      AgentsRelayDelta('working', replay: true, mid: 2),
      AgentsRelayTool(
        'run_command',
        arguments: 'ls /nope',
        result: 'No such file',
        detail: 'ls: /nope: No such file',
        exitCode: 2,
        failed: true,
        replay: true,
        mid: 3,
      ),
      AgentsRelaySubagent(
        subagentId: 'sa_1',
        title: 'writer',
        state: 'succeeded',
        result: 'the summary',
        replay: true,
        mid: 4,
      ),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final rows = rowsFor(sessionKey);
    final calls = jsonDecode(rows.last['toolCalls'] as String) as List<dynamic>;
    expect(calls, hasLength(2));
    expect((calls[0] as Map)['name'], 'run_command');
    expect((calls[0] as Map)['status'], 'error');
    expect((calls[1] as Map)['name'], 'subagent');
    expect((calls[1] as Map)['status'], 'completed');
  });

  test('a replayed file becomes a sandbox artifact block', () async {
    await replay(<AgentsRelayInbound>[
      const AgentsRelayUser('make me a csv', mid: 1),
      const AgentsRelayDelta('here you go', replay: true, mid: 2),
      AgentsRelayFile(
        name: 'report.csv',
        mimeType: 'text/csv',
        declaredSize: 3,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        replay: true,
        mid: 3,
      ),
      const AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final rows = rowsFor(sessionKey);
    final blocks = (jsonDecode(rows.last['contentBlocks'] as String) as List)
        .map((b) => ContentBlock.fromJson(Map<String, dynamic>.from(b as Map)))
        .toList();
    // The answer text has to survive alongside the artifact, or a row that
    // renders as blocks would lose it.
    expect(blocks.map((b) => b.type), <ContentBlockType>[
      ContentBlockType.text,
      ContentBlockType.sandboxArtifact,
    ]);
    expect(blocks.last.sandboxArtifact!.filename, 'report.csv');
    expect(blocks.last.sandboxArtifact!.storagePath, startsWith('cowork://blob/'));
    // The file row moved the cursor (docs/WIRE_CONTRACT.md, cowork-266).
    expect(loader.cursorFor(sessionKey), 3);
  });

  // --- persisted subagent / file / approval events (bead cowork-266) --------

  List<ToolCall> toolCallsOf(Map<String, dynamic> row) =>
      (jsonDecode(row['toolCalls'] as String) as List)
          .map((c) => ToolCall.fromJson(Map<String, dynamic>.from(c as Map)))
          .toList();

  test('a LIVE file or child agent is left to the ledger', () async {
    await replay(<AgentsRelayInbound>[
      const AgentsRelayUser('go', mid: 1),
      const AgentsRelayDelta('done', replay: true, mid: 2),
      AgentsRelayFile(
        name: 'live.csv',
        mimeType: 'text/csv',
        declaredSize: 1,
        bytes: Uint8List.fromList(<int>[1]),
      ),
      const AgentsRelaySubagent(subagentId: 'sa_live', title: 't', state: 'running'),
      const AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final row = rowsFor(sessionKey).last;
    expect(row['contentBlocks'] ?? '', isNot(contains('live.csv')));
    expect(row['toolCalls'] ?? '', isNot(contains('sa_live')));
  });

  test('replayed child-agent states fold into one card, last state wins',
      () async {
    await replay(<AgentsRelayInbound>[
      const AgentsRelayUser('research it', mid: 1),
      const AgentsRelayDelta('on it', replay: true, mid: 2),
      const AgentsRelaySubagent(
        subagentId: 'sa_1', title: 'reader', state: 'queued', replay: true, mid: 3,
      ),
      const AgentsRelaySubagent(
        subagentId: 'sa_1', title: 'reader', state: 'running', replay: true, mid: 4,
      ),
      const AgentsRelaySubagent(
        subagentId: 'sa_1',
        title: 'reader',
        state: 'succeeded',
        result: 'found it',
        replay: true,
        mid: 5,
      ),
      const AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final calls = toolCallsOf(rowsFor(sessionKey).last);
    expect(calls, hasLength(1));
    expect(calls.single.name, 'subagent');
    expect(calls.single.arguments['subagent_id'], 'sa_1');
    expect(calls.single.arguments['state'], 'succeeded');
    expect(calls.single.status, ToolCallStatus.completed);
    expect(calls.single.result, 'found it');
    expect(loader.cursorFor(sessionKey), 5);
  });

  test('a replayed, decided approval is a card with nothing to press',
      () async {
    await replay(<AgentsRelayInbound>[
      const AgentsRelayUser('publish it', mid: 1),
      const AgentsRelayApprovalRequest(
        approvalId: 'ap1',
        action: 'herenow_publish',
        path: 'site',
        name: 'My site',
        fileCount: 2,
        totalBytes: 10,
        baseUrl: 'here.now',
        public: true,
        replay: true,
        mid: 2,
        decision: 'approved',
        decisionReason: 'user',
      ),
      const AgentsRelayDelta('published', replay: true, mid: 3),
      const AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final calls = toolCallsOf(rowsFor(sessionKey).last);
    expect(calls.single.name, 'ask_user');
    expect(calls.single.arguments.containsKey('options'), isFalse,
        reason: 'no options under the key the AskUserCard reads');
    expect(calls.single.arguments['offered_options'], ['Publish', 'Deny']);
    expect(calls.single.arguments['decision'], 'Publish');
    expect(calls.single.arguments['decision_reason'], 'user');
    expect(calls.single.arguments['approvalId'], 'ap1');
  });

  test('a replayed open approval on a run still in flight is drawn as live',
      () async {
    await replay(<AgentsRelayInbound>[
      const AgentsRelayRunState(sessionKey: sessionKey, state: 'running', runId: 'r1'),
      const AgentsRelayUser('publish it', mid: 1),
      const AgentsRelayApprovalRequest(
        approvalId: 'ap1',
        action: 'herenow_publish',
        path: 'site',
        name: 'My site',
        fileCount: 2,
        totalBytes: 10,
        baseUrl: 'here.now',
        public: true,
        replay: true,
        mid: 2,
      ),
      const AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final calls = toolCallsOf(rowsFor(sessionKey).last);
    expect(calls.single.arguments['options'], ['Publish', 'Deny']);
    expect(calls.single.arguments.containsKey('decision'), isFalse);
  });

  test('a replayed open approval on an idle run is history, not a prompt',
      () async {
    await replay(<AgentsRelayInbound>[
      const AgentsRelayRunState(sessionKey: sessionKey, state: 'idle'),
      const AgentsRelayUser('publish it', mid: 1),
      const AgentsRelayApprovalRequest(
        approvalId: 'ap1',
        action: 'herenow_publish',
        path: 'site',
        name: 'My site',
        fileCount: 1,
        totalBytes: 1,
        baseUrl: 'here.now',
        public: true,
        replay: true,
        mid: 2,
      ),
      const AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final calls = toolCallsOf(rowsFor(sessionKey).last);
    expect(calls.single.arguments.containsKey('options'), isFalse);
    expect(calls.single.arguments['decision'], 'Expired');
  });

  test('a second full replay overwrites, it never duplicates', () async {
    const script = <AgentsRelayInbound>[
      AgentsRelayUser('do the thing', mid: 1),
      AgentsRelayDelta('all set', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ];
    await replay(script);
    expect(rowsFor(sessionKey), hasLength(2));
    final firstRevision = loader.revisionFor(sessionKey);

    await replay(script);
    expect(rowsFor(sessionKey), hasLength(2));
    expect(loader.revisionFor(sessionKey), firstRevision + 1);
  });

  test('the cursor advances and is persisted per session', () async {
    expect(loader.cursorFor(sessionKey), 0);
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('do the thing', mid: 4),
      AgentsRelayDelta('all set', replay: true, mid: 9),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    expect(loader.cursorFor(sessionKey), 9);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('$kReplayCursorPrefix$sessionKey'), 9);

    // A fresh loader state reads the cursor back off the store.
    loader.reset();
    await loader.load();
    expect(loader.cursorFor(sessionKey), 9);
  });

  test('pre-timestamp cursor re-fetches history without deleting its cache', () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('old message', mid: 1),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$kReplayTimestampCursorPrefix$sessionKey');
    loader.reset();
    await loader.load();
    expect(loader.cursorFor(sessionKey), 0);
    expect(rowsFor(sessionKey).single['text'], 'old message');
  });

  test('forgetting the cursor makes the next replay replace instead of append',
      () async {
    // A live turn is written locally by the UI, so the cursor still points
    // below it. Asking from there lets the host honour the cursor and the
    // loader appends the host's copy of the same turn underneath the local
    // one — the reported double bubble (bead cowork-bkw). Forgetting the
    // cursor turns the next replay into a full one, which replaces.
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('why', mid: 1),
      AgentsRelayDelta('because', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    expect(loader.cursorFor(sessionKey), 2);

    loader.invalidateCursor(sessionKey);
    expect(loader.cursorFor(sessionKey), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('$kReplayCursorPrefix$sessionKey'), 0);

    // The host now re-sends the whole thread. It must land as two rows, not
    // four.
    loader.attach();
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('why', mid: 1),
      AgentsRelayDelta('because', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final rows = rowsFor(sessionKey);
    expect(rows, hasLength(2));
    expect(rows.map((r) => r['text']), <String>['why', 'because']);
  });

  test('a cursor with no local thread is dropped and the thread replayed whole',
      () async {
    // The reported loss (bead cowork-izh): the cursor lives in preferences and
    // the transcript lives in the store, so a store that lost its threads
    // leaves a cursor pointing at rows nobody has. "Nothing after 106" then
    // looks like success, the thread stays empty, and the cursor keeps
    // advancing — so it is never asked for again although the host still has
    // every word.
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('yesterday', mid: 100),
      AgentsRelayDelta('an answer', replay: true, mid: 106),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    expect(loader.cursorFor(sessionKey), 106);

    // The store loses the thread; the cursor survives.
    await ChatStorageService.deleteChat(sessionKey);

    loader.attach();
    await replay(
      const <AgentsRelayInbound>[
        AgentsRelayDone(reason: 'replay', replay: true),
      ],
      afterId: 106,
    );

    expect(loader.cursorFor(sessionKey), 0);
    expect(loader.takeReplayWanted(sessionKey), isTrue);
  });

  test('an empty delta with the thread still cached leaves the cursor alone',
      () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('yesterday', mid: 100),
      AgentsRelayDelta('an answer', replay: true, mid: 106),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    loader.attach();
    await replay(
      const <AgentsRelayInbound>[
        AgentsRelayDone(reason: 'replay', replay: true),
      ],
      afterId: 106,
    );

    expect(loader.cursorFor(sessionKey), 106);
    expect(loader.takeReplayWanted(sessionKey), isFalse);
    expect(rowsFor(sessionKey), hasLength(2));
  });

  test('invalidating a cursor that was never set changes nothing', () async {
    loader.invalidateCursor('never-seen');
    expect(loader.cursorFor('never-seen'), 0);
  });

  test('a replayed thought lands in the row it belongs to', () async {
    // Reasoning used to be live-only, so a replayed answer came back without
    // the thinking block the live one had.
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('why', mid: 1),
      AgentsRelayReasoning('weighing it up', replay: true, mid: 2),
      AgentsRelayDelta('because', replay: true, mid: 3),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final rows = rowsFor(sessionKey);
    expect(rows, hasLength(2));
    expect(rows.last['reasoning'], 'weighing it up');
    expect(rows.last['text'], 'because');
  });

  test('a LIVE thought is left to the adapter', () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('why', mid: 1),
      AgentsRelayReasoning('live thinking'),
      AgentsRelayDelta('because', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    expect(rowsFor(sessionKey).last['reasoning'], isNot(contains('live')));
  });

  test('a delta replay above the cursor appends to what is cached', () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('first', mid: 1),
      AgentsRelayDelta('first answer', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    expect(rowsFor(sessionKey), hasLength(2));

    loader.attach();
    await replay(
      const <AgentsRelayInbound>[
        AgentsRelayUser('second', mid: 3),
        AgentsRelayDelta('second answer', replay: true, mid: 4),
        AgentsRelayDone(reason: 'replay', replay: true),
      ],
      afterId: 2,
    );

    final rows = rowsFor(sessionKey);
    expect(rows, hasLength(4));
    expect(rows.map((r) => r['text']), <String>[
      'first',
      'first answer',
      'second',
      'second answer',
    ]);
    expect(loader.cursorFor(sessionKey), 4);
  });

  test('a host that ignores the cursor replaces instead of duplicating',
      () async {
    const script = <AgentsRelayInbound>[
      AgentsRelayUser('first', mid: 1),
      AgentsRelayDelta('first answer', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ];
    await replay(script);
    // Asked with a cursor, answered with the whole history anyway (the old
    // executor). The lowest mid gives it away, so the cache is replaced.
    await replay(script, afterId: 2);

    expect(rowsFor(sessionKey), hasLength(2));
  });

  test('an empty delta replay leaves the cache alone', () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('first', mid: 1),
      AgentsRelayDelta('first answer', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    final revision = loader.revisionFor(sessionKey);

    await replay(
      const <AgentsRelayInbound>[AgentsRelayDone(reason: 'replay', replay: true)],
      afterId: 2,
    );

    expect(rowsFor(sessionKey), hasLength(2));
    expect(loader.revisionFor(sessionKey), revision);
  });

  test('a replayed run terminal closes the answer and marks it ready',
      () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('do the thing', mid: 1),
      AgentsRelayDelta('the answer', replay: true, mid: 2),
      AgentsRelayDone(
        reason: 'finished',
        replay: true,
        whileAway: true,
        runId: 'run-3',
      ),
      AgentsRelayUser('and again', mid: 3),
      AgentsRelayDelta('the second answer', replay: true, mid: 4),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    final rows = rowsFor(sessionKey);
    expect(rows.map((r) => r['text']), <String>[
      'do the thing',
      'the answer',
      'and again',
      'the second answer',
    ]);
    expect(loader.answerReadyFor(sessionKey), isTrue);
    // The waiting answer knows its run, so a second answer can be told from
    // a re-replay of this one (review F7).
    expect(loader.answerReadyRunFor(sessionKey), 'run-3');
    loader.clearAnswerReady(sessionKey);
    expect(loader.answerReadyFor(sessionKey), isFalse);
    expect(loader.answerReadyRunFor(sessionKey), isNull);
  });

  test('a running run_state is adopted so the thread shows Working', () async {
    controller.emit(
      const AgentsRelayRunState(
        sessionKey: sessionKey,
        state: 'running',
        runId: 'run-5',
        prompt: 'the thing it is busy with',
      ),
    );
    await _drain();

    expect(loader.hostRunning(sessionKey), isTrue);
    expect(loader.hostPrompt(sessionKey), 'the thing it is busy with');
    expect(AgentsRunLedger.instance.isRunning(sessionKey), isTrue);

    controller.emit(
      const AgentsRelayRunState(sessionKey: sessionKey, state: 'idle'),
    );
    await _drain();
    expect(loader.hostRunning(sessionKey), isFalse);
  });

  test('live frames are ignored: the loader only owns history', () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayDelta('a live token'),
      AgentsRelayTool('run_command', exitCode: 0),
      AgentsRelayReasoning('live thinking'),
      AgentsRelayDone(reason: 'finished', iterations: 1),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);

    expect(rowsFor(sessionKey), isEmpty);
  });

  test('the run_state header routes a replay to the session it names',
      () async {
    loader.expect('other-thread');
    controller.emit(
      const AgentsRelayRunState(sessionKey: 'other-thread', state: 'idle'),
    );
    controller.emit(const AgentsRelayUser('over there', mid: 1));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    await _drain();

    expect(rowsFor('other-thread'), hasLength(1));
    expect(rowsFor(sessionKey), isEmpty);
  });

  test('two overlapping replay requests land in their own threads (F1)',
      () async {
    // The first pairing asks for `default` and, one frame later, for the host
    // agent's thread. The host answers in order, each answer headed by its
    // run_state. The second request must not pull the tail of the first
    // answer into the second thread.
    loader.expect('default');
    controller.emit(
      const AgentsRelayRunState(sessionKey: 'default', state: 'idle'),
    );
    controller.emit(const AgentsRelayUser('first question', mid: 1));
    await _drain();
    // Second request while the first answer is still streaming.
    loader.expect('host:peer', afterId: 10);
    controller.emit(const AgentsRelayDelta('first answer', replay: true, mid: 2));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    // Now the host answers the second request.
    controller.emit(
      const AgentsRelayRunState(sessionKey: 'host:peer', state: 'idle'),
    );
    controller.emit(const AgentsRelayUser('other question', mid: 11));
    controller.emit(const AgentsRelayDelta('other answer', replay: true, mid: 12));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    await _drain();

    expect(rowsFor('default').map((r) => r['text']),
        <String>['first question', 'first answer']);
    expect(loader.cursorFor('default'), 2);
    // A delta (cursor honoured) onto a thread with no local rows is a cache
    // miss (F2), so the second thread is asked for again — but nothing of
    // `default` ever landed in it, and its cursor was not moved to 2.
    expect(rowsFor('host:peer'), isEmpty);
    expect(loader.cursorFor('host:peer'), 0);
    expect(loader.takeReplayWanted('host:peer'), isTrue);
  });

  test('a second request for the same thread queues behind the answer in '
      'flight (F1)', () async {
    loader.expect(sessionKey);
    controller.emit(
      const AgentsRelayRunState(sessionKey: sessionKey, state: 'idle'),
    );
    controller.emit(const AgentsRelayUser('q1', mid: 1));
    await _drain();
    // Asked again mid-stream: the first answer must still commit whole.
    loader.expect(sessionKey);
    controller.emit(const AgentsRelayDelta('a1', replay: true, mid: 2));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    await _drain();
    expect(rowsFor(sessionKey).map((r) => r['text']), <String>['q1', 'a1']);

    // The host answers the second request: a full replay replaces.
    controller.emit(
      const AgentsRelayRunState(sessionKey: sessionKey, state: 'idle'),
    );
    controller.emit(const AgentsRelayUser('q1', mid: 1));
    controller.emit(const AgentsRelayDelta('a1', replay: true, mid: 2));
    controller.emit(const AgentsRelayUser('q2', mid: 3));
    controller.emit(const AgentsRelayDelta('a2', replay: true, mid: 4));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    await _drain();
    expect(rowsFor(sessionKey).map((r) => r['text']),
        <String>['q1', 'a1', 'q2', 'a2']);
    expect(loader.cursorFor(sessionKey), 4);
  });

  test('a delta that finds no local rows forgets the cursor instead of '
      'truncating the thread (F2)', () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('first', mid: 1),
      AgentsRelayDelta('first answer', replay: true, mid: 2),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    expect(rowsFor(sessionKey), hasLength(2));
    expect(loader.cursorFor(sessionKey), 2);

    // The local copy becomes unreadable (a SQLite read that threw, a table
    // not migrated yet); the cursor still says 2.
    await ChatStorageService.reset();
    expect(rowsFor(sessionKey), isEmpty);

    loader.attach();
    await replay(
      const <AgentsRelayInbound>[
        AgentsRelayUser('second', mid: 3),
        AgentsRelayDelta('second answer', replay: true, mid: 4),
        AgentsRelayDone(reason: 'replay', replay: true),
      ],
      afterId: 2,
    );

    // Nothing was written over the thread, the cursor is gone, and the view
    // is told to ask for the whole thread again.
    expect(rowsFor(sessionKey), isEmpty);
    expect(loader.cursorFor(sessionKey), 0);
    expect(loader.takeReplayWanted(sessionKey), isTrue);
    expect(loader.takeReplayWanted(sessionKey), isFalse);
  });

  test('a LIVE user frame is ignored like every other live frame (F13)',
      () async {
    await replay(const <AgentsRelayInbound>[
      AgentsRelayUser('not history', replay: false),
      AgentsRelayUser('history', mid: 1),
      AgentsRelayDone(reason: 'replay', replay: true),
    ]);
    expect(rowsFor(sessionKey).map((r) => r['text']), <String>['history']);
  });
}

/// Lets the loader's internal handler chain settle.
Future<void> _drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
