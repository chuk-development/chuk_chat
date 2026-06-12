import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // After a web-search turn the model reasons TWICE: once before calling the
  // tool ("I should search the web") and again after the results come back,
  // just before writing the final answer ("based on the results…"). The
  // second reasoning used to live only in the flat message reasoning field,
  // which the bubble suppresses in content-block mode — so it silently
  // vanished and users saw only one reasoning block. StreamingMessageHandler
  // now appends the final pass's reasoning as its own ContentBlock.reasoning
  // right before the final text block. This test locks the render contract:
  // a reasoning block sitting between a tool-call round and the final text
  // renders as its own standalone "Reasoning" card.
  testWidgets('post-tool reasoning before final text renders as its own card', (
    tester,
  ) async {
    final search = ToolCall(
      id: 'call_1',
      name: 'web_search',
      arguments: const {'query': 'x'},
      status: ToolCallStatus.completed,
      result: 'ok',
    );

    final blocks = <ContentBlock>[
      ContentBlock.toolCalls([search]),
      const ContentBlock.reasoning('Synthesizing the search findings'),
      const ContentBlock.text('Here is the final answer.'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            showReasoningTokens: true,
            contentBlocks: blocks,
          ),
        ),
      ),
    );

    // The standalone reasoning card (label + preview) is present...
    expect(find.text('Reasoning'), findsOneWidget);
    expect(
      find.textContaining('Synthesizing the search findings'),
      findsOneWidget,
    );
    // ...and the final answer text still renders after it.
    expect(find.textContaining('Here is the final answer.'), findsOneWidget);
  });

  // Sanity contrast: with no post-tool reasoning block, no standalone
  // "Reasoning" card appears — the second reasoning only shows when it was
  // actually captured.
  testWidgets('no standalone reasoning card without a post-tool reasoning block', (
    tester,
  ) async {
    final search = ToolCall(
      id: 'call_1',
      name: 'web_search',
      arguments: const {'query': 'x'},
      status: ToolCallStatus.completed,
      result: 'ok',
    );

    final blocks = <ContentBlock>[
      ContentBlock.toolCalls([search]),
      const ContentBlock.text('Here is the final answer.'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            showReasoningTokens: true,
            contentBlocks: blocks,
          ),
        ),
      ),
    );

    expect(find.text('Reasoning'), findsNothing);
    expect(find.textContaining('Here is the final answer.'), findsOneWidget);
  });
}
