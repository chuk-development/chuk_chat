import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A Kimi multiplex turn leaks a lone `<` text block between consecutive
  // tool-call sections. That junk block strips to empty, so it must NOT act as
  // a separator: the surrounding tool-call blocks should still merge into ONE
  // bar (e.g. `web_search (4×)`), exactly like a run of tool-call blocks with
  // no text between them. Previously the empty block closed the round and the
  // four calls rendered as four separate bars.
  testWidgets('tool-call blocks split by junk-only "<" text blocks merge', (
    tester,
  ) async {
    ToolCall search(String id) => ToolCall(
      id: id,
      name: 'web_search',
      arguments: const {'query': 'x'},
      status: ToolCallStatus.completed,
      result: 'ok',
    );

    final blocks = <ContentBlock>[
      ContentBlock.toolCalls([search('call_1')]),
      const ContentBlock.text('<'),
      ContentBlock.toolCalls([search('call_2')]),
      const ContentBlock.text('<'),
      ContentBlock.toolCalls([search('call_3')]),
      const ContentBlock.text('<'),
      ContentBlock.toolCalls([search('call_4')]),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            contentBlocks: blocks,
          ),
        ),
      ),
    );

    // One merged bar, not four.
    expect(find.text('web_search (4×)'), findsOneWidget);
    expect(find.text('web_search'), findsNothing);
    // The junk `<` blocks never render as text.
    expect(find.text('<'), findsNothing);
  });

  // A real (non-empty) text block between tool rounds STILL separates them.
  testWidgets('real text between tool rounds keeps them as separate bars', (
    tester,
  ) async {
    ToolCall search(String id) => ToolCall(
      id: id,
      name: 'web_search',
      arguments: const {'query': 'x'},
      status: ToolCallStatus.completed,
      result: 'ok',
    );

    final blocks = <ContentBlock>[
      ContentBlock.toolCalls([search('call_1')]),
      const ContentBlock.text('Some real prose between rounds.'),
      ContentBlock.toolCalls([search('call_2')]),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            contentBlocks: blocks,
          ),
        ),
      ),
    );

    expect(find.text('Some real prose between rounds.'), findsOneWidget);
    // Two single-call bars, not one merged `web_search (2×)`.
    expect(find.text('web_search'), findsNWidgets(2));
    expect(find.text('web_search (2×)'), findsNothing);
  });
}
