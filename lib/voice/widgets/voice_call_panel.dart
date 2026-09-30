// lib/voice/widgets/voice_call_panel.dart
//
// The compact live-call panel: it sits above the composer (or at the top of
// the chat) while a call runs. Status with the agent-speaking bars and the
// call clock, the live transcript of this call, mute, speaker (phones), and
// the red hang-up.
//
// docs/DESIGN.md: panel corner 18, flat fill, no shadow, HugeIcons, the
// app's squircle controls.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/widgets/voice_agent_card.dart';
import 'package:chuk_chat/voice/widgets/voice_call_controls.dart';

class VoiceCallPanel extends StatelessWidget {
  const VoiceCallPanel({super.key, this.chatId, this.controller});

  /// Show only the call of this chat. Null shows whatever call runs.
  final String? chatId;

  /// Defaults to [VoiceCallController.instance].
  final VoiceCallController? controller;

  /// The transcript's tallest height before it scrolls.
  static const double transcriptMaxHeight = 132;

  /// Shorter when cards share the panel.
  static const double transcriptWithCardsMaxHeight = 88;

  /// The height of the card strip; a taller card scrolls inside.
  static const double cardStripHeight = 196;

  @override
  Widget build(BuildContext context) {
    final VoiceCallController c = controller ?? VoiceCallController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final bool mine = chatId == null || c.chatId == chatId;
        final bool visible =
            mine && (c.isActive || c.phase == VoiceCallPhase.failed);
        return AnimatedSize(
          duration: kExpressiveShort,
          curve: kExpressiveDecelerate,
          alignment: Alignment.bottomCenter,
          child: visible ? _PanelBody(controller: c) : const SizedBox.shrink(),
        );
      },
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.controller});

  final VoiceCallController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final VoiceCallController c = controller;
    final bool failed = c.phase == VoiceCallPhase.failed;
    return Semantics(
      container: true,
      label: 'Voice call',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        child: failed
            ? _FailedRow(controller: c)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _StatusRow(controller: c),
                  if (c.runningTools.isNotEmpty &&
                      c.phase == VoiceCallPhase.live) ...<Widget>[
                    const SizedBox(height: 6),
                    _ToolLine(tool: c.runningTools.last),
                  ],
                  if (c.turns.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    _Transcript(
                      turns: c.turns,
                      assistantLabel: _assistantLabel(c),
                      maxHeight: c.cards.isEmpty
                          ? VoiceCallPanel.transcriptMaxHeight
                          : VoiceCallPanel.transcriptWithCardsMaxHeight,
                    ),
                  ],
                  if (c.cards.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    _CardStrip(cards: c.cards),
                  ],
                ],
              ),
      ),
    );
  }

  static String _assistantLabel(VoiceCallController c) {
    final String? name = c.agentName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return c.mode == VoiceCallMode.agents ? 'Agent' : 'Assistant';
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.controller});

  final VoiceCallController controller;

  String _status(VoiceCallController c) {
    switch (c.phase) {
      case VoiceCallPhase.connecting:
        return 'Connecting…';
      case VoiceCallPhase.ending:
        return 'Hanging up…';
      case VoiceCallPhase.live:
        if (!c.agentPresent) return 'Waiting for the agent…';
        if (c.agentSpeaking) return 'Speaking';
        if (c.agentThinking) return 'Thinking';
        return c.micMuted ? 'Muted' : 'Listening';
      case VoiceCallPhase.idle:
      case VoiceCallPhase.ended:
      case VoiceCallPhase.failed:
        return 'Call ended';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final VoiceCallController c = controller;
    final bool live = c.phase == VoiceCallPhase.live;
    return Row(
      children: <Widget>[
        VoiceSpeakingBars(
          speaking: live && c.agentSpeaking,
          color: scheme.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    _status(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (live && c.startedAt != null) ...<Widget>[
                  const SizedBox(width: 8),
                  _CallClock(startedAt: c.startedAt!),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        VoiceCallControl(
          semanticsId: 'voice-call-mute',
          tooltip: c.micMuted ? 'Unmute' : 'Mute',
          toggled: c.micMuted,
          fill: c.micMuted
              ? scheme.inverseSurface
              : scheme.surfaceContainerHighest,
          onTap: c.phase == VoiceCallPhase.ending
              ? null
              : () => c.setMicMuted(!c.micMuted),
          child: VoiceMicGlyph(
            muted: c.micMuted,
            color: c.micMuted
                ? scheme.onInverseSurface
                : scheme.onSurfaceVariant,
            gapColor: c.micMuted
                ? scheme.inverseSurface
                : scheme.surfaceContainerHighest,
          ),
        ),
        if (c.canSwitchSpeaker) ...<Widget>[
          const SizedBox(width: 8),
          _SpeakerToggle(controller: c),
        ],
        const SizedBox(width: 8),
        VoiceCallControl(
          semanticsId: 'voice-call-hang-up',
          tooltip: 'Hang up',
          fill: scheme.error,
          onTap: c.phase == VoiceCallPhase.ending ? null : () => c.end(),
          child: VoiceHangUpGlyph(color: scheme.onError),
        ),
      ],
    );
  }
}

/// Speaker or earpiece. Words, not a glyph: the icon set has no speaker, and
/// a Material glyph would break the one-set rule.
class _SpeakerToggle extends StatelessWidget {
  const _SpeakerToggle({required this.controller});

  final VoiceCallController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool on = controller.speakerOn;
    return Semantics(
      identifier: 'voice-call-speaker',
      button: true,
      toggled: on,
      label: 'Speaker',
      child: MorphTap(
        onTap: () => controller.setSpeakerOn(!on),
        color: on ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: ExcludeSemantics(
          child: Text(
            'Speaker',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: on ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// mm:ss since the call went live, ticking once a second.
class _CallClock extends StatefulWidget {
  const _CallClock({required this.startedAt});

  final DateTime startedAt;

  @override
  State<_CallClock> createState() => _CallClockState();
}

class _CallClockState extends State<_CallClock> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Text(
      formatVoiceCallClock(DateTime.now().difference(widget.startedAt)),
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}

/// `mm:ss`, or `h:mm:ss` past an hour.
String formatVoiceCallClock(Duration d) {
  final Duration v = d.isNegative ? Duration.zero : d;
  final String mm = v.inMinutes.remainder(60).toString().padLeft(2, '0');
  final String ss = v.inSeconds.remainder(60).toString().padLeft(2, '0');
  return v.inHours > 0 ? '${v.inHours}:$mm:$ss' : '$mm:$ss';
}

/// "Searching the web…" while a worker tool runs.
class _ToolLine extends StatelessWidget {
  const _ToolLine({required this.tool});

  final VoiceToolActivity tool;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      liveRegion: true,
      child: Row(
        children: <Widget>[
          HugeIcon(HugeIcons.wrench01, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${tool.label}…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The agent's cards, newest first, side by side. A card taller than the
/// strip scrolls inside itself.
class _CardStrip extends StatelessWidget {
  const _CardStrip({required this.cards});

  final List<VoiceCard> cards;

  @override
  Widget build(BuildContext context) {
    final List<VoiceCard> newestFirst = cards.reversed.toList(growable: false);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double width = newestFirst.length == 1
            ? box.maxWidth
            : (box.maxWidth * 0.86).clamp(0.0, 320.0);
        return SizedBox(
          height: VoiceCallPanel.cardStripHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: newestFirst.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int i) => SizedBox(
              key: ValueKey<String>('voice-card-${newestFirst[i].id}'),
              width: width,
              child: SingleChildScrollView(
                child: VoiceAgentCard(card: newestFirst[i]),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.turns,
    required this.assistantLabel,
    required this.maxHeight,
  });

  final List<VoiceTurn> turns;
  final String assistantLabel;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    // Reversed: the newest line is index 0 at the bottom, so the list stays
    // pinned to the latest words without a scroll controller.
    final List<VoiceTurn> newestFirst = turns.reversed.toList(growable: false);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView.builder(
        reverse: true,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: newestFirst.length,
        itemBuilder: (BuildContext context, int i) => Padding(
          padding: EdgeInsets.only(top: i == newestFirst.length - 1 ? 0 : 6),
          child: VoiceTurnLine(
            turn: newestFirst[i],
            assistantLabel: assistantLabel,
          ),
        ),
      ),
    );
  }
}

/// One transcript line: who spoke, then what was said. A partial line is
/// quieter until its final text arrives.
class VoiceTurnLine extends StatelessWidget {
  const VoiceTurnLine({
    super.key,
    required this.turn,
    required this.assistantLabel,
    this.userLabel = 'You',
  });

  final VoiceTurn turn;
  final String assistantLabel;
  final String userLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? body = theme.textTheme.bodyMedium;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '${turn.isUser ? userLabel : assistantLabel}  ',
            style: body?.copyWith(
              fontWeight: FontWeight.w700,
              color: turn.isUser ? scheme.onSurfaceVariant : scheme.primary,
            ),
          ),
          TextSpan(
            text: turn.text,
            style: body?.copyWith(
              color: turn.isFinal
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.controller});

  final VoiceCallController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      children: <Widget>[
        HugeIcon(HugeIcons.alertCircle, size: 20, color: scheme.error),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(
              controller.error ?? 'The call failed',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        VoiceCallControl(
          semanticsId: 'voice-call-dismiss',
          tooltip: 'Dismiss',
          fill: scheme.surfaceContainerHighest,
          onTap: controller.dismiss,
          child: HugeIcon(
            HugeIcons.cancel01,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
