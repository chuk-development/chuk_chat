/// An [IndexedStack] that fades through instead of cutting: the Chats and
/// Agents halves of the messenger shell. Moved out of the old phone home
/// (`mobile_home.dart`), which the swipe pager replaced.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/motion.dart';

/// An [IndexedStack] that fades through instead of cutting.
///
/// All children stay in the tree — the same guarantee [IndexedStack] gives, so
/// the roster is not rebuilt on every tab press — and the swap is painted: the
/// tab being left fades out over the first third, the tab being entered fades
/// in over the rest while it grows the last few percent back to size. Material
/// calls this fade-through, and it is the transition for peers: nothing slides,
/// because neither tab is "further in" than the other.
///
/// A child that is not in front can take no focus and runs no tickers: a
/// hidden composer must not open the keyboard, and a hidden list has nothing
/// to animate.
class FadeThroughTabs extends StatefulWidget {
  const FadeThroughTabs({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  /// Inside the 200–350 ms band the rest of the app's motion lives in.
  static const Duration duration = Duration(milliseconds: 300);

  @override
  State<FadeThroughTabs> createState() => _FadeThroughTabsState();
}

class _FadeThroughTabsState extends State<FadeThroughTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: FadeThroughTabs.duration,
    value: 1,
  )..addStatusListener(_onStatus);

  /// The tab that is arriving (at rest: the tab that is simply there).
  late int _incoming = widget.index;

  /// The tab that is leaving, while it is still worth painting.
  int? _outgoing;

  bool _reducedMotion = false;

  late final Animation<double> _out = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.35, curve: Curves.easeOut),
  );
  late final Animation<double> _in = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.35, 1, curve: kExpressiveDecelerate),
  );

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_outgoing == null || !mounted) return;
    setState(() => _outgoing = null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion && (_c.isAnimating || _outgoing != null)) {
      _c.stop();
      _c.value = 1;
      _outgoing = null;
    }
  }

  @override
  void didUpdateWidget(covariant FadeThroughTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _incoming) return;
    final int leaving = _incoming;
    _incoming = widget.index;
    // Reduced motion: the tab is simply the other one now.
    if (_reducedMotion) {
      _c.value = 1;
      _outgoing = null;
      return;
    }
    _outgoing = leaving;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        final double leaving = _out.value;
        final double arriving = _in.value;
        return Stack(
          children: <Widget>[
            // Every tab keeps its slot and its wrapper chain, in the same
            // order, for the life of the widget. That is what keeps the state:
            // change the shape of a slot (Offstage here, Opacity there) and
            // Flutter throws the subtree away and builds a new one, which is
            // exactly the rebuilt roster this is meant to avoid. So the chain
            // is always the same widgets, and only their values move.
            for (int i = 0; i < widget.children.length; i++)
              Offstage(
                // Laid out either way (see [RenderOffstage]), so a tab that is
                // waiting keeps its scroll position and its controllers.
                offstage: i != _incoming && i != _outgoing,
                child: TickerMode(
                  enabled: i == _incoming || i == _outgoing,
                  child: ExcludeFocus(
                    excluding: i != _incoming,
                    child: IgnorePointer(
                      ignoring: i != _incoming,
                      child: Opacity(
                        opacity: i == _incoming
                            ? arriving
                            : (i == _outgoing ? 1 - leaving : 0),
                        child: Transform.scale(
                          scale: i == _incoming
                              ? 0.94 + 0.06 * arriving
                              : (i == _outgoing ? 1 - 0.03 * leaving : 1),
                          child: widget.children[i],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
