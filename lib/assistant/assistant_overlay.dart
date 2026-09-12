import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/assistant/assistant_cards.dart';
import 'package:chuk_chat/assistant/assistant_result.dart';
import 'package:chuk_chat/assistant/assistant_session.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Transparent, instant route for the assistant surface.
///
/// The assist activity builds this as its only route, so closing the surface
/// finishes the activity and returns to the app that was on screen. The in-app
/// launcher pushes the same route above the current page.
Route<void> buildAssistantOverlayRoute() => PageRouteBuilder<void>(
  settings: const RouteSettings(name: assistantOverlayRouteName),
  opaque: false,
  transitionDuration: Duration.zero,
  reverseTransitionDuration: Duration.zero,
  pageBuilder: (_, _, _) => const AssistantOverlayPage(),
);

/// The initial route the native assist activity starts Flutter on.
const String assistantOverlayRouteName = '/assistant-overlay';

class AssistantOverlayPage extends StatefulWidget {
  const AssistantOverlayPage({super.key});

  @override
  State<AssistantOverlayPage> createState() => _AssistantOverlayPageState();
}

class _AssistantOverlayPageState extends State<AssistantOverlayPage> {
  AssistantSession? _session;
  bool _contextOpen = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_startSession());
  }

  Future<void> _startSession() async {
    final session = AssistantSession();
    if (!mounted) {
      session.dispose();
      return;
    }
    setState(() => _session = session);
    await session.start();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _session?.dispose();
    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      // Started by the assist gesture: this is the only route, so popping the
      // navigator would leave an empty stack. Finish the activity instead.
      await SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    if (!_closing) _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: session == null
            ? AssistantOverlayView(
                status: 'Starte …',
                busy: true,
                onMic: () {},
                onClose: () => unawaited(_close()),
                onContext: () {},
                onScreen: () {},
              )
            : ListenableBuilder(
                listenable: session,
                builder: (context, _) => AssistantOverlayView(
                  status: session.statusLabel,
                  transcript: session.userText,
                  caption: session.answer,
                  errorText: session.error,
                  busy: session.busy,
                  listening: session.listening,
                  muted: session.muted,
                  level: session.level,
                  contextOpen: _contextOpen,
                  card: session.card,
                  tools: [
                    for (final run in session.tools)
                      AssistantToolBadge(
                        label: run.label,
                        done: run.done,
                        failed: run.failed,
                      ),
                  ],
                  onContext: () => setState(() => _contextOpen = !_contextOpen),
                  onMic: () => unawaited(session.toggleMute()),
                  onClose: () => unawaited(_close()),
                  onScreen: () => unawaited(session.attachScreenContext()),
                ),
              ),
      ),
    );
  }
}

/// One tool call, as the surface shows it.
@immutable
class AssistantToolBadge {
  const AssistantToolBadge({
    required this.label,
    this.done = false,
    this.failed = false,
  });

  final String label;
  final bool done;
  final bool failed;
}

/// Presentation separated from transport so the layout can be checked offline.
///
/// Every colour is read off the running [ThemeData], which Chuk Chat builds
/// from the user's accent, background and contrast. Nothing here carries its
/// own palette.
class AssistantOverlayView extends StatelessWidget {
  const AssistantOverlayView({
    super.key,
    required this.onMic,
    required this.onClose,
    required this.onContext,
    required this.onScreen,
    this.status = 'Bereit',
    this.transcript = '',
    this.caption = '',
    this.errorText = '',
    this.busy = false,
    this.listening = false,
    this.muted = false,
    this.level = 0,
    this.contextOpen = false,
    this.tools = const <AssistantToolBadge>[],
    this.card,
  });

  final VoidCallback onMic, onClose, onContext, onScreen;
  final String status, transcript, caption, errorText;
  final bool busy, listening, muted, contextOpen;
  final double level;
  final List<AssistantToolBadge> tools;

  /// The visual result of the turn, drawn above the answer.
  final AssistantCard? card;

  bool get _hasError => errorText.trim().isNotEmpty;

  /// While the surface only listens there is nothing worth saying, so the
  /// panel stays away and the waveform alone carries the state. It appears
  /// once the turn produces something: a tool call, an answer, an error.
  bool get _showPanel =>
      busy ||
      _hasError ||
      transcript.trim().isNotEmpty ||
      caption.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = card != null || contextOpen || tools.isNotEmpty;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(
              color: scheme.scrim.withValues(alpha: 0.03),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: ConstrainedBox(
                // The panel sits at the bottom edge, so it grows upward. Give
                // it most of the screen, otherwise a long answer is cut off
                // instead of using the empty space above it.
                constraints: BoxConstraints(
                  maxWidth: 420,
                  maxHeight:
                      MediaQuery.sizeOf(context).height *
                      (expanded ? .88 : .74),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (card != null) ...[
                        AssistantSurface(child: AssistantCardView(card: card!)),
                        const SizedBox(height: 10),
                      ],
                      if (_showPanel)
                        AssistantSurface(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'CHUK CHAT',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 11,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                status,
                                style: TextStyle(
                                  fontSize: 20,
                                  height: 1.2,
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              // The quoted request and the answer appear
                              // together, and only once the answer stands.
                              // While the turn runs the panel shows the state
                              // and the waveform, nothing half written.
                              if (!busy && transcript.trim().isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '„${transcript.trim()}"',
                                  style: TextStyle(
                                    color: scheme.primary,
                                    fontSize: 14,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                              if (_hasError) ...[
                                const SizedBox(height: 8),
                                Text(
                                  errorText.trim(),
                                  style: TextStyle(
                                    color: scheme.error,
                                    fontSize: 14,
                                    height: 1.4,
                                  ),
                                ),
                              ] else if (!busy && caption.trim().isNotEmpty) ...[
                                const SizedBox(height: 8),
                                // The answer is read, not heard, so it is
                                // rendered: a bold number, a short list, inline
                                // code. No inner height cap and no inner
                                // scroller — the answer grows the panel upward
                                // and the outer scroll view takes over at the
                                // top.
                                MarkdownMessage(
                                  text: caption.trim(),
                                  textColor: scheme.onSurfaceVariant,
                                  backgroundColor: scheme.surface,
                                  wrapWithSelectionArea: false,
                                  paragraphFontSize: 14,
                                  paragraphHeight: 1.4,
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (tools.isNotEmpty) ...[
                        if (_showPanel) const SizedBox(height: 10),
                        AssistantSurface(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final tool in tools)
                                AssistantToolRow(tool: tool),
                            ],
                          ),
                        ),
                      ],
                      if (_showPanel || tools.isNotEmpty)
                        const SizedBox(height: 10),
                      AssistantSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        child: AssistantWaveform(
                          level: level,
                          active: listening && !muted,
                          busy: busy,
                        ),
                      ),
                      if (contextOpen) ...[
                        const SizedBox(height: 10),
                        AssistantSurface(
                          child: Column(
                            children: [
                              AssistantAction(
                                label: 'Bildschirm mitgeben',
                                icon: Icons.screenshot_monitor_outlined,
                                onPressed: onScreen,
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: AssistantAction(
                              label: 'Kontext hinzufügen',
                              icon: contextOpen ? Icons.remove : Icons.add,
                              iconOnly: true,
                              onPressed: onContext,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: AssistantAction(
                              label: _hasError
                                  ? 'Wiederholen'
                                  : busy
                                  ? status
                                  : muted
                                  ? 'Fortsetzen'
                                  : 'Pausieren',
                              icon: _hasError
                                  ? Icons.refresh
                                  : muted
                                  ? Icons.mic_off_outlined
                                  : Icons.mic_none_rounded,
                              primary: true,
                              onPressed: busy ? null : onMic,
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 48,
                            child: AssistantAction(
                              label: 'Schließen',
                              icon: Icons.close,
                              iconOnly: true,
                              onPressed: onClose,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One line per tool call, so the user sees what the assistant really does.
class AssistantToolRow extends StatelessWidget {
  const AssistantToolRow({super.key, required this.tool});

  final AssistantToolBadge tool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tool.failed
        ? scheme.error
        : tool.done
        ? scheme.onSurfaceVariant
        : scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: tool.done
                ? AppIcon(
                    tool.failed
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    size: 16,
                    color: color,
                  )
                : CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tool.label,
              style: TextStyle(color: color, fontSize: 13, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// One floating, blurred panel. The surface colour is the user's, only the
/// translucency is ours — the app underneath has to stay recognizable.
class AssistantSurface extends StatelessWidget {
  const AssistantSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.93),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Label and icon as one centred group with a 48 dp minimum target.
class AssistantAction extends StatelessWidget {
  const AssistantAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.iconOnly = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary, iconOnly;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: primary ? scheme.onPrimary : scheme.onSurface,
          backgroundColor: primary
              ? scheme.primary
              : scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          disabledBackgroundColor: primary
              ? scheme.primary.withValues(alpha: 0.45)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          disabledForegroundColor: scheme.onSurfaceVariant.withValues(
            alpha: 0.6,
          ),
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.symmetric(
            horizontal: iconOnly ? 0 : 12,
            vertical: 12,
          ),
          shape: const StadiumBorder(),
        ),
        child: iconOnly
            ? AppIcon(icon, size: 22, semanticLabel: label)
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(icon, size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Microphone level as a symmetric bar field.
class AssistantWaveform extends StatefulWidget {
  const AssistantWaveform({
    super.key,
    required this.level,
    required this.active,
    required this.busy,
  });

  final double level;
  final bool active, busy;

  @override
  State<AssistantWaveform> createState() => _AssistantWaveformState();
}

class _AssistantWaveformState extends State<AssistantWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  void _sync() {
    if (!MediaQuery.disableAnimationsOf(context) &&
        (widget.active || widget.busy)) {
      if (!_animation.isAnimating) _animation.repeat();
    } else {
      _animation.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AssistantWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.busy
          ? 'Verbindungsaufbau'
          : widget.active
          ? 'Spracheingabe'
          : 'Mikrofon inaktiv',
      child: SizedBox(
        height: 40,
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, _) => CustomPaint(
            painter: _WavePainter(
              phase: _animation.value,
              level: widget.level,
              active: widget.active,
              busy: widget.busy,
              activeColor: scheme.primary,
              idleColor: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.phase,
    required this.level,
    required this.active,
    required this.busy,
    required this.activeColor,
    required this.idleColor,
  });

  final double phase, level;
  final bool active, busy;
  final Color activeColor, idleColor;

  @override
  void paint(Canvas canvas, Size size) {
    const count = 21;
    final step = math.min(10.0, size.width / count);
    final width = step * .46;
    final start = (size.width - (count - 1) * step) / 2;
    final energy = level.isFinite ? level.clamp(0.0, 1.0) : 0.0;
    final paint = Paint()..color = active ? activeColor : idleColor;
    for (var i = 0; i < count; i++) {
      final envelope = math.sin((i + 1) / (count + 1) * math.pi);
      final wave = .5 + .5 * math.sin(phase * math.pi * 2 + i * .8);
      final amplitude = busy
          ? 8 * wave
          : active
          ? (3 + 29 * energy) * envelope * (.45 + .55 * wave)
          : 0.0;
      final height = math.min(size.height - 4, 4 + amplitude);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(start + i * step, size.height / 2),
            width: width,
            height: height,
          ),
          const Radius.circular(4),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      phase != old.phase ||
      level != old.level ||
      active != old.active ||
      busy != old.busy ||
      activeColor != old.activeColor ||
      idleColor != old.idleColor;
}
