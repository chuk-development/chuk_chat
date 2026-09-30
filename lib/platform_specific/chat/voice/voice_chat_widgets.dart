// lib/platform_specific/chat/voice/voice_chat_widgets.dart
//
// What a chat screen draws for a voice call: the finished calls between its
// messages, and the live panel above its composer. Built only when
// `voiceCallUiEnabled` is true.

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart'
    show messageRowTime;
import 'package:chuk_chat/platform_specific/chat/voice/voice_record_placement.dart';
import 'package:chuk_chat/voice/voice_call.dart';

/// Gap between a call card and the rows around it: the gap between two runs
/// of bubbles (docs/DESIGN.md §9), so a card reads as its own group.
const double kVoiceRecordGap = 14;

/// Places [records] against [messages] by the rows' own clocks
/// ([messageRowTime]): a call goes above the first message sent after it
/// started.
VoiceRecordPlacement<VoiceCallRecord> placeVoiceRecords(
  List<Map<String, String>> messages,
  List<VoiceCallRecord> records,
) {
  if (records.isEmpty) return VoiceRecordPlacement.empty<VoiceCallRecord>();
  return placeRecordsByTime<VoiceCallRecord>(
    messageTimes: <DateTime?>[
      for (final Map<String, String> m in messages) messageRowTime(m),
    ],
    records: records,
    timeOf: (VoiceCallRecord r) => r.startedAt,
  );
}

/// [item] (message row [index] of [messageCount]) with the call cards that
/// belong above it, and — for the last row — the cards after every message.
/// Returns [item] itself when no card belongs here, so a chat without calls
/// builds exactly the rows it built before.
Widget withVoiceRecords({
  required Widget item,
  required int index,
  required int messageCount,
  required VoiceRecordPlacement<VoiceCallRecord> placement,
}) {
  if (placement.isEmpty) return item;
  final List<VoiceCallRecord> above = placement.before(index);
  final List<VoiceCallRecord> below = index == messageCount - 1
      ? placement.trailing
      : const <VoiceCallRecord>[];
  if (above.isEmpty && below.isEmpty) return item;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (final VoiceCallRecord r in above) _card(r),
      item,
      for (final VoiceCallRecord r in below) _card(r),
    ],
  );
}

Widget _card(VoiceCallRecord record) => Padding(
  key: ValueKey<String>(
    'voice-call-record-${record.startedAt.microsecondsSinceEpoch}',
  ),
  padding: const EdgeInsets.symmetric(vertical: kVoiceRecordGap / 2),
  child: Align(
    alignment: Alignment.center,
    child: VoiceCallRecordCard(record),
  ),
);

/// The live call panel of [chatId] with its gap to the composer under it.
/// Draws nothing while no call runs (or just failed) for this chat.
class VoiceCallPanelSlot extends StatelessWidget {
  const VoiceCallPanelSlot({super.key, required this.chatId, this.gap = 8});

  final String? chatId;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final String? id = chatId;
    if (id == null || id.isEmpty) return const SizedBox.shrink();
    final VoiceCallController c = VoiceCallController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? panel) {
        final bool visible =
            c.chatId == id &&
            (c.isActive || c.phase == VoiceCallPhase.failed);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[panel!, if (visible) SizedBox(height: gap)],
        );
      },
      child: VoiceCallPanel(chatId: id),
    );
  }
}
