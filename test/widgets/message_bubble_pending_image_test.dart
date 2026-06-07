import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(
    List<ToolCall> calls, {
    bool streaming = true,
    List<ContentBlock>? contentBlocks,
    List<String>? images,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          message: '',
          isUser: false,
          isStreamingMessage: streaming,
          toolCalls: calls,
          contentBlocks: contentBlocks,
          images: images,
        ),
      ),
    );
  }

  ToolCall genImage({
    required ToolCallStatus status,
    Map<String, dynamic> args = const {'prompt': 'x'},
    String? result,
  }) {
    return ToolCall(
      name: 'generate_image',
      arguments: args,
      status: status,
      result: result,
    );
  }

  testWidgets('running generate_image shows spinner + resolution label', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        genImage(
          status: ToolCallStatus.running,
          args: const {'prompt': 'a cat', 'image_size': 'landscape_16_9'},
        ),
      ]),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('1024 × 576'), findsOneWidget);
  });

  testWidgets('aspect_ratio arg is used as the label', (tester) async {
    await tester.pumpWidget(
      host([
        genImage(
          status: ToolCallStatus.running,
          args: const {'prompt': 'x', 'aspect_ratio': '16:9'},
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('16:9'), findsOneWidget);
  });

  testWidgets('completed generate_image shows no loader label', (tester) async {
    await tester.pumpWidget(
      host([
        genImage(
          status: ToolCallStatus.completed,
          args: const {'prompt': 'x', 'image_size': 'square_hd'},
          result: 'IMAGE:{"url":"https://example.com/a.png"}',
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('1024 × 1024'), findsNothing);
  });

  testWidgets('loader shows even when not flagged streaming', (tester) async {
    // The desktop streaming flag flips false during tool execution, so a
    // running generate_image must still show its loader regardless.
    await tester.pumpWidget(
      host(streaming: false, [
        genImage(
          status: ToolCallStatus.running,
          args: const {'prompt': 'x', 'image_size': 'landscape_16_9'},
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('1024 × 576'), findsOneWidget);
  });

  testWidgets(
    'content-blocks round with 4 running calls shows 4 loader spinners',
    (tester) async {
      // Exercises the real desktop path: live tool calls live inside a
      // content block, not flagged streaming during tool execution.
      final calls = [
        genImage(status: ToolCallStatus.running),
        genImage(status: ToolCallStatus.running),
        genImage(status: ToolCallStatus.running),
        genImage(status: ToolCallStatus.running),
      ];

      await tester.pumpWidget(
        host(
          streaming: false,
          calls,
          contentBlocks: [ContentBlock.toolCalls(calls)],
        ),
      );
      await tester.pump();

      // 4 loader tiles → 4 spinners.
      expect(find.byType(CircularProgressIndicator), findsNWidgets(4));
    },
  );
}
