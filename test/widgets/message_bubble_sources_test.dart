import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The bottom-right sources pill: it gathers the pages a turn read into one
  // "N sources" count. Only the web tools feed it — an image-generation URL is
  // not a source — so a turn with no web reads shows no pill.
  Widget wrap(List<ContentBlock> blocks) => MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: '',
            isUser: false,
            contentBlocks: blocks,
          ),
        ),
      );

  testWidgets('a web_search turn shows a sources pill with the count',
      (tester) async {
    await tester.pumpWidget(
      wrap(<ContentBlock>[
        ContentBlock.toolCalls([
          ToolCall(
            id: 'call_1',
            name: 'web_search',
            arguments: const {'query': 'kiel'},
            status: ToolCallStatus.completed,
            result: '1. Example Title\n'
                '   https://example.com/page\n'
                '2. Second Title\n'
                '   https://foo.org/bar\n',
          ),
        ]),
        const ContentBlock.text('Here is what I found.'),
      ]),
    );
    await tester.pump();

    expect(find.text('2 sources'), findsOneWidget);
  });

  testWidgets('a single source reads "1 source", not "1 sources"',
      (tester) async {
    await tester.pumpWidget(
      wrap(<ContentBlock>[
        ContentBlock.toolCalls([
          ToolCall(
            id: 'call_1',
            name: 'web_crawl',
            arguments: const {'url': 'https://example.com/page'},
            status: ToolCallStatus.completed,
            result: 'Content from https://example.com/page\nBody text.',
          ),
        ]),
        const ContentBlock.text('Done.'),
      ]),
    );
    await tester.pump();

    expect(find.text('1 source'), findsOneWidget);
  });

  testWidgets('an image-generation turn shows no sources pill',
      (tester) async {
    await tester.pumpWidget(
      wrap(<ContentBlock>[
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
      ]),
    );
    await tester.pump();

    // The image URL must not be mistaken for a web source.
    expect(find.textContaining('source'), findsNothing);
  });
}
