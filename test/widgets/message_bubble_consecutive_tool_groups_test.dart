import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Regression: a multi-pass turn emits reasoning→tool repeatedly with no text
  // between the passes (e.g. `reasoning → web_search → reasoning → notes`).
  // Each pass used to render as its OWN tool bar, so the message showed several
  // stacked boxes. Consecutive tool-call rounds must instead merge into ONE
  // activity timeline, and ALL reasoning — including the final-pass reasoning
  // that trails the last tool — folds INTO that timeline as steps, so the
  // collapsed turn reads as a single "Worked for …" line plus the answer.
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

    // Both rounds collapse into a SINGLE timeline, not one per round.
    expect(find.byType(AgentActivityTimeline), findsOneWidget);
    expect(find.textContaining('Worked for'), findsOneWidget);

    // Collapsed: the steps and the reasoning are hidden, the answer is not.
    expect(find.textContaining('Synthesizing the findings'), findsNothing);
    expect(find.textContaining('Here is the final answer.'), findsOneWidget);

    // Expanded: all three reasoning notes and both tool steps sit inside
    // that one timeline, in the order they happened.
    await tester.tap(find.textContaining('Worked for'));
    await tester.pumpAndSettle();
    expect(find.text('I should search the web'), findsOneWidget);
    expect(find.text('Now I need my notes'), findsOneWidget);
    expect(find.text('Synthesizing the findings'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
  });

  testWidgets('two tool rounds with no text after still merge into one', (
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

    expect(find.byType(AgentActivityTimeline), findsOneWidget);
  });
}
