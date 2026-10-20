import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/voice/widgets/voice_call_controls.dart';

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
    expect(find.byTooltip('End call').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Mute').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'camera is visible only while enabled and waits for local track',
    (tester) async {
      final controller = VoiceCallController.forTesting();
      controller.debugSetState(
        phase: VoiceCallPhase.live,
        cameraEnabled: false,
      );
      await tester.pumpWidget(
        MaterialApp(home: VoiceCallFullscreenPage(controller: controller)),
      );
      expect(find.byKey(const ValueKey('voice-camera-preview')), findsNothing);
      controller.debugSetState(phase: VoiceCallPhase.live, cameraEnabled: true);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('voice-camera-preview')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Your camera'), findsOneWidget);
      expect(find.text('Starting camera…'), findsOneWidget);
      expect(find.byTooltip('Turn video off'), findsOneWidget);
      controller.debugSetState(
        phase: VoiceCallPhase.live,
        cameraEnabled: false,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('voice-camera-preview')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('speaker route changes the button label and its fill', (
    tester,
  ) async {
    final controller = VoiceCallController.forTesting();
    controller.debugSetState(
      phase: VoiceCallPhase.live,
      canSwitchSpeaker: true,
      speakerOn: true,
      outputRoute: 'speaker',
    );
    await tester.pumpWidget(
      MaterialApp(home: VoiceCallFullscreenPage(controller: controller)),
    );
    Color? fill(String tooltip) {
      final box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return (box.decoration as BoxDecoration?)?.color;
    }

    expect(find.byTooltip('Speaker on'), findsOneWidget);
    final selectedFill = fill('Speaker on');
    controller.debugSetState(
      phase: VoiceCallPhase.live,
      canSwitchSpeaker: true,
      speakerOn: false,
      outputRoute: 'earpiece',
    );
    await tester.pump();
    expect(find.byTooltip('Earpiece'), findsOneWidget);
    expect(fill('Earpiece'), isNot(selectedFill));
    controller.debugSetState(
      phase: VoiceCallPhase.live,
      canSwitchSpeaker: true,
      speakerOn: false,
      outputRoute: 'bluetooth',
      changingSpeaker: true,
    );
    await tester.pump();
    expect(find.byTooltip('Switching…'), findsOneWidget);
    controller.debugSetState(
      phase: VoiceCallPhase.live,
      canSwitchSpeaker: true,
      speakerOn: false,
      outputRoute: 'bluetooth',
    );
    await tester.pump();
    expect(find.byTooltip('Bluetooth'), findsOneWidget);
  });

  testWidgets('the route menu switches to the speaker', (tester) async {
    final controller = VoiceCallController.forTesting();
    controller.debugSetState(
      phase: VoiceCallPhase.connecting,
      canSwitchSpeaker: true,
      speakerOn: false,
      outputRoute: 'earpiece',
    );
    await tester.pumpWidget(
      MaterialApp(home: VoiceCallFullscreenPage(controller: controller)),
    );
    await tester.tap(find.byTooltip('Earpiece'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Speaker'), findsOneWidget);
    await tester.tap(find.text('Speaker'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.speakerOn, isTrue);
  });

  testWidgets('a place card lifts the bars; hiding it lowers them', (
    tester,
  ) async {
    final controller = VoiceCallController.forTesting();
    controller.debugSetState(
      phase: VoiceCallPhase.live,
      agentSpeaking: true,
      cards: [
        VoiceCard(
          id: 'c1',
          kind: 'weather',
          title: 'Kiel',
          data: const {'temperature': 12, 'condition': 'Cloudy'},
          at: DateTime.utc(2026),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(home: VoiceCallFullscreenPage(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final bars = tester.getRect(
      find.byKey(const ValueKey('voice-visualization')),
    );
    expect(bars.height, lessThanOrEqualTo(108));
    expect(find.text('Kiel'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Kiel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('interrupted caption dims only words that were not spoken', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceTurnCaption(
            name: 'Assistant',
            turn: VoiceTurn(
              role: 'assistant',
              text: 'The first part.',
              intendedText: 'The first part. The rest.',
              interrupted: true,
              at: DateTime.utc(2026),
              isFinal: true,
            ),
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(find.byType(Text).last);
    final spans = (text.textSpan! as TextSpan).children!;
    expect(spans[1].toPlainText(), 'The first part.');
    expect(spans[2].toPlainText(), ' The rest.');
    expect((spans[2] as TextSpan).style?.fontWeight, FontWeight.w300);
    expect(text.semanticsLabel, contains('Interrupted. Unspoken:  The rest.'));
  });

  testWidgets('nonprefix interrupted draft is labelled separately', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceTurnCaption(
            name: 'Assistant',
            turn: VoiceTurn(
              role: 'assistant',
              text: 'What I said.',
              intendedText: 'A different draft.',
              interrupted: true,
              at: DateTime.utc(2026),
              isFinal: true,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Unspoken: A different draft.'), findsOneWidget);
  });

  testWidgets('control label is visible and selected state is accessible', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceCallControl(
            tooltip: 'Use earpiece',
            label: 'Speaker on',
            toggled: true,
            fill: Colors.black,
            onTap: () {},
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      ),
    );
    expect(find.text('Speaker on'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Use earpiece')),
      matchesSemantics(
        label: 'Use earpiece',
        hasToggledState: true,
        isToggled: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
        textDirection: TextDirection.ltr,
      ),
    );
    semantics.dispose();
  });
}
