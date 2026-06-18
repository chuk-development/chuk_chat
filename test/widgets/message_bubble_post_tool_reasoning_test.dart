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
  // that trailing reasoning is NOT peeled out as a standalone card between the
  // bar and the answer — it folds INTO the one tool bar as the last card, so
  // the whole turn reads as one disclosure followed by the answer.
  testWidgets('post-tool reasoning folds into the tool bar, not a standalone '
      'card', (tester) async {
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

    // Collapsed: only the single tool bar (header = 'web_search') and the
    // answer are visible. The trailing reasoning lives INSIDE the collapsed
    // bar, so its 'Reasoning' card is not in the tree yet. Structural check —
    // we never assert the reasoning prose (blocks are classified by
    // ContentBlockType, never by text content).
    expect(find.text('web_search'), findsOneWidget);
    expect(find.text('Reasoning'), findsNothing);
    expect(find.textContaining('Here is the final answer.'), findsOneWidget);

    // Expand the bar — the folded-in final reasoning card now appears inside it.
    await tester.tap(find.text('web_search'));
    await tester.pumpAndSettle();
    expect(find.text('Reasoning'), findsOneWidget);
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
