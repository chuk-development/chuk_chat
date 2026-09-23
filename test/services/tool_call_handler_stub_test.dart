import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_tool_call_handler.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';

void main() {
  // Agents delivers files as file blocks; decode them as the Agents build
  // does (the default follows FEATURE_AGENTS, which tests leave off).
  ContentBlock.decodesFileBlocks = true;
  const sessionKey = 'thread-1';
  final handler = AgentsToolCallHandler.instance;
  final ledger = AgentsRunLedger.instance;

  setUp(() {
    ledger.reset();
    AgentsRelayLink.instance.reset();
  });

  ToolLoopSession sessionFor(String? key) => handler.createSession(
        initialUserMessage: 'do the thing',
        history: const <Map<String, dynamic>>[],
        accessToken: 'token',
        discoveryContextKey: key,
      );

  test('shouldContinue is false, always', () async {
    for (final calls in <List<NativeToolCall>>[
      const <NativeToolCall>[],
      const <NativeToolCall>[
        NativeToolCall(id: '1', name: 'run_command', arguments: '{}'),
      ],
    ]) {
      for (final meta in <Map<String, dynamic>?>[
        null,
        <String, dynamic>{'stop_reason': 'tool_use'},
        <String, dynamic>{'finish_reason': 'tool_calls'},
        <String, dynamic>{'stop_reason': 'max_tokens'},
      ]) {
        final result = await handler.processAssistantResponse(
          session: sessionFor(sessionKey),
          content: 'the answer',
          reasoning: '',
          turnSignals: ToolTurnSignals.fromMeta(meta),
          nativeToolCalls: calls,
        );
        expect(result.shouldContinue, isFalse);
        expect(result.nextStep, isNull);
      }
    }
  });

  test('the host owns the prompt and the tools', () async {
    final session = sessionFor(sessionKey);
    expect(await handler.buildInitialSystemPrompt(session), '');
    expect(handler.nativeToolDefinitions(session), isEmpty);
  });

  test("the run ledger's tool calls and blocks surface on the result",
      () async {
    ledger.begin(sessionKey);
    ledger
      ..openTool(sessionKey, 'run_command', arguments: 'ls')
      ..closeTool(sessionKey, 'run_command', result: 'a\nb', exitCode: 0);
    await ledger.file(
      sessionKey,
      AgentsRelayFile(
        name: 'report.csv',
        mimeType: 'text/csv',
        declaredSize: 3,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );
    ledger.reasoning(sessionKey, 'thinking hard');
    ledger.finish(sessionKey, finalAnswer: 'here it is', reason: 'finished');

    final surfaced = <List<ToolCall>>[];
    final result = await handler.processAssistantResponse(
      session: sessionFor(sessionKey),
      content: 'streamed text',
      reasoning: '',
      onToolCallsUpdated: surfaced.add,
    );

    expect(result.shouldContinue, isFalse);
    expect(result.toolCalls.map((c) => c.name), <String>['run_command']);
    expect(result.toolCalls.single.status, ToolCallStatus.completed);
    expect(result.producedBlocks, hasLength(1));
    expect(
      result.producedBlocks.single.type,
      ContentBlockType.sandboxArtifact,
    );
    // The host's own final answer wins over the streamed deltas.
    expect(result.finalContent, 'here it is');
    // With no streamed reasoning buffer the ledger's copy is the fallback.
    expect(result.finalReasoning, 'thinking hard');
    expect(surfaced, hasLength(1));
    expect(surfaced.single.single.name, 'run_command');
  });

  test('the run is taken once: a second fold sees nothing', () async {
    ledger.begin(sessionKey);
    ledger.closeTool(sessionKey, 'run_command', exitCode: 0);
    ledger.finish(sessionKey, reason: 'finished');

    final first = await handler.processAssistantResponse(
      session: sessionFor(sessionKey),
      content: 'a',
      reasoning: '',
    );
    final second = await handler.processAssistantResponse(
      session: sessionFor(sessionKey),
      content: 'a',
      reasoning: '',
    );

    expect(first.toolCalls, hasLength(1));
    expect(second.toolCalls, isEmpty);
    expect(second.shouldContinue, isFalse);
  });

  test('an empty host answer never overwrites the streamed reply', () async {
    ledger.begin(sessionKey);
    ledger.finish(sessionKey, finalAnswer: '   ', reason: 'finished');

    final result = await handler.processAssistantResponse(
      session: sessionFor(sessionKey),
      content: 'the streamed answer',
      reasoning: 'streamed thinking',
    );

    expect(result.finalContent, 'the streamed answer');
    expect(result.finalReasoning, 'streamed thinking');
  });

  test('a session with no chat id falls back to the link session key',
      () async {
    AgentsRelayLink.instance.sessionKey.value = 'fallback-thread';
    ledger.begin('fallback-thread');
    ledger.closeTool('fallback-thread', 'run_command', exitCode: 0);

    final result = await handler.processAssistantResponse(
      session: sessionFor(null),
      content: 'a',
      reasoning: '',
    );

    expect(result.toolCalls, hasLength(1));
  });

  test('a tool still running when the turn ends is finalised, not left spinning',
      () async {
    ledger.begin(sessionKey);
    ledger.openTool(sessionKey, 'run_command', arguments: 'sleep 999');
    // The run is over (a terminal that did not close the line itself).
    ledger.runFor(sessionKey)!.running = false;

    final result = await handler.processAssistantResponse(
      session: sessionFor(sessionKey),
      content: 'a',
      reasoning: '',
    );

    expect(result.toolCalls.single.status, ToolCallStatus.error);
    expect(result.toolCalls.single.completedAt, isNotNull);
  });

  test('a run the host still works on is read, not taken', () async {
    // `run_state: running`: the stream closes at once, the run stays live.
    ledger.adoptRunning(sessionKey, runId: 'run-1');
    ledger.openTool(sessionKey, 'run_command', arguments: 'sleep 999');

    final result = await handler.processAssistantResponse(
      session: sessionFor(sessionKey),
      content: '',
      reasoning: '',
    );

    expect(result.toolCalls.single.name, 'run_command');
    expect(result.toolCalls.single.status, ToolCallStatus.running);
    expect(ledger.isRunning(sessionKey), isTrue);
    expect(
      ledger.runFor(sessionKey)!.toolCalls.single.status,
      ToolCallStatus.running,
    );

    // Once the host finishes, the next fold takes it as usual.
    ledger.finish(sessionKey, finalAnswer: 'done', reason: 'finished');
    final later = await handler.processAssistantResponse(
      session: sessionFor(sessionKey),
      content: '',
      reasoning: '',
    );
    expect(later.finalContent, 'done');
    expect(ledger.runFor(sessionKey), isNull);
  });
}
