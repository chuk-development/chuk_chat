// lib/widgets/unread_jump_pill.dart
//
// "3 new" over a thread (bead chuk_chat-f5wd). A thread opens at its bottom;
// when the agent wrote several messages while the reader was away, the first
// of them sits above the screen. The pill says how many arrived, a tap
// scrolls to the first one, and it goes away for good once that message was
// on screen, whether the tap or the reader's own scrolling brought it there.
//
// The pill only reads the list: the row it points at carries [targetKey],
// and the scroll position is the chat's own [controller].

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

class UnreadJumpPill extends StatefulWidget {
  const UnreadJumpPill({
    super.key,
    required this.controller,
    required this.targetKey,
    required this.count,
    required this.onSeen,
    this.topInset = 0,
    this.dense = true,
  });

  /// The transcript's scroll controller.
  final ScrollController controller;

  /// The key on the first unread row.
  final GlobalKey targetKey;

  /// How many rows are new.
  final int count;

  /// Called once, when the first unread row was on screen.
  final VoidCallback onSeen;

  /// Height of the chrome that floats over the top of the list; a row under
  /// it is not on screen.
  final double topInset;

  /// The small button size; a pill over the thread is not a thumb target
  /// for a main action.
  final bool dense;

  @override
  State<UnreadJumpPill> createState() => _UnreadJumpPillState();
}

class _UnreadJumpPillState extends State<UnreadJumpPill> {
  bool _visible = false;
  bool _seen = false;
  bool _jumping = false;

  /// The thread settles at its bottom over a few frames after it opens. The
  /// pill waits for that, so it never flashes for a row that is on screen a
  /// moment later.
  bool _armed = false;
  Timer? _armTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_checkAfterFrame);
    _armTimer = Timer(const Duration(milliseconds: 400), () {
      _armed = true;
      _checkAfterFrame();
    });
    _checkAfterFrame();
  }

  @override
  void didUpdateWidget(UnreadJumpPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_checkAfterFrame);
      widget.controller.addListener(_checkAfterFrame);
    }
    _checkAfterFrame();
  }

  @override
  void dispose() {
    _armTimer?.cancel();
    widget.controller.removeListener(_checkAfterFrame);
    super.dispose();
  }

  bool _checkScheduled = false;

  /// Checks once the next frame is laid out. A scroll notifies before the
  /// rows at the new offset exist, so an immediate look would miss them.
  void _checkAfterFrame() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      _check();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Whether the first unread row is (partly) on screen, below the chrome.
  bool _targetOnScreen() {
    final BuildContext? target = widget.targetKey.currentContext;
    if (target == null) return false;
    final RenderObject? box = target.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final ScrollableState? scrollable = Scrollable.maybeOf(target);
    final RenderObject? viewport = scrollable?.context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return false;
    final double top = box.localToGlobal(Offset.zero).dy;
    final double bottom = top + box.size.height;
    final double viewTop = viewport.localToGlobal(Offset.zero).dy;
    final double viewBottom = viewTop + viewport.size.height;
    return bottom > viewTop + widget.topInset + 12 && top < viewBottom - 24;
  }

  void _check() {
    if (!mounted || _seen) return;
    if (_targetOnScreen()) {
      _markSeen();
      return;
    }
    if (_armed && !_visible && widget.controller.hasClients) {
      setState(() => _visible = true);
    }
  }

  void _markSeen() {
    if (_seen) return;
    _seen = true;
    if (mounted) setState(() => _visible = false);
    widget.onSeen();
  }

  Future<void> _jump() async {
    if (_jumping) return;
    _jumping = true;
    try {
      // The row may not be built yet: the list only lays out what is near
      // the screen. Walk up a screen at a time until it is, then glide.
      for (int step = 0; step < 80 && mounted; step++) {
        final BuildContext? target = widget.targetKey.currentContext;
        if (target != null) {
          if (!target.mounted) break;
          await Scrollable.ensureVisible(
            target,
            alignment: 0.12,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
          break;
        }
        if (!widget.controller.hasClients) break;
        final ScrollPosition position = widget.controller.position;
        final double next = math.max(
          position.minScrollExtent,
          position.pixels - position.viewportDimension * 0.9,
        );
        if ((next - position.pixels).abs() < 0.5) break;
        widget.controller.jumpTo(next);
        await SchedulerBinding.instance.endOfFrame;
      }
    } finally {
      _jumping = false;
    }
    if (mounted) _markSeen();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final String label =
        l?.unreadJumpPill(widget.count) ?? '${widget.count} new';
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: _visible ? Offset.zero : const Offset(0, -0.4),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: Semantics(
            button: true,
            liveRegion: _visible,
            child: ExpressiveButton(
              key: const ValueKey<String>('unread-jump-pill'),
              icon: Icons.keyboard_arrow_up,
              label: label,
              tonal: true,
              dense: true,
              onTap: () => unawaited(_jump()),
            ),
          ),
        ),
      ),
    );
  }
}
