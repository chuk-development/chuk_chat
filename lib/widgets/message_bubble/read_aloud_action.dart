// lib/widgets/message_bubble/read_aloud_action.dart
//
// The read-aloud button of an AI answer. It follows the phase of
// [TtsAudioService]: a progress ring while the audio loads, pause while it
// plays, resume while it is paused.
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/tts_audio_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

/// The text read aloud for [messageText]: what the bubble shows, trimmed.
String readAloudTextFor(String messageText) =>
    stripToolCallBlocksForDisplay(messageText).trim();

/// The button for an answer whose read-aloud text is [speechText].
///
/// Only the answer equal to [activeText] shows [phase]; every other answer
/// shows the idle "Read aloud" button.
MessageBubbleAction readAloudAction({
  required String speechText,
  required String? activeText,
  required TtsPhase phase,
  required Future<void> Function(String) onSpeak,
}) {
  final TtsPhase shown = activeText == speechText ? phase : TtsPhase.idle;
  void onPressed() => unawaited(onSpeak(speechText));
  return switch (shown) {
    TtsPhase.idle => MessageBubbleAction(
      icon: Icons.volume_up_outlined,
      tooltip: 'Read aloud',
      label: 'Read aloud',
      onPressed: onPressed,
    ),
    TtsPhase.loading => MessageBubbleAction(
      icon: Icons.volume_up_outlined,
      tooltip: 'Loading audio, tap to cancel',
      label: 'Cancel',
      isLoading: true,
      onPressed: onPressed,
    ),
    TtsPhase.playing => MessageBubbleAction(
      icon: Icons.pause_circle_outline,
      tooltip: 'Pause reading',
      label: 'Pause',
      onPressed: onPressed,
    ),
    TtsPhase.paused => MessageBubbleAction(
      icon: Icons.play_arrow_rounded,
      tooltip: 'Resume reading',
      label: 'Resume',
      onPressed: onPressed,
    ),
  };
}

/// [actions] of an AI answer with the read-aloud button after "Copy".
///
/// Adds nothing while the answer streams or has no text to read. The list
/// from `MessageActionsHandler.buildActionsForMessage` starts with "Copy"
/// whenever the answer has text, so the button takes the second place.
List<MessageBubbleAction> withReadAloudAction(
  List<MessageBubbleAction> actions, {
  required String messageText,
  required bool isUser,
  required bool isStreaming,
  required String? activeText,
  required TtsPhase phase,
  required Future<void> Function(String) onSpeak,
}) {
  if (isUser || isStreaming || messageText.trim().isEmpty) return actions;
  final String speechText = readAloudTextFor(messageText);
  if (speechText.isEmpty) return actions;
  final MessageBubbleAction button = readAloudAction(
    speechText: speechText,
    activeText: activeText,
    phase: phase,
    onSpeak: onSpeak,
  );
  final int at = actions.isEmpty ? 0 : 1;
  return <MessageBubbleAction>[...actions]..insert(at, button);
}
