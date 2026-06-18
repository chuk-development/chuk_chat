import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Regression: a multi-pass turn emits reasoning→tool repeatedly with no text
  // between the passes (e.g. `reasoning → web_search → reasoning → notes`).
  // Each pass used to render as its OWN tool bar, so the message showed several
  // stacked boxes. Consecutive tool-call rounds must instead merge into ONE
  // bar, and ALL reasoning — including the final-pass reasoning that trails the
  // last tool — folds INTO that one bar (as ordered cards), so the collapsed
  // turn reads as a single disclosure followed by the answer.
  ToolCall tool(String id, String name) => ToolCall(
    id: id,
    name: name,
    arguments: const {'q': 'x'},
    status: ToolCallStatus.completed,
    result: 'ok',
  );

  testWidgets('consecutive tool rounds + all reasoning fold into one bar', (
    tester,
  ) async {
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

    // Collapsed: no standalone reasoning card — the final reasoning is folded
    // inside the bar. Only the answer follows the bar.
    expect(find.text('Reasoning'), findsNothing);
    expect(find.textContaining('Synthesizing the findings'), findsNothing);
    expect(find.textContaining('Here is the final answer.'), findsOneWidget);

    // Expand the merged bar — structural check only: all three reasoning
    // entries and both tool entries live inside the one bar. We assert the
    // card COUNT, not the reasoning prose (the renderer never inspects text
    // content — blocks are classified purely by ContentBlockType).
    await tester.tap(find.text('web_search, notes'));
    await tester.pumpAndSettle();
    expect(find.text('Reasoning'), findsNWidgets(3));
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
