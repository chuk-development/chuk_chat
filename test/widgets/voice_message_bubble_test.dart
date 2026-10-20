import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/message_bubble/voice_message_bubble.dart';

import '../support/test_app.dart';

const String _transcript =
    'Okay so I was thinking about the trip next week and I would like to '
    'know what the weather will be like in Kiel on Friday and Saturday.';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpBubble(
    WidgetTester tester, {
    required bool voice,
    Duration? duration,
    List<MessageBubbleAction> actions = const <MessageBubbleAction>[],
  }) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: MessageBubble(
            message: _transcript,
            isUser: true,
            maxWidth: 400,
            isVoiceInput: voice,
            voiceInputDuration: duration,
            userMessageActions: actions,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('collapsed: waveform, duration, no transcript', (tester) async {
    await pumpBubble(
      tester,
      voice: true,
      duration: const Duration(seconds: 83),
    );
    expect(find.byType(VoiceMessageBubble), findsOneWidget);
    expect(find.byKey(kVoiceBubbleHeaderKey), findsOneWidget);
    expect(find.text('1:23'), findsOneWidget);
    expect(find.text(_transcript), findsNothing);
    expect(find.byKey(kVoiceBubbleTranscriptKey), findsNothing);
  });

  testWidgets('tap opens the transcript, next tap folds it', (tester) async {
    await pumpBubble(tester, voice: true);
    // Unknown duration: no time label.
    expect(find.textContaining(RegExp(r'^\d+:\d\d$')), findsNothing);

    await tester.tap(find.byKey(kVoiceBubbleHeaderKey));
    await tester.pumpAndSettle();
    expect(find.text(_transcript), findsOneWidget);

    await tester.tap(find.byKey(kVoiceBubbleHeaderKey));
    await tester.pumpAndSettle();
    expect(find.text(_transcript), findsNothing);
  });

  testWidgets('open bubble shows the user actions (copy/edit)', (tester) async {
    int copied = 0;
    await pumpBubble(
      tester,
      voice: true,
      actions: <MessageBubbleAction>[
        MessageBubbleAction(
          icon: Icons.copy,
          tooltip: 'Copy',
          onPressed: () => copied++,
        ),
      ],
    );
    expect(find.byTooltip('Copy'), findsNothing);
    await tester.tap(find.byKey(kVoiceBubbleHeaderKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy'));
    expect(copied, 1);
  });

  testWidgets('typed message renders as before', (tester) async {
    await pumpBubble(tester, voice: false);
    expect(find.byType(VoiceMessageBubble), findsNothing);
    expect(find.text(_transcript), findsOneWidget);
  });

  testWidgets('fits 360 px at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            textScaler: TextScaler.linear(1.3),
          ),
          child: Scaffold(
            body: MessageBubble(
              message: _transcript,
              isUser: true,
              maxWidth: 288,
              isVoiceInput: true,
              voiceInputDuration: const Duration(minutes: 12, seconds: 5),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('waveform bars are stable per text and in range', () {
    final List<double> a = voiceBubbleBars('hello');
    expect(voiceBubbleBars('hello'), a);
    expect(voiceBubbleBars('hello!'), isNot(a));
    expect(a, everyElement(inInclusiveRange(0.25, 1.0)));
    expect(a.length, kVoiceBubbleBarCount);
  });

  test('duration format', () {
    expect(formatVoiceDuration(const Duration(milliseconds: 300)), '0:01');
    expect(formatVoiceDuration(const Duration(seconds: 65)), '1:05');
    expect(formatVoiceDuration(const Duration(seconds: 3725)), '1:02:05');
  });
}
