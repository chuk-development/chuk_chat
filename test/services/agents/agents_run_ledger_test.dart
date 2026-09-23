import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

void main() {
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
  // Agents delivers files as file blocks; decode them as the Agents build
  // does (the default follows FEATURE_AGENTS, which tests leave off).
  ContentBlock.decodesFileBlocks = true;
  const sessionKey = 'thread-1';
  final ledger = AgentsRunLedger.instance;

  setUp(() {
    ledger.reset();
    ImageStorageService.clearCache();
  });

  test('a scripted run folds into the tool calls the renderer draws', () {
    ledger.begin(sessionKey);
    ledger
      ..openTool(sessionKey, 'run_command', arguments: 'ls /tmp')
      ..closeTool(
        sessionKey,
        'run_command',
        result: 'a\nb',
        exitCode: 0,
        duration: const Duration(milliseconds: 250),
      )
      ..openTool(sessionKey, 'run_command', arguments: 'ls /nope')
      ..closeTool(
        sessionKey,
        'run_command',
        result: 'No such file',
        exitCode: 2,
        failed: true,
      );

    final calls = ledger.runFor(sessionKey)!.toolCalls;
    expect(calls, hasLength(2));
    expect(calls[0].status, ToolCallStatus.completed);
    expect(calls[0].arguments['command'], 'ls /tmp');
    expect(calls[0].result, 'a\nb');
    expect(calls[0].elapsed, const Duration(milliseconds: 250));
    expect(calls[1].status, ToolCallStatus.error);
    expect(calls[1].arguments['exit_code'], 2);
  });

  test('a close with no matching open still records the call', () {
    ledger.begin(sessionKey);
    ledger.closeTool(sessionKey, 'search', result: 'nothing', exitCode: 0);

    final calls = ledger.runFor(sessionKey)!.toolCalls;
    expect(calls, hasLength(1));
    expect(calls.single.status, ToolCallStatus.completed);
  });

  test('a subagent updates its own line instead of stacking', () {
    ledger.begin(sessionKey);
    ledger.subagent(
      sessionKey,
      subagentId: 'sa_1',
      title: 'writer',
      state: 'running',
    );
    ledger.subagent(
      sessionKey,
      subagentId: 'sa_2',
      title: 'checker',
      state: 'running',
    );
    ledger.subagent(
      sessionKey,
      subagentId: 'sa_1',
      title: 'writer',
      state: 'succeeded',
      result: 'the summary',
    );

    final calls = ledger.runFor(sessionKey)!.toolCalls;
    expect(calls, hasLength(2));
    expect(calls[0].name, 'subagent');
    expect(calls[0].arguments['state'], 'succeeded');
    expect(calls[0].status, ToolCallStatus.completed);
    expect(calls[0].result, 'the summary');
    expect(calls[1].arguments['state'], 'running');
    expect(calls[1].status, ToolCallStatus.running);
  });

  test('a failed subagent is an error line carrying its error', () {
    ledger.begin(sessionKey);
    ledger.subagent(
      sessionKey,
      subagentId: 'sa_1',
      title: 'writer',
      state: 'failed',
      error: 'boom',
    );

    final call = ledger.runFor(sessionKey)!.toolCalls.single;
    expect(call.status, ToolCallStatus.error);
    expect(call.result, 'boom');
  });

  test('a file writes its bytes BEFORE the block that points at them',
      () async {
    ledger.begin(sessionKey);
    final bytes = Uint8List.fromList(<int>[9, 8, 7, 6]);
    final block = await ledger.file(
      sessionKey,
      AgentsRelayFile(
        name: 'shot.png',
        mimeType: 'image/png',
        declaredSize: 4,
        bytes: bytes,
      ),
    );

    expect(block, isNotNull);
    expect(block!.type, ContentBlockType.sandboxArtifact);
    final payload = block.sandboxArtifact!;
    expect(payload.filename, 'shot.png');
    expect(payload.mime, 'image/png');
    expect(payload.sizeBytes, 4);
    // The block's storage path resolves the moment the block exists — that is
    // the invariant: bytes first, then the card that renders them.
    expect(ImageStorageService.getCached(payload.storagePath), bytes);
    expect(await ImageStorageService.imageExists(payload.storagePath), isTrue);
    expect(ledger.runFor(sessionKey)!.blocks, <ContentBlock>[block]);
  });

  test('a broken file writes nothing and produces no block', () async {
    ledger.begin(sessionKey);
    final block = await ledger.file(
      sessionKey,
      const AgentsRelayFile(
        name: 'shot.png',
        mimeType: 'image/png',
        declaredSize: 9,
        error: 'The file body is not valid base64.',
      ),
    );

    expect(block, isNull);
    expect(ledger.runFor(sessionKey)!.blocks, isEmpty);
  });

  test('an approval becomes the completed ask_user line AskUserCard reads', () {
    ledger.begin(sessionKey);
    ledger.approval(
      sessionKey,
      const AgentsRelayApprovalRequest(
        approvalId: 'ap-1',
        action: 'herenow_publish',
        path: 'site',
        name: 'My Page',
        fileCount: 2,
        totalBytes: 2048,
        baseUrl: 'https://here.now',
        public: true,
      ),
    );

    final call = ledger.runFor(sessionKey)!.toolCalls.single;
    expect(call.name, 'ask_user');
    expect(call.status, ToolCallStatus.completed);
    expect(call.arguments['options'], <String>['Publish', 'Deny']);
    expect(call.arguments['approvalId'], 'ap-1');
    expect(call.arguments['question'], contains('My Page'));
    expect(call.result, contains('"approvalId":"ap-1"'));
  });

  test('reasoning accumulates and finish closes the run', () {
    ledger.begin(sessionKey);
    expect(ledger.isRunning(sessionKey), isTrue);
    ledger
      ..reasoning(sessionKey, 'first ')
      ..reasoning(sessionKey, 'second');
    ledger.finish(
      sessionKey,
      finalAnswer: 'done',
      reason: 'finished',
      iterations: 3,
      tokensSpent: 42,
      runId: 'run-1',
    );

    final run = ledger.runFor(sessionKey)!;
    expect(run.modelReasoning, 'first second');
    expect(run.finalAnswer, 'done');
    expect(run.iterations, 3);
    expect(run.tokensSpent, 42);
    expect(run.runId, 'run-1');
    expect(ledger.isRunning(sessionKey), isFalse);
  });

  test('finish leaves nothing spinning', () {
    ledger.begin(sessionKey);
    ledger.openTool(sessionKey, 'run_command', arguments: 'sleep 999');
    ledger.finish(sessionKey, reason: 'estop');

    expect(
      ledger.runFor(sessionKey)!.toolCalls.single.status,
      ToolCallStatus.error,
    );
  });

  test('take hands the run over once and forgets it', () {
    ledger.begin(sessionKey);
    ledger.closeTool(sessionKey, 'run_command', exitCode: 0);

    final run = ledger.take(sessionKey);
    expect(run, isNotNull);
    expect(run!.toolCalls, hasLength(1));
    expect(ledger.take(sessionKey), isNull);
    expect(ledger.runFor(sessionKey), isNull);
  });

  test('begin starts a clean turn, keeping the thread debug context', () {
    ledger.begin(sessionKey);
    ledger.debugContext(sessionKey, <String, dynamic>{'round': 1});
    ledger.closeTool(sessionKey, 'run_command', exitCode: 0);

    ledger.begin(sessionKey);
    expect(ledger.runFor(sessionKey)!.toolCalls, isEmpty);
    expect(ledger.runFor(sessionKey)!.debugContext, <String, dynamic>{
      'round': 1,
    });
  });

  test('two threads keep their own runs', () {
    ledger.begin('a');
    ledger.begin('b');
    ledger.closeTool('a', 'run_command', exitCode: 0);
    ledger.subagent('b', subagentId: 'sa_1', title: 't', state: 'running');

    expect(ledger.runFor('a')!.toolCalls.single.name, 'run_command');
    expect(ledger.runFor('b')!.toolCalls.single.name, 'subagent');
    expect(ledger.runningSessions.toSet(), <String>{'a', 'b'});
  });

  test('a host run adopted from run_state is running without a begin', () {
    ledger.adoptRunning(
      sessionKey,
      runId: 'run-7',
      prompt: 'the thing it is busy with',
    );
    expect(ledger.isRunning(sessionKey), isTrue);
    expect(ledger.runFor(sessionKey)!.detachedPrompt,
        'the thing it is busy with');

    // It never clobbers a run this client is already tracking.
    ledger.begin(sessionKey);
    ledger.closeTool(sessionKey, 'run_command', exitCode: 0);
    ledger.adoptRunning(sessionKey, runId: 'run-8');
    expect(ledger.runFor(sessionKey)!.toolCalls, hasLength(1));
  });

  test('every recording notifies, so the roster can follow a run', () {
    var notifications = 0;
    void listener() => notifications++;
    ledger.addListener(listener);
    addTearDown(() => ledger.removeListener(listener));

    ledger.begin(sessionKey);
    ledger.closeTool(sessionKey, 'run_command', exitCode: 0);
    ledger.finish(sessionKey, reason: 'finished');

    expect(notifications, greaterThanOrEqualTo(3));
  });

  // --- one mapping for live and replay (bead cowork-266) --------------------

  test('subagentCallFromRelay updates the card it is given', () {
    final opened = subagentCallFromRelay(
      null,
      subagentId: 'sa_1',
      title: 'reader',
      state: 'running',
      result: 'partial',
    );
    expect(opened.status, ToolCallStatus.running);
    expect(opened.arguments['title'], 'reader');
    expect(opened.result, 'partial');

    final closed = subagentCallFromRelay(
      opened,
      subagentId: 'sa_1',
      title: 'reader',
      state: 'failed',
      error: 'boom',
      now: DateTime(2026, 9, 5),
    );
    expect(identical(closed, opened), isTrue);
    expect(closed.status, ToolCallStatus.error);
    expect(closed.result, 'boom');
    expect(closed.completedAt, DateTime(2026, 9, 5));
  });

  test('artifactBlockFromFile describes the stored bytes', () {
    final block = artifactBlockFromFile(
      'cowork://blob/1',
      AgentsRelayFile(
        name: 'a.png',
        mimeType: 'image/png',
        declaredSize: 3,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );
    expect(block.type, ContentBlockType.sandboxArtifact);
    expect(block.sandboxArtifact!.storagePath, 'cowork://blob/1');
    expect(block.sandboxArtifact!.filename, 'a.png');
    expect(block.sandboxArtifact!.sizeBytes, 3);
  });

  test('approvalCallFromRelay: open offers options, decided only reports', () {
    const open = AgentsRelayApprovalRequest(
      approvalId: 'ap1',
      action: 'herenow_publish',
      path: 'site',
      name: 'Site',
      fileCount: 1,
      totalBytes: 2,
      baseUrl: 'here.now',
      public: true,
    );
    final live = approvalCallFromRelay(open);
    expect(live.name, 'ask_user');
    expect(live.arguments['options'], ['Publish', 'Deny']);
    expect(live.arguments.containsKey('decision'), isFalse);

    const denied = AgentsRelayApprovalRequest(
      approvalId: 'ap1',
      action: 'herenow_publish',
      path: 'site',
      name: 'Site',
      fileCount: 1,
      totalBytes: 2,
      baseUrl: 'here.now',
      public: true,
      replay: true,
      mid: 4,
      decision: 'denied',
      decisionReason: 'stopped',
    );
    final settled = approvalCallFromRelay(denied);
    expect(settled.arguments.containsKey('options'), isFalse);
    expect(settled.arguments['offered_options'], ['Publish', 'Deny']);
    expect(settled.arguments['decision'], 'Deny');
    expect(settled.arguments['decision_reason'], 'stopped');

    // An open request on a run that is over is settled by the caller.
    final expired = approvalCallFromRelay(open, decided: true);
    expect(expired.arguments.containsKey('options'), isFalse);
    expect(expired.arguments['decision'], 'Expired');
  });
}
