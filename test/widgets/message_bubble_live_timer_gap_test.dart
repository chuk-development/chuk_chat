import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Regression: the "Worked for …" elapsed counter froze during Deep Research.
  // The interleaved (content-block) layout never marked its open round live, so
  // in the gaps where the model reasons BETWEEN tool rounds — every tool reads
  // `completed`, none running/pending — `isRunning` computed false, the 1 Hz
  // ticker was cancelled, and the header fell back to the frozen final duration.
  // The last open tool-round now stays live while the message streams, so the
  // header keeps counting ("Working for …") through the reasoning gap.
  ToolCall completedTool(String id, String name) => ToolCall(
    id: id,
    name: name,
    arguments: const {'q': 'x'},
    status: ToolCallStatus.completed,
    result: 'ok',
  );

  testWidgets('interleaved streaming timeline keeps counting between tool '
      'rounds (no running tool)', (tester) async {
    // A streaming turn frozen in a reasoning gap: tools done, model thinking,
    // no live tool call in flight, last block is reasoning.
    final blocks = <ContentBlock>[
      const ContentBlock.reasoning('I should search the web'),
      ContentBlock.toolCalls([completedTool('c1', 'web_search')]),
      const ContentBlock.reasoning('Now let me reason about the results'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            showReasoningTokens: true,
            showToolCalls: true,
            contentBlocks: blocks,
            isStreamingMessage: true,
            turnStartedAt: DateTime.now().subtract(const Duration(seconds: 9)),
          ),
        ),
      ),
    );

    // Running verb + live count, NOT the frozen "Worked for …".
    expect(find.textContaining('Working for'), findsOneWidget);
    expect(find.textContaining('Worked for'), findsNothing);
  });

  // Contrast: once the turn is no longer streaming, the same interleaved shape
  // settles to the recorded duration ("Worked for …"), so `live` does not pin
  // a finished message open.
  testWidgets('interleaved finished timeline shows recorded duration', (
    tester,
  ) async {
    final blocks = <ContentBlock>[
      const ContentBlock.reasoning('I should search the web'),
      ContentBlock.toolCalls([completedTool('c1', 'web_search')]),
      const ContentBlock.text('Here is the answer.'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            showReasoningTokens: true,
            showToolCalls: true,
            contentBlocks: blocks,
            workedFor: const Duration(seconds: 14),
          ),
        ),
      ),
    );

    expect(find.textContaining('Worked for'), findsOneWidget);
    expect(find.textContaining('Working for'), findsNothing);
  });
}
