import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_protocol.dart';
import 'package:chuk_chat/voice/widgets/voice_bars.dart';
import 'package:chuk_chat/voice/widgets/voice_call_buttons.dart';
import 'package:chuk_chat/voice/widgets/voice_call_controls.dart';
import 'package:chuk_chat/voice/widgets/voice_call_stage.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';

/// Back (and the chat button) return to the chat while the call continues.
/// The close button ends the call.
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

/// Where the call sound goes, as the route button and its menu show it.
enum _Route { earpiece, speaker, wired, bluetooth }

class _VoiceCallFullscreenPageState extends State<VoiceCallFullscreenPage> {
  VoiceCallController get c =>
      widget.controller ?? VoiceCallController.instance;
  bool _closing = false;
  Timer? _clock;
  final Set<String> _hiddenCards = <String>{};

  @override
  void initState() {
    super.initState();
    c.addListener(_onState);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c.startedAt != null) setState(() {});
    });
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
    _clock?.cancel();
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

  _Route? get _route {
    switch (c.outputRoute) {
      case 'wired':
        return _Route.wired;
      case 'bluetooth':
        return _Route.bluetooth;
      case 'speaker':
        return _Route.speaker;
      case 'earpiece':
        return _Route.earpiece;
    }
    if (!c.canSwitchSpeaker) return null;
    return c.speakerOn ? _Route.speaker : _Route.earpiece;
  }

  static HugeIconData _routeGlyph(_Route route) => switch (route) {
    _Route.earpiece => HugeIcons.smartPhone01,
    _Route.speaker => HugeIcons.volumeHigh,
    _Route.wired => HugeIcons.headphones,
    _Route.bluetooth => HugeIcons.bluetooth,
  };

  static String _routeLabel(_Route route) => switch (route) {
    _Route.earpiece => 'Earpiece',
    _Route.speaker => 'Speaker on',
    _Route.wired => 'Headphones',
    _Route.bluetooth => 'Bluetooth',
  };

  /// The route menu: one framed list over the button. A plugged-in headset
  /// always wins, so it is listed but cannot be left from here.
  Future<void> _pickRoute(BuildContext buttonContext, _Route current) async {
    final ThemeData theme = Theme.of(context);
    final Color ink = theme.colorScheme.onSurface;
    final List<_Route> routes = <_Route>[
      if (current == _Route.wired || current == _Route.bluetooth) current,
      if (c.canSwitchSpeaker) ...<_Route>[_Route.earpiece, _Route.speaker],
    ];
    final _Route? picked = await showAnchoredMenu<_Route>(
      buttonContext,
      color: theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
      borderColor: ink.withValues(alpha: 0.3),
      outlined: true,
      borderRadius: 18,
      preferAbove: true,
      minWidth: 220,
      items: <Widget>[
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final _Route route in routes)
              PopupMenuItem<_Route>(
                value: route,
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    HugeIcon(_routeGlyph(route), size: 18, color: ink),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        route == _Route.speaker
                            ? 'Speaker'
                            : _routeLabel(route),
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: route == current
                              ? ink
                              : ink.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (route == current) ...<Widget>[
                      const SizedBox(width: 12),
                      HugeIcon(HugeIcons.check, size: 18, color: ink),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ],
    );
    if (picked == null || picked == current || !mounted) return;
    if (picked == _Route.speaker || picked == _Route.earpiece) {
      await _action(() => c.setSpeakerOn(picked == _Route.speaker));
    }
  }

  VoiceBarsState get _barsState {
    if (c.phase == VoiceCallPhase.connecting) return VoiceBarsState.thinking;
    if (c.agentSpeaking) return VoiceBarsState.speaking;
    if (c.agentThinking) return VoiceBarsState.thinking;
    return VoiceBarsState.listening;
  }

  VoiceCard? get _stageCard {
    for (final VoiceCard card in c.cards.reversed) {
      if (kVoiceSearchCardKinds.contains(card.kind)) continue;
      if (_hiddenCards.contains(card.id)) return null;
      return card;
    }
    return null;
  }

  VoiceCard? get _searchCard {
    for (final VoiceCard card in c.cards.reversed) {
      if (kVoiceSearchCardKinds.contains(card.kind)) return card;
    }
    return null;
  }

  VoiceToolActivity? get _searchTool {
    for (final VoiceToolActivity tool in c.runningTools.reversed) {
      if (kVoiceSearchTools.contains(tool.name)) return tool;
    }
    return null;
  }

  String? _statusLine(bool failed) {
    if (failed) return c.error ?? 'Call failed';
    return switch (c.phase) {
      VoiceCallPhase.connecting => 'Connecting…',
      VoiceCallPhase.ending => 'Ending call…',
      _ => null,
    };
  }

  String get _semanticStatus {
    if (c.agentSpeaking) return 'Assistant speaking';
    if (c.agentThinking) return 'Thinking';
    if (c.micMuted) return 'Muted';
    return 'Listening';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final ThemeData theme = Theme.of(context);
      final ColorScheme scheme = theme.colorScheme;
      final bool failed = c.phase == VoiceCallPhase.failed;
      final String name = c.agentName?.trim().isNotEmpty == true
          ? c.agentName!.trim()
          : 'Assistant';
      final VoiceCard? stageCard = c.cameraEnabled ? null : _stageCard;
      final bool raised = c.cameraEnabled || stageCard != null;
      final VoiceToolActivity? searchTool = _searchTool;
      final String? status = _statusLine(failed);

      return Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final bool short = constraints.maxHeight < 480;
              final double topInset = short ? 48 : 64;
              final double compactBars = short ? 48 : 108;
              final Widget bars = Semantics(
                label: _semanticStatus,
                child: VoiceBars(
                  key: const ValueKey('voice-visualization'),
                  state: _barsState,
                  muted: c.micMuted,
                  level: c.audioLevel,
                  compact: raised,
                ),
              );
              final Widget searchLine = VoiceSearchLine(
                searching: searchTool != null,
                label: searchTool?.label ?? '',
                result: _searchCard,
              );
              final Widget statusText = status == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        status,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: failed
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    );

              final Widget field;
              if (!raised) {
                final double barsHeight = (constraints.maxHeight * 0.32).clamp(
                  56.0,
                  200.0,
                );
                field = Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SizedBox(height: barsHeight, child: bars),
                      SizedBox(height: short ? 8 : 28),
                      searchLine,
                      statusText,
                    ],
                  ),
                );
              } else {
                final Widget stage;
                if (c.cameraEnabled) {
                  stage = Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: VoiceStageFrame(
                      child: VoiceCameraStage(
                        track: c.cameraTrack,
                        mirrored: c.cameraMirrored,
                        onFlip: () => unawaited(_action(c.switchCamera)),
                      ),
                    ),
                  );
                } else {
                  final VoiceCard card = stageCard!;
                  stage = Padding(
                    padding: VoiceCardStage.isFrameless(card)
                        ? const EdgeInsets.only(bottom: 16)
                        : const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: VoiceCardStage(
                      card: card,
                      onClose: () => setState(() => _hiddenCards.add(card.id)),
                    ),
                  );
                }
                field = Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: Column(
                    children: <Widget>[
                      SizedBox(height: compactBars, child: bars),
                      searchLine,
                      statusText,
                      Expanded(child: stage),
                    ],
                  ),
                );
              }

              return Column(
                children: <Widget>[
                  Expanded(
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(child: field),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: _header(context, name, failed),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, 8, 20, short ? 12 : 32),
                    child: _controls(context, scheme, failed),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );

  Widget _header(BuildContext context, String name, bool failed) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime? started = c.startedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
      child: Row(
        children: <Widget>[
          FloatingHeaderButton(
            tooltip: 'Back to chat',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icons.arrow_back_rounded,
          ),
          Flexible(
            child: TextButton(
              onPressed: failed || c.changingVoice ? null : _chooseVoice,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurface,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const Spacer(),
          FloatingHeaderButton(
            tooltip: 'Chat',
            onPressed: () => Navigator.of(context).maybePop(),
            hugeIcon: HugeIcons.message01,
          ),
          const SizedBox(width: 8),
          if (started != null)
            Text(
              formatVoiceDuration(DateTime.now().difference(started)),
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context, ColorScheme scheme, bool failed) {
    final _Route? route = _route;
    final bool headset = route == _Route.wired || route == _Route.bluetooth;
    final bool showRoute = c.canSwitchSpeaker || headset;
    final (Color mutedFill, _) = VoiceButtonGroup.colorsFor(
      scheme,
      VoiceButtonTone.muted,
    );
    final (Color plainFill, _) = VoiceButtonGroup.colorsFor(
      scheme,
      VoiceButtonTone.plain,
    );
    return Center(
      child: VoiceButtonGroup(
        items: <VoiceButtonItem>[
          VoiceButtonItem(
            semanticsId: 'voice-call-video',
            tooltip: c.cameraEnabled ? 'Turn video off' : 'Turn video on',
            tone: c.cameraEnabled
                ? VoiceButtonTone.selected
                : VoiceButtonTone.plain,
            opened: c.cameraEnabled,
            onPressed: failed
                ? null
                : (_) => unawaited(
                    _action(() => c.setCameraEnabled(!c.cameraEnabled)),
                  ),
            icon: (Color ink) => HugeIcon(HugeIcons.video01, color: ink),
          ),
          VoiceButtonItem(
            semanticsId: 'voice-call-mute',
            tooltip: c.micMuted ? 'Unmute' : 'Mute',
            tone: c.micMuted ? VoiceButtonTone.muted : VoiceButtonTone.plain,
            opened: c.micMuted,
            onPressed: failed
                ? null
                : (_) => unawaited(_action(() => c.setMicMuted(!c.micMuted))),
            icon: (Color ink) => VoiceMicGlyph(
              muted: c.micMuted,
              size: 24,
              color: ink,
              gapColor: c.micMuted ? mutedFill : plainFill,
            ),
          ),
          if (showRoute && route != null)
            VoiceButtonItem(
              semanticsId: 'voice-call-speaker',
              tooltip: c.changingSpeaker ? 'Switching…' : _routeLabel(route),
              tone: switch (route) {
                _Route.earpiece => VoiceButtonTone.plain,
                _Route.speaker => VoiceButtonTone.selected,
                _Route.wired || _Route.bluetooth => VoiceButtonTone.headset,
              },
              opened: route != _Route.earpiece,
              onPressed: failed || c.changingSpeaker
                  ? null
                  : (BuildContext buttonContext) =>
                        unawaited(_pickRoute(buttonContext, route)),
              icon: (Color ink) => HugeIcon(_routeGlyph(route), color: ink),
            ),
          VoiceButtonItem(
            semanticsId: 'voice-call-hang-up',
            tooltip: failed ? 'Close' : 'End call',
            onPressed: (_) async {
              if (!failed) await c.end();
              if (context.mounted && !_closing) {
                await Navigator.of(context).maybePop();
              }
            },
            icon: (Color ink) => HugeIcon(HugeIcons.cancel01, color: ink),
          ),
        ],
      ),
    );
  }

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
