import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cowork/widgets/messenger_context_menu.dart';
import 'package:cowork/widgets/chat_reply_preview.dart';

void main() {
  testWidgets(
    'menu fades in without moving and extra reactions scroll inline',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showMessengerContextMenu(
                    context: context,
                    anchor: const Rect.fromLTWH(20, 150, 280, 100),
                    preview: const Text('Message'),
                    canEdit: true,
                    canReply: true,
                    isUser: true,
                    canReact: true,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final first = tester.getRect(
        find.byKey(const ValueKey('context_message_actions')),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.getRect(find.byKey(const ValueKey('context_message_actions'))),
        first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byTooltip('More reactions'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('context_reactions')),
        const Offset(-1000, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('🤯').hitTestable());
      await tester.pumpAndSettle();
      expect(result, 'reaction:🤯');
    },
  );

  testWidgets('edit cancel has a full touch target', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatEditNotice(onCancel: () => cancelled = true)),
      ),
    );
    final button = find.widgetWithText(TextButton, 'Cancel');
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    expect(cancelled, isTrue);
  });
}
