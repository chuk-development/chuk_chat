import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Regression: a multi-pass turn emits reasoning→tool repeatedly with no text
  // between the passes (e.g. `reasoning → web_search → reasoning → notes`).
  // Each pass used to render as its OWN tool bar, so the message showed three
  // stacked boxes (`web_search`, `notes`, `Reasoning`). Consecutive tool-call
  // rounds must instead merge into ONE bar; only the final-pass reasoning that
  // trails the last tool (right before the answer) peels out as its own card.
  ToolCall tool(String id, String name) => ToolCall(
    id: id,
    name: name,
    arguments: const {'q': 'x'},
    status: ToolCallStatus.completed,
    result: 'ok',
  );

  testWidgets('consecutive tool rounds with inter-tool reasoning merge into '
      'one bar; trailing reasoning stays standalone', (tester) async {
    final blocks = <ContentBlock>[
      const ContentBlock.reasoning('I should search the web'),
      ContentBlock.toolCalls([tool('c1', 'web_search')]),
      const ContentBlock.reasoning('Now I need my notes'),
      ContentBlock.toolCalls([tool('c2', 'notes')]),
      const ContentBlock.reasoning('Synthesizing the findings'),
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

    // Both tools collapse into a SINGLE bar whose head lists both names —
    // not two separate `web_search` / `notes` bars.
    expect(find.text('web_search, notes'), findsOneWidget);
    expect(find.text('web_search'), findsNothing);
    expect(find.text('notes'), findsNothing);

    // The trailing final-pass reasoning still renders as its own card,
    // and the final answer follows it.
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.textContaining('Synthesizing the findings'), findsOneWidget);
    expect(find.textContaining('Here is the final answer.'), findsOneWidget);
  });

  testWidgets('two tool rounds with no text after still merge into one bar', (
    tester,
  ) async {
    final blocks = <ContentBlock>[
      ContentBlock.toolCalls([tool('c1', 'web_search')]),
      const ContentBlock.reasoning('inter-tool thought'),
      ContentBlock.toolCalls([tool('c2', 'notes')]),
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

    expect(find.text('web_search, notes'), findsOneWidget);
  });
}
