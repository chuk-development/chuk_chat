import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders <image> visual block with caption', (tester) async {
    const message =
        '<image>{"url":"https://example.com/photo.jpg","caption":"Michelangelo Porträt"}</image>';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: message, isUser: false)),
      ),
    );

    expect(find.text('Michelangelo Porträt'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('shows parse error for invalid <image> URL', (tester) async {
    const message = '<image>{"url":"ftp://example.com/photo.jpg"}</image>';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: message, isUser: false)),
      ),
    );

    expect(
      find.textContaining('image parse error: invalid or missing http(s) url'),
      findsOneWidget,
    );
  });
}
