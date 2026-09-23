// The status line above an answer: what the turn is doing, and how long it
// has been doing it. One source of truth for both platforms, so these tests
// cover the wording itself rather than a platform's layout.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:chuk_chat/widgets/agent_activity/turn_status.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

void main() {
  group('wording', () {
    test('a request still in flight is not called thinking', () {
      const status = TurnStatus(
        isRunning: true,
        hasToolCalls: false,
        elapsed: Duration(seconds: 2),
      );

      expect(status.label, 'Connecting for 2s');
    });

    test('the server reading the prompt is named as such', () {
      const status = TurnStatus(
        isRunning: true,
        hasToolCalls: false,
        phase: StreamPhase.processing,
        elapsed: Duration(seconds: 3),
      );

      expect(status.label, 'Prompt processing for 3s');
    });

    test('reasoning tokens make it thinking', () {
      const status = TurnStatus(
        isRunning: true,
        hasToolCalls: false,
        phase: StreamPhase.thinking,
        elapsed: Duration(seconds: 12),
      );

      expect(status.label, 'Thinking for 12s');
    });

    test('a running tool outranks the stream phase', () {
      const status = TurnStatus(
        isRunning: true,
        hasToolCalls: true,
        phase: StreamPhase.writing,
        runningToolLabel: 'Searching the web',
        elapsed: Duration(seconds: 4),
      );

      expect(status.label, 'Searching the web for 4s');
    });

    test('a settled turn is named by what it did', () {
      const thought = TurnStatus(
        isRunning: false,
        hasToolCalls: false,
        elapsed: Duration(seconds: 12),
      );
      const worked = TurnStatus(
        isRunning: false,
        hasToolCalls: true,
        elapsed: Duration(seconds: 12),
      );

      expect(thought.label, 'Thought for 12s');
      expect(worked.label, 'Worked for 12s');
    });

    test('a turn under a second still prints its time', () {
      const status = TurnStatus(
        isRunning: false,
        hasToolCalls: false,
        elapsed: Duration(milliseconds: 600),
      );

      expect(status.label, 'Thought for 0.6s');
    });
  });

  group('elapsed', () {
    final now = DateTime.utc(2026, 9, 14, 12, 0, 30);

    test('the recorded length wins over everything else', () {
      final elapsed = resolveTurnElapsed(
        finalDuration: const Duration(seconds: 7),
        startedAt: now.subtract(const Duration(seconds: 99)),
        now: now,
        isRunning: false,
      );

      expect(elapsed, const Duration(seconds: 7));
    });

    test('a running turn counts from the send', () {
      final elapsed = resolveTurnElapsed(
        startedAt: now.subtract(const Duration(seconds: 9)),
        now: now,
        isRunning: true,
      );

      expect(elapsed, const Duration(seconds: 9));
    });

    test('a settled turn with no recorded length keeps the last live count', () {
      final elapsed = resolveTurnElapsed(
        now: now,
        isRunning: false,
        lastLiveDuration: const Duration(seconds: 11),
      );

      expect(elapsed, const Duration(seconds: 11));
    });

    test('a settled turn does not keep growing off its start stamp', () {
      final elapsed = resolveTurnElapsed(
        startedAt: now.subtract(const Duration(seconds: 40)),
        now: now,
        isRunning: false,
        lastLiveDuration: const Duration(seconds: 11),
      );

      expect(elapsed, const Duration(seconds: 11));
    });
  });

  group('reasoning lines', () {
    test('a one-sentence thought is not printed twice', () {
      final entry = reasoningEntry('Brief German take.');

      expect(entry.label, 'Brief German take.');
      expect(entry.hasBody, isFalse);
    });

    test('a longer thought keeps the rest as its body', () {
      final entry = reasoningEntry('First. Second sentence with more.');

      expect(entry.label, 'First.');
      expect(entry.body, 'First. Second sentence with more.');
    });

    testWidgets('the timeline renders a short thought once', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AgentActivityTimeline(
              toolCalls: <ToolCall>[],
              steps: <AgentActivityStep>[
                AgentActivityStep.reasoning('Brief German take.'),
              ],
              initiallyExpanded: true,
            ),
          ),
        ),
      );

      expect(find.text('Brief German take.'), findsOneWidget);
    });
  });

  group('the header is always there', () {
    testWidgets('a running turn with nothing on screen yet still counts', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentActivityTimeline(
              toolCalls: const <ToolCall>[],
              steps: const <AgentActivityStep>[],
              isRunning: true,
              phase: StreamPhase.processing,
              startedAt: DateTime.now().subtract(const Duration(seconds: 3)),
            ),
          ),
        ),
      );

      expect(find.textContaining('Prompt processing for'), findsOneWidget);
    });

    testWidgets('the header stays while the answer is being written', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: 'The answer so f',
              isUser: false,
              isStreamingMessage: true,
              isReasoningStreaming: true,
              turnStartedAt: DateTime.now().subtract(
                const Duration(seconds: 5),
              ),
            ),
          ),
        ),
      );

      // No reasoning and no tool call, but the turn is running: the reader
      // still gets a header, and it counts.
      expect(find.textContaining('for 5s'), findsOneWidget);
    });

    testWidgets('a reasoning-only round carries the turn duration', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: 'Here is the answer.',
              isUser: false,
              showReasoningTokens: true,
              showToolCalls: true,
              contentBlocks: const <ContentBlock>[
                ContentBlock.reasoning('Brief German take.'),
              ],
              workedFor: const Duration(seconds: 12),
            ),
          ),
        ),
      );

      expect(find.text('Thought for 12s'), findsOneWidget);
    });
  });
}
