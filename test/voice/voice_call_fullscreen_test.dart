import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/widgets/voice_call_fullscreen_page.dart';

void main() {
  testWidgets('fullscreen route is unique, returns to chat and can reopen', (
    tester,
  ) async {
    final controller = VoiceCallController.forTesting();
    controller.debugSetState(
      phase: VoiceCallPhase.live,
      chatId: 'chat-a',
      turns: [
        VoiceTurn(
          role: 'assistant',
          text: 'A normal spoken answer',
          at: DateTime.utc(2026),
          isFinal: true,
        ),
      ],
    );
    late BuildContext chatContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            chatContext = context;
            return const Scaffold(body: Text('Ordinary chat'));
          },
        ),
      ),
    );
    final first = VoiceCallFullscreenPage.show(
      chatContext,
      controller: controller,
    );
    expect(
      identical(
        first,
        VoiceCallFullscreenPage.show(chatContext, controller: controller),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(find.byType(VoiceCallFullscreenPage), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-visualization')), findsOneWidget);
    expect(find.textContaining('A normal spoken answer'), findsOneWidget);
    Navigator.of(chatContext).pop();
    await tester.pumpAndSettle();
    await first;
    expect(find.text('Ordinary chat'), findsOneWidget);
    expect(controller.phase, VoiceCallPhase.live);

    VoiceCallFullscreenPage.show(chatContext, controller: controller);
    await tester.pumpAndSettle();
    controller.debugSetState(phase: VoiceCallPhase.ended, chatId: 'chat-a');
    await tester.pumpAndSettle();
    expect(find.byType(VoiceCallFullscreenPage), findsNothing);
    expect(find.text('Ordinary chat'), findsOneWidget);
  });

  testWidgets('call controls fit a narrow landscape viewport', (tester) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VoiceCallController.forTesting();
    controller.debugSetState(phase: VoiceCallPhase.live, chatId: 'chat-a');
    await tester.pumpWidget(
      MaterialApp(home: VoiceCallFullscreenPage(controller: controller)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byTooltip('End call'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byTooltip('End call').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
