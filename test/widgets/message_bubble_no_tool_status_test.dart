import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/message_bubble.dart';

void main() {
  // A turn with no tool call renders its status through _buildInfoStatusBar,
  // not the tool-call timeline. That path used to build the header without the
  // request start time, so a tool-free answer could not count from the moment
  // its request went out — the header sat at a bare "Thinking" with no elapsed
  // time. The info bar now forwards turnStartedAt (and the live phase) the same
  // way the tool path does. This test locks that: a streaming tool-free turn
  // whose request went out seconds ago shows a counting header.
  testWidgets('tool-free streaming turn counts from the request start', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            showReasoningTokens: true,
            reasoning: 'Planning the answer',
            isReasoningStreaming: true,
            isStreamingMessage: true,
            turnStartedAt: DateTime.now().subtract(const Duration(seconds: 7)),
          ),
        ),
      ),
    );

    // Running verb with an elapsed count, not a bare "Thinking". The number
    // is real time, so match the "<verb> for" shape rather than an exact
    // second.
    expect(find.textContaining('Thinking for'), findsOneWidget);
  });

  // Contrast: a finished tool-free answer shows its recorded duration through
  // the same path — "Thought for …", proving workedFor reaches the info bar
  // too, not only the live count.
  testWidgets('finished tool-free turn shows its recorded duration', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: 'Here is the answer.',
            isUser: false,
            showReasoningTokens: true,
            reasoning: 'Planning the answer',
            workedFor: const Duration(seconds: 12),
          ),
        ),
      ),
    );

    expect(find.textContaining('Thought for'), findsOneWidget);
  });
}
