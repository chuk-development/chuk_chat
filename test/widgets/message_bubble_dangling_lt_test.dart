import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Kimi K2.x on Fireworks leaks a lone `<` (the start of a stripped
  // `<|tool_calls_section_begin|>` token) as a finalized text content block.
  // On mobile / cached chats that raw block reaches the renderer; it must
  // never show up as a stray `<` line above the tool-call bar.
  testWidgets('lone "<" text content block does not render', (tester) async {
    final blocks = <ContentBlock>[
      const ContentBlock.text('<'),
      ContentBlock.toolCalls([
        ToolCall(
          id: 'call_1',
          name: 'generate_image',
          arguments: const {'prompt': 'a lake'},
          status: ToolCallStatus.completed,
          result: 'IMAGE:{"url":"https://example.com/x.webp"}',
        ),
      ]),
      const ContentBlock.text('Here is your image.'),
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

    expect(find.text('Here is your image.'), findsOneWidget);
    // The stray `<` block must be stripped — no text widget renders just "<".
    expect(find.text('<'), findsNothing);
  });
}
