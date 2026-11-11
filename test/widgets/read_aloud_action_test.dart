import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tts_audio_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/message_bubble/read_aloud_action.dart';

MessageBubbleAction _action(TtsPhase phase, {String? activeText = 'Hello'}) =>
    readAloudAction(
      speechText: 'Hello',
      activeText: activeText,
      phase: phase,
      onSpeak: (_) async {},
    );

void main() {
  test('each phase draws its own button', () {
    expect(_action(TtsPhase.idle).icon, Icons.volume_up_outlined);
    expect(_action(TtsPhase.loading).isLoading, isTrue);
    expect(_action(TtsPhase.playing).icon, Icons.pause_circle_outline);
    expect(_action(TtsPhase.paused).icon, Icons.play_arrow_rounded);
  });

  test('another answer keeps the idle button', () {
    final action = _action(TtsPhase.playing, activeText: 'Other');
    expect(action.icon, Icons.volume_up_outlined);
    expect(action.isLoading, isFalse);
  });

  test('the button sits after Copy and taps speak the shown text', () {
    String? spoken;
    final copy = MessageBubbleAction(
      icon: Icons.copy,
      tooltip: 'Copy message',
      onPressed: () {},
    );
    final retry = MessageBubbleAction(
      icon: Icons.replay,
      tooltip: 'Retry response',
      onPressed: () {},
    );
    final actions = withReadAloudAction(
      [copy, retry],
      messageText: '  Hello  ',
      isUser: false,
      isStreaming: false,
      activeText: null,
      phase: TtsPhase.idle,
      onSpeak: (text) async => spoken = text,
    );
    expect(actions.map((a) => a.tooltip), [
      'Copy message',
      'Read aloud',
      'Retry response',
    ]);
    actions[1].onPressed();
    expect(spoken, 'Hello');
  });

  test('no button while streaming or for user messages', () {
    for (final (isUser, isStreaming) in [(true, false), (false, true)]) {
      final actions = withReadAloudAction(
        const [],
        messageText: 'Hello',
        isUser: isUser,
        isStreaming: isStreaming,
        activeText: null,
        phase: TtsPhase.idle,
        onSpeak: (_) async {},
      );
      expect(actions, isEmpty);
    }
  });
}
