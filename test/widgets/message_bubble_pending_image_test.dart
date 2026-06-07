import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(List<ToolCall> calls, {bool streaming = true}) {
    return MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          message: '',
          isUser: false,
          isStreamingMessage: streaming,
          toolCalls: calls,
        ),
      ),
    );
  }

  testWidgets('running generate_image shows spinner + resolution label', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        ToolCall(
          name: 'generate_image',
          arguments: const {'prompt': 'a cat', 'image_size': 'landscape_16_9'},
          status: ToolCallStatus.running,
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
        ToolCall(
          name: 'generate_image',
          arguments: const {'prompt': 'x', 'aspect_ratio': '16:9'},
          status: ToolCallStatus.running,
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('16:9'), findsOneWidget);
  });

  testWidgets('completed generate_image shows no placeholder label', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        ToolCall(
          name: 'generate_image',
          arguments: const {'prompt': 'x', 'image_size': 'square_hd'},
          status: ToolCallStatus.completed,
          result: 'IMAGE:{"url":"https://example.com/a.png"}',
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('1024 × 1024'), findsNothing);
  });

  testWidgets('placeholder only appears while streaming', (tester) async {
    await tester.pumpWidget(
      host(streaming: false, [
        ToolCall(
          name: 'generate_image',
          arguments: const {'prompt': 'x', 'image_size': 'landscape_16_9'},
          status: ToolCallStatus.running,
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('1024 × 576'), findsNothing);
  });
}
