/// Pull up at the end of a chat to start a new one (owner, 2026-11-13).
///
/// The chat is at its last message and the finger keeps pulling up: a round
/// button with a label rises over the chat. It fills as the pull grows. Let
/// go past [PullUpToCreate.threshold] and [PullUpToCreate.onCreate] runs: a
/// new chat in the Chats half, a new Sidekick in the Sidekicks half. Let go
/// before that and nothing happens.
///
/// It listens to the scroll notifications of the chat below it and moves
/// nothing itself, so the transcript keeps its own physics.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps a chat. See the library doc.
class PullUpToCreate extends StatefulWidget {
  const PullUpToCreate({
    super.key,
    required this.child,
    required this.onCreate,
    required this.label,
    this.icon = Icons.edit_square,
    this.bottom = 150,
    this.enabled = true,
  });

  /// How far the finger pulls past the end before a release creates.
  static const double threshold = 96;

  final Widget child;

  /// Runs when the finger lets go past the [threshold].
  final VoidCallback onCreate;

  /// The words under the button: "New chat", "New Sidekick".
  final String label;
  final IconData icon;

  /// Distance of the button from the bottom edge: above the composer.
  final double bottom;

  /// False ignores every pull.
  final bool enabled;

  @override
  State<PullUpToCreate> createState() => _PullUpToCreateState();
}

class _PullUpToCreateState extends State<PullUpToCreate> {
  /// How far the finger has pulled past the end, in logical pixels.
  final ValueNotifier<double> _pull = ValueNotifier<double>(0);

  bool get _armed => _pull.value >= PullUpToCreate.threshold;

  @override
  void dispose() {
    _pull.dispose();
    super.dispose();
  }

  /// The pull at the visual bottom edge that [n] adds, or null when [n] is
  /// not a finger pulling up there.
  double? _added(ScrollNotification n) {
    final ScrollMetrics m = n.metrics;
    // In a reversed list the newest message is at offset zero.
    final bool reversed =
        m.axisDirection == AxisDirection.up ||
        m.axisDirection == AxisDirection.left;
    if (n is OverscrollNotification) {
      if (n.dragDetails == null) return null;
      final double over = reversed ? -n.overscroll : n.overscroll;
      return over > 0 ? over : null;
    }
    if (n is ScrollUpdateNotification) {
      if (n.dragDetails == null) return null;
      // Bouncing physics: the offset itself runs past the end.
      final double past = reversed
          ? m.minScrollExtent - m.pixels
          : m.pixels - m.maxScrollExtent;
      if (past <= 0) return null;
      final double delta = n.scrollDelta ?? 0;
      final double step = reversed ? -delta : delta;
      return step > 0 ? step : null;
    }
    return null;
  }

  bool _onScroll(ScrollNotification n) {
    if (!widget.enabled) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollEndNotification) {
      _release();
      return false;
    }
    final double? added = _added(n);
    if (added != null) {
      // A text field scrolls too. A pull in the composer is not a pull on
      // the chat. Looked up only when a pull starts: an ordinary scroll
      // frame pays nothing for it.
      if (_pull.value == 0 &&
          n.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
        return false;
      }
      final bool was = _armed;
      _pull.value += added;
      if (!was && _armed) HapticFeedback.selectionClick();
      return false;
    }
    // The finger turned back down, or the list moves by itself again.
    if (n is ScrollUpdateNotification && _pull.value > 0) {
      if (n.dragDetails == null) {
        _release();
      } else {
        _pull.value = 0;
      }
    }
    return false;
  }

  void _release() {
    if (_pull.value == 0) return;
    final bool create = _armed;
    _pull.value = 0;
    if (create) widget.onCreate();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: widget.child,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: widget.bottom,
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: _pull,
              builder: (BuildContext context, double pull, Widget? _) {
                if (pull <= 0) return const SizedBox.shrink();
                final double t = (pull / PullUpToCreate.threshold).clamp(
                  0.0,
                  1.0,
                );
                return _Hint(
                  progress: t,
                  armed: t >= 1,
                  icon: widget.icon,
                  label: widget.label,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// The round button and its label, at [progress] of the pull.
class _Hint extends StatelessWidget {
  const _Hint({
    required this.progress,
    required this.armed,
    required this.icon,
    required this.label,
  });

  final double progress;
  final bool armed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = armed ? scheme.primary : scheme.surfaceContainerHighest;
    final Color onFill = armed ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Opacity(
      key: const ValueKey<String>('pull_up_to_create_hint'),
      opacity: progress,
      child: Transform.translate(
        // Rises the last 24 px into place.
        offset: Offset(0, 24 * (1 - progress)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Transform.scale(
              scale: 0.7 + 0.3 * progress,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Icon(icon, size: 22, color: onFill),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: armed ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
