// lib/voice/widgets/voice_call_record_card.dart
//
// A finished call inside the chat history. Collapsed it is one line —
// "Voice call · 3 min · 12 turns" and the time; a tap opens the full
// transcript. docs/DESIGN.md: card corner 18, flat fill, reading measure 720.

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/widgets/voice_agent_card.dart';
import 'package:chuk_chat/voice/widgets/voice_call_panel.dart';

class VoiceCallRecordCard extends StatefulWidget {
  const VoiceCallRecordCard(
    this.record, {
    super.key,
    this.assistantLabel,
    this.initiallyExpanded = false,
  });

  final VoiceCallRecord record;

  /// The name on the agent's lines. Null: "Agent" in an Agents thread,
  /// "Assistant" in a chat.
  final String? assistantLabel;
  final bool initiallyExpanded;

  @override
  State<VoiceCallRecordCard> createState() => _VoiceCallRecordCardState();
}

class _VoiceCallRecordCardState extends State<VoiceCallRecordCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final VoiceCallRecord record = widget.record;
    final String assistant =
        widget.assistantLabel ??
        (record.mode == VoiceCallMode.agents ? 'Agent' : 'Assistant');
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    final String time = l10n.formatTimeOfDay(
      TimeOfDay.fromDateTime(record.startedAt),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final BorderRadius radius = BorderRadius.circular(18);
    final bool hasContent = record.turns.isNotEmpty || record.cards.isNotEmpty;
    final List<Object> timeline = voiceCallTimeline(record);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: hasContent
              ? () => setState(() => _expanded = !_expanded)
              : null,
          child: AnimatedSize(
            duration: kExpressiveShort,
            curve: kExpressiveDecelerate,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Semantics(
                    button: hasContent,
                    expanded: hasContent ? _expanded : null,
                    child: Row(
                      children: <Widget>[
                        HugeIcon(
                          HugeIcons.call02,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            describeVoiceCall(record),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          time,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (hasContent) ...<Widget>[
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0,
                            duration: kExpressiveShort,
                            curve: kExpressiveDecelerate,
                            child: HugeIcon(
                              HugeIcons.arrowDown01,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_expanded) ...<Widget>[
                    const SizedBox(height: 10),
                    for (int i = 0; i < timeline.length; i++)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                        child: switch (timeline[i]) {
                          final VoiceTurn turn => VoiceTurnLine(
                            turn: turn,
                            assistantLabel: assistant,
                          ),
                          final VoiceCard card => VoiceAgentCard(card: card),
                          _ => const SizedBox.shrink(),
                        },
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The record's turns and cards in one list, by time. A card sorts after a
/// turn that started at the same moment (the words came first).
List<Object> voiceCallTimeline(VoiceCallRecord record) {
  final List<(DateTime, int, Object)> items = <(DateTime, int, Object)>[
    for (final VoiceTurn t in record.turns) (t.at, 0, t),
    for (final VoiceCard c in record.cards) (c.at, 1, c),
  ];
  // Stable: equal keys keep the order they were written in.
  final List<(DateTime, int, Object)> sorted = <(DateTime, int, Object)>[];
  for (final (DateTime, int, Object) item in items) {
    int at = sorted.length;
    while (at > 0) {
      final (DateTime, int, Object) prev = sorted[at - 1];
      final int byTime = prev.$1.compareTo(item.$1);
      if (byTime < 0 || (byTime == 0 && prev.$2 <= item.$2)) break;
      at--;
    }
    sorted.insert(at, item);
  }
  return <Object>[for (final (DateTime, int, Object) i in sorted) i.$3];
}

/// "Voice call · 3 min · 12 turns" — the collapsed line of a record.
String describeVoiceCall(VoiceCallRecord record) {
  final int seconds = record.duration.inSeconds;
  final String length = seconds < 60
      ? '$seconds s'
      : '${(seconds / 60).round()} min';
  final int count = record.turns.length;
  final String turns = count == 1 ? '1 turn' : '$count turns';
  return 'Voice call · $length · $turns';
}
