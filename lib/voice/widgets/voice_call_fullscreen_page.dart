import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_protocol.dart';
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
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                          child: Column(
                            children: [
                              Expanded(
                                child: c.cameraEnabled
                                    ? _cameraPreview(scheme)
                                    : Center(
                                        child: _visualization(compact, scheme),
                                      ),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (c.cameraEnabled) ...[
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: _visualization(true, scheme),
                                    ),
                                    const SizedBox(width: 10),
                                  ],
                                  Flexible(
                                    child: Text(
                                      failed
                                          ? (c.error ?? 'Call failed')
                                          : _status(c),
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            color: failed
                                                ? scheme.error
                                                : scheme.onSurface,
                                            fontWeight: FontWeight.w500,
                                          ),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
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
                        height: compact ? 62 : 108,
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
                                    child: VoiceTurnCaption(
                                      turn: turn,
                                      name: name,
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
                              width: 112,
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
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            VoiceCallControl(
                              semanticsId: 'voice-call-mute',
                              tooltip: c.micMuted ? 'Unmute' : 'Mute',
                              label: c.micMuted ? 'Unmute' : 'Mute',
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
                              label: 'Camera',
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
                                label: c.changingSpeaker
                                    ? 'Switching…'
                                    : _outputLabel(c),
                                toggled: c.speakerOn,
                                size: 52,
                                fill: c.speakerOn
                                    ? scheme.inverseSurface
                                    : scheme.surfaceContainerHighest,
                                onTap: failed || c.changingSpeaker
                                    ? null
                                    : () => unawaited(
                                        _action(
                                          () => c.setSpeakerOn(!c.speakerOn),
                                        ),
                                      ),
                                child: HugeIcon(
                                  c.speakerOn
                                      ? HugeIcons.volumeHigh
                                      : HugeIcons.smartPhone01,
                                  color: c.speakerOn
                                      ? scheme.onInverseSurface
                                      : scheme.onSurface,
                                ),
                              ),
                            VoiceCallControl(
                              semanticsId: 'voice-call-hang-up',
                              tooltip: failed ? 'Close' : 'End call',
                              label: failed ? 'Close' : 'End',
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

  Widget _visualization(bool compact, ColorScheme scheme) => Semantics(
    label: c.agentSpeaking ? 'Assistant speaking' : _status(c),
    child: ValueListenableBuilder<double>(
      valueListenable: c.audioLevel,
      builder: (context, level, _) => AnimatedContainer(
        key: const ValueKey('voice-visualization'),
        duration: kExpressiveShort,
        width: (compact ? 76.0 : 144.0) * (1 + level.clamp(0, 1) * .1),
        height: (compact ? 76.0 : 144.0) * (1 + level.clamp(0, 1) * .1),
        decoration: BoxDecoration(
          color: c.agentSpeaking
              ? scheme.primaryContainer
              : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(compact ? 28 : 54),
        ),
        child: Center(
          child: VoiceSpeakingBars(
            speaking: c.agentSpeaking,
            color: c.agentSpeaking
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
            size: (compact ? 32.0 : 64.0) * (1 + level.clamp(0, 1) * .2),
          ),
        ),
      ),
    ),
  );

  Widget _cameraPreview(ColorScheme scheme) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 440),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        key: const ValueKey('voice-camera-preview'),
        fit: StackFit.expand,
        children: [
          ColoredBox(color: scheme.surfaceContainerHigh),
          if (c.cameraTrack case final track?)
            lk.VideoTrackRenderer(
              track,
              fit: lk.VideoViewFit.cover,
              mirrorMode: c.cameraMirrored
                  ? lk.VideoViewMirrorMode.mirror
                  : lk.VideoViewMirrorMode.off,
            )
          else
            Center(
              child: Text(
                'Starting camera…',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          Positioned(
            top: 10,
            left: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text('Your camera'),
              ),
            ),
          ),
          if (c.cameraTrack != null)
            Positioned(
              bottom: 10,
              right: 10,
              child: VoiceCallControl(
                semanticsId: 'voice-switch-camera',
                tooltip: 'Switch camera',
                fill: scheme.surface,
                onTap: () => unawaited(_action(c.switchCamera)),
                child: HugeIcon(
                  HugeIcons.repeat,
                  color: scheme.onSurface,
                  size: 20,
                ),
              ),
            ),
        ],
      ),
    ),
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
              const SizedBox(height: 12),
              Text('Engine', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Applies to your next call.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final engine in VoiceCallEngine.values)
                ListTile(
                  title: Text(_engineTitle(engine)),
                  subtitle: Text(_engineSubtitle(engine)),
                  selected: engine == c.defaultEngine,
                  trailing: engine == c.defaultEngine
                      ? const HugeIcon(HugeIcons.tick02, size: 20)
                      : null,
                  onTap: engine == c.defaultEngine
                      ? null
                      : () => unawaited(
                          _action(() => c.setDefaultEngine(engine)),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _action(() => c.setVoice(selected));
  }

  static String _engineTitle(VoiceCallEngine engine) => switch (engine) {
    VoiceCallEngine.pipeline => 'Pipeline (standard)',
    VoiceCallEngine.inworldS2S => 'Inworld Speech-to-Speech',
  };

  static String _engineSubtitle(VoiceCallEngine engine) => switch (engine) {
    VoiceCallEngine.pipeline =>
      'Our STT → LLM → TTS stack with tools, cards and delegation.',
    VoiceCallEngine.inworldS2S =>
      "Inworld's realtime API with semantic turn detection. Conversation "
          'only: no tools, cards, or video description.',
  };

  static String _outputLabel(VoiceCallController c) => switch (c.outputRoute) {
    'bluetooth' => 'Bluetooth',
    'wired' => 'Headphones',
    'speaker' => 'Speaker on',
    'earpiece' => 'Earpiece',
    _ => 'Audio output',
  };

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

/// Keep the words that reached playback distinct from an interrupted draft.
class VoiceTurnCaption extends StatelessWidget {
  const VoiceTurnCaption({super.key, required this.turn, required this.name});
  final VoiceTurn turn;
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final intended = turn.intendedText;
    final showDraft =
        !turn.isUser &&
        turn.interrupted &&
        intended != null &&
        intended != turn.text;
    final samePrefix = showDraft && intended.startsWith(turn.text);
    final style = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface);
    final dim = TextStyle(
      color: scheme.onSurfaceVariant.withValues(alpha: .65),
      fontWeight: FontWeight.w300,
    );
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${turn.isUser ? 'You' : name}: ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: turn.text),
          if (showDraft)
            TextSpan(
              text: samePrefix
                  ? intended.substring(turn.text.length)
                  : '\nUnspoken: $intended',
              style: dim,
            ),
        ],
      ),
      style: style,
      semanticsLabel: showDraft
          ? '${turn.isUser ? 'You' : name}: ${turn.text}. Interrupted. Unspoken: ${samePrefix ? intended.substring(turn.text.length) : intended}'
          : null,
    );
  }
}
