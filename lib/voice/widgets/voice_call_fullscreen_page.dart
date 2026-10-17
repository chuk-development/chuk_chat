import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/widgets/voice_agent_card.dart';
import 'package:chuk_chat/voice/widgets/voice_call_controls.dart';

/// Back returns to chat while the call continues. Hang-up ends the call.
class VoiceCallFullscreenPage extends StatefulWidget {
  const VoiceCallFullscreenPage({super.key, this.controller});
  final VoiceCallController? controller;

  static const String routeName = '/voice-call';
  static final Map<NavigatorState, Future<void>> _open = {};

  /// One fullscreen call route per app navigator, including incoming calls.
  static Future<void> show(
    BuildContext context, {
    VoiceCallController? controller,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final existing = _open[navigator];
    if (existing != null) return existing;
    final result = navigator.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: routeName),
        fullscreenDialog: true,
        builder: (_) => VoiceCallFullscreenPage(controller: controller),
      ),
    );
    final completion = result.then<void>((_) {});
    _open[navigator] = completion;
    unawaited(completion.whenComplete(() => _open.remove(navigator)));
    return completion;
  }

  @override
  State<VoiceCallFullscreenPage> createState() =>
      _VoiceCallFullscreenPageState();
}

class _VoiceCallFullscreenPageState extends State<VoiceCallFullscreenPage> {
  VoiceCallController get c =>
      widget.controller ?? VoiceCallController.instance;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_onState);
  }

  void _onState() {
    if (c.phase != VoiceCallPhase.ended || _closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      final navigator = Navigator.of(context);
      navigator.popUntil(
        (candidate) => candidate == route || candidate.isFirst,
      );
      if (route?.isCurrent == true) navigator.maybePop();
    });
  }

  @override
  void dispose() {
    c.removeListener(_onState);
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update the call. Please try again.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final failed = c.phase == VoiceCallPhase.failed;
      final name = c.agentName?.trim().isNotEmpty == true
          ? c.agentName!.trim()
          : 'Assistant';
      return ExpressiveScreen(
        title: name,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              c.startedAt == null
                  ? ''
                  : formatVoiceDuration(
                      DateTime.now().difference(c.startedAt!),
                    ),
            ),
          ),
        ],
        builder: (context) => SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 520;
              final content = Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Semantics(
                                label: c.agentSpeaking
                                    ? 'Assistant speaking'
                                    : _status(c),
                                child: ValueListenableBuilder<double>(
                                  valueListenable: c.audioLevel,
                                  builder: (context, level, _) =>
                                      AnimatedContainer(
                                        key: const ValueKey(
                                          'voice-visualization',
                                        ),
                                        duration: kExpressiveShort,
                                        width:
                                            (compact ? 108.0 : 170.0) *
                                            (1 + level.clamp(0, 1) * 0.12),
                                        height:
                                            (compact ? 108.0 : 170.0) *
                                            (1 + level.clamp(0, 1) * 0.12),
                                        decoration: BoxDecoration(
                                          color: c.agentSpeaking
                                              ? scheme.primaryContainer
                                              : scheme.surfaceContainerHigh,
                                          borderRadius: BorderRadius.circular(
                                            c.agentSpeaking ? 58 : 70,
                                          ),
                                        ),
                                        child: Center(
                                          child: VoiceSpeakingBars(
                                            speaking: c.agentSpeaking,
                                            color: c.agentSpeaking
                                                ? scheme.onPrimaryContainer
                                                : scheme.onSurfaceVariant,
                                            size:
                                                (compact ? 48.0 : 70.0) *
                                                (1 + level.clamp(0, 1) * 0.25),
                                          ),
                                        ),
                                      ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                child: Text(
                                  failed
                                      ? (c.error ?? 'Call failed')
                                      : _status(c),
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: failed
                                        ? scheme.error
                                        : scheme.onSurface,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (c.runningTools.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    c.runningTools.last.status,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (c.cards.isNotEmpty && !compact)
                        SizedBox(
                          height: 136,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: c.cards.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 10),
                            itemBuilder: (_, index) => SizedBox(
                              width:
                                  constraints.maxWidth
                                      .clamp(0, 340)
                                      .toDouble() -
                                  40,
                              child: VoiceAgentCard(card: c.cards[index]),
                            ),
                          ),
                        ),
                      SizedBox(
                        key: const ValueKey('voice-compact-transcript'),
                        height: compact ? 62 : 100,
                        child: c.turns.isEmpty
                            ? Center(
                                child: Text(
                                  failed
                                      ? 'Return to your chat'
                                      : 'Say something…',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                reverse: true,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 8,
                                ),
                                itemCount: c.turns.length,
                                itemBuilder: (_, index) {
                                  final turn =
                                      c.turns[c.turns.length - index - 1];
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text:
                                                '${turn.isUser ? 'You' : name}: ',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          TextSpan(text: turn.text),
                                        ],
                                      ),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          children: [
                            const HugeIcon(HugeIcons.volumeHigh, size: 18),
                            Expanded(
                              child: Slider(
                                value: c.volume,
                                label: '${(c.volume * 100).round()}%',
                                semanticFormatterCallback: (value) =>
                                    'Playback volume ${(value * 100).round()} percent',
                                onChanged: failed
                                    ? null
                                    : (value) => unawaited(
                                        _action(() => c.setVolume(value)),
                                      ),
                              ),
                            ),
                            SizedBox(
                              width: 128,
                              child: TextButton.icon(
                                icon: const HugeIcon(
                                  HugeIcons.userCircle,
                                  size: 20,
                                ),
                                label: Text(
                                  c.changingVoice ? 'Changing…' : c.voiceId,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onPressed: failed || c.changingVoice
                                    ? null
                                    : _chooseVoice,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Wrap(
                          spacing: 14,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            VoiceCallControl(
                              semanticsId: 'voice-call-mute',
                              tooltip: c.micMuted ? 'Unmute' : 'Mute',
                              toggled: c.micMuted,
                              size: 52,
                              fill: c.micMuted
                                  ? scheme.inverseSurface
                                  : scheme.surfaceContainerHighest,
                              onTap: failed
                                  ? null
                                  : () => unawaited(
                                      _action(() => c.setMicMuted(!c.micMuted)),
                                    ),
                              child: VoiceMicGlyph(
                                muted: c.micMuted,
                                size: 22,
                                color: c.micMuted
                                    ? scheme.onInverseSurface
                                    : scheme.onSurface,
                                gapColor: c.micMuted
                                    ? scheme.inverseSurface
                                    : scheme.surfaceContainerHighest,
                              ),
                            ),
                            VoiceCallControl(
                              semanticsId: 'voice-call-video',
                              tooltip: c.cameraEnabled
                                  ? 'Turn video off'
                                  : 'Turn video on',
                              toggled: c.cameraEnabled,
                              size: 52,
                              fill: c.cameraEnabled
                                  ? scheme.secondaryContainer
                                  : scheme.surfaceContainerHighest,
                              onTap: failed
                                  ? null
                                  : () => unawaited(
                                      _action(
                                        () => c.setCameraEnabled(
                                          !c.cameraEnabled,
                                        ),
                                      ),
                                    ),
                              child: HugeIcon(
                                HugeIcons.video01,
                                color: scheme.onSurface,
                              ),
                            ),
                            if (c.canSwitchSpeaker)
                              VoiceCallControl(
                                semanticsId: 'voice-call-speaker',
                                tooltip: c.speakerOn
                                    ? 'Use earpiece'
                                    : 'Use speaker',
                                toggled: c.speakerOn,
                                size: 52,
                                fill: c.speakerOn
                                    ? scheme.secondaryContainer
                                    : scheme.surfaceContainerHighest,
                                onTap: failed
                                    ? null
                                    : () => unawaited(
                                        _action(
                                          () => c.setSpeakerOn(!c.speakerOn),
                                        ),
                                      ),
                                child: HugeIcon(
                                  HugeIcons.volumeHigh,
                                  color: scheme.onSurface,
                                ),
                              ),
                            VoiceCallControl(
                              semanticsId: 'voice-call-hang-up',
                              tooltip: failed ? 'Close' : 'End call',
                              size: 52,
                              fill: scheme.error,
                              onTap: () async {
                                if (!failed) await c.end();
                                if (context.mounted && !_closing) {
                                  Navigator.of(context).maybePop();
                                }
                              },
                              child: VoiceHangUpGlyph(
                                color: scheme.onError,
                                size: 22,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
              return constraints.maxHeight < 420
                  ? SingleChildScrollView(
                      child: SizedBox(height: 420, child: content),
                    )
                  : content;
            },
          ),
        ),
      );
    },
  );

  Future<void> _chooseVoice() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          builder: (context, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Choose voice',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              for (final voice in c.availableVoices)
                ListTile(
                  title: Text(voice),
                  selected: voice == c.voiceId,
                  subtitle: voice == c.defaultVoiceId
                      ? const Text('Default for new calls')
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (voice == c.voiceId)
                        const HugeIcon(HugeIcons.tick02, size: 20),
                      IconButton(
                        tooltip: voice == c.defaultVoiceId
                            ? 'Default voice'
                            : 'Use $voice as default',
                        isSelected: voice == c.defaultVoiceId,
                        icon: const HugeIcon(HugeIcons.star, size: 20),
                        color: voice == c.defaultVoiceId
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        onPressed: voice == c.defaultVoiceId
                            ? null
                            : () => unawaited(
                                _action(() => c.setDefaultVoice(voice)),
                              ),
                      ),
                    ],
                  ),
                  onTap: () => Navigator.pop(context, voice),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _action(() => c.setVoice(selected));
  }

  static String _status(VoiceCallController c) {
    if (c.phase == VoiceCallPhase.connecting) return 'Connecting…';
    if (c.phase == VoiceCallPhase.ending) return 'Ending call…';
    if (c.agentSpeaking) return 'Speaking';
    if (c.agentThinking) return 'Thinking';
    if (c.micMuted) return 'Muted';
    return 'Listening';
  }
}

String formatVoiceDuration(Duration value) =>
    '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
