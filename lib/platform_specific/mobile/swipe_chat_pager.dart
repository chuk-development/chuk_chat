/// Horizontal swipe between chats on the phone, over ONE live chat view.
///
/// The phone has no drawer and no bottom bar. The user stays in one chat UI
/// and swipes sideways to reach the previous or the next chat. This is not a
/// [PageView]: the chat view owns sockets, streams and a composer, so there is
/// exactly one of it, at one place in the tree, for the whole life of the
/// pager. A swipe only moves that one child out, tells the shell to select the
/// neighbour, and moves the same child back in, now showing the new chat.
///
/// The drag position is published as "progress in pages" through
/// [SwipeChatPagerController.progress], so the title strip above the chat can
/// slide its text with the finger.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

import 'package:chuk_chat/ui/expressive/motion.dart';

/// One chat (or agent, or sentinel page like 'home' / 'new') the pager and
/// the title strip can show.
@immutable
class SwipeChatEntry {
  const SwipeChatEntry({
    required this.id,
    required this.title,
    this.subtitle,
    this.leading,
    this.unread = false,
    this.working = false,
  });

  /// Chat id, agent id, or a sentinel like 'home' / 'new'.
  final String id;
  final String title;

  /// The last line or a status. One line.
  final String? subtitle;

  /// A face or an icon. Null draws none.
  final Widget? leading;
  final bool unread;

  /// A run is in flight: the strip and the sheet show working dots.
  final bool working;

  @override
  bool operator ==(Object other) =>
      other is SwipeChatEntry &&
      other.id == id &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.leading == leading &&
      other.unread == unread &&
      other.working == working;

  @override
  int get hashCode =>
      Object.hash(id, title, subtitle, leading, unread, working);
}

/// The index of [id] in [entries], or -1.
int swipeChatIndexOf(List<SwipeChatEntry> entries, String? id) {
  if (id == null) return -1;
  for (int i = 0; i < entries.length; i++) {
    if (entries[i].id == id) return i;
  }
  return -1;
}

/// Shares the pager's drag position with other widgets (the title strip).
///
/// [progress] is in pages: 0 = at rest, -0.4 = the chat is 40 % of the way
/// out to the left, that is 40 % towards the NEXT entry (index + 1). +0.4 is
/// 40 % towards the previous entry. During a committed switch the value runs
/// to ±1, the selection changes, and it continues from ∓1 back to 0.
class SwipeChatPagerController {
  SwipeChatPagerController();

  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  /// The drag progress in pages. See the class comment for the sign.
  ValueListenable<double> get progress => _progress;

  final ValueNotifier<double> _carousel = ValueNotifier<double>(0);

  /// Like [progress], but without the jump of a committed switch: it runs to
  /// ±1 while the chat leaves, and reads 0 from the moment the selection
  /// changes, while the chat comes back in. The title carousel follows this
  /// one, so a title glides from the edge to the centre in one piece.
  ValueListenable<double> get carousel => _carousel;

  _SwipeChatPagerState? _attached;

  /// Animates to the next entry, like a swipe to the left. No-op when there
  /// is no next entry or the pager is not mounted.
  void next() => _attached?._commit(-1, velocity: 0);

  /// Animates to the previous entry, like a swipe to the right.
  void previous() => _attached?._commit(1, velocity: 0);

  /// Drives the pager from a drag that starts outside it: the title strip
  /// above the chat is the main swipe surface. The chat and the strip move
  /// together, exactly as for a drag on the chat itself.
  void dragStart() => _attached?._onStart(DragStartDetails());

  /// [dx] is the finger's travel since the last update, in logical pixels.
  void dragUpdate(double dx) => _attached?._onUpdate(
    DragUpdateDetails(globalPosition: Offset.zero, delta: Offset(dx, 0)),
  );

  /// [velocity] is the release speed along x, in px/s.
  void dragEnd(double velocity) => _attached?._onEnd(
    DragEndDetails(
      velocity: Velocity(pixelsPerSecond: Offset(velocity, 0)),
      primaryVelocity: velocity,
    ),
  );

  void dragCancel() => _attached?._onCancel();

  void dispose() {
    _progress.dispose();
    _carousel.dispose();
  }
}

/// Fraction of the width a release must pass to commit a switch.
const double kSwipeChatCommitFraction = 0.22;

/// Fling speed (px/s) that commits a switch whatever the distance.
const double kSwipeChatFlingVelocity = 700;

/// Duration of the "out" half of a committed switch.
const Duration kSwipeChatOutDuration = Duration(milliseconds: 160);

/// Duration of the "in" half of a committed switch.
const Duration kSwipeChatInDuration = Duration(milliseconds: 220);

/// M3 emphasized accelerate: leaves slowly, exits fast.
const Cubic _kEmphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);

/// How far (in pages) the rubber band can stretch at an end, at most.
const double _kRubberMax = 0.12;

/// Wraps the single live chat view and turns horizontal drags into
/// "previous / next entry".
class SwipeChatPager extends StatefulWidget {
  const SwipeChatPager({
    super.key,
    required this.entries,
    required this.selectedId,
    required this.onSelected,
    required this.child,
    this.enabled = true,
    this.controller,
    this.clipBehavior = Clip.hardEdge,
    this.moveChild = true,
  });

  /// entries[0] is the leftmost. A swipe to the left goes to index + 1.
  final List<SwipeChatEntry> entries;
  final String? selectedId;

  /// Called once per committed switch, with the id of the new entry, while
  /// the child is off screen. Update [selectedId] synchronously in it (a
  /// plain setState), so the child and the title strip come back in showing
  /// the new chat.
  final ValueChanged<String> onSelected;

  /// The one live chat view. It keeps its State across every switch.
  final Widget child;

  /// False turns the swipe off (the child stays where it is).
  final bool enabled;
  final SwipeChatPagerController? controller;

  /// Clips the child while it is moved. [Clip.none] lets it paint outside.
  final Clip clipBehavior;

  /// False keeps the child still: the swipe only switches the chat, and the
  /// motion is the title strip's alone (owner, 2026-11-05, the phone).
  final bool moveChild;

  @override
  State<SwipeChatPager> createState() => _SwipeChatPagerState();
}

class _SwipeChatPagerState extends State<SwipeChatPager>
    with SingleTickerProviderStateMixin {
  /// Progress in pages, see [SwipeChatPagerController.progress].
  late final AnimationController _anim = AnimationController.unbounded(
    vsync: this,
  )..addListener(_publish);

  double _width = 0;

  /// The finger's travel in pages, before the rubber band.
  double _raw = 0;
  bool _dragging = false;

  /// A switch is running (out, select, in). Drags are ignored until done.
  bool _committing = false;

  /// The "in" half of a switch runs: the selection has changed already.
  bool _arriving = false;

  /// The id this pager asked the shell to select. A [selectedId] change to
  /// this id is ours, not an outside jump.
  String? _expectedId;

  @override
  void initState() {
    super.initState();
    widget.controller?._attached = this;
  }

  @override
  void didUpdateWidget(SwipeChatPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._attached == this) {
        oldWidget.controller!._attached = null;
      }
      widget.controller?._attached = this;
      _publish();
    }
    if (oldWidget.selectedId != widget.selectedId &&
        widget.selectedId != _expectedId) {
      // Selected from outside (the sheet, a new chat): no slide, just rest.
      _expectedId = null;
      _committing = false;
      _arriving = false;
      _dragging = false;
      _raw = 0;
      _anim.stop();
      _anim.value = 0;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._attached == this) {
      widget.controller!._attached = null;
      widget.controller!._progress.value = 0;
      widget.controller!._carousel.value = 0;
    }
    _anim.dispose();
    super.dispose();
  }

  void _publish() {
    final SwipeChatPagerController? c = widget.controller;
    if (c == null) return;
    c._progress.value = _anim.value;
    c._carousel.value = _arriving ? 0 : _anim.value;
  }

  int get _index => swipeChatIndexOf(widget.entries, widget.selectedId);
  bool get _hasNext {
    final int i = _index;
    return i >= 0 && i < widget.entries.length - 1;
  }

  bool get _hasPrev => _index > 0;

  bool get _reducedMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// A drag that starts on a text field belongs to the text field (caret,
  /// selection), even where the field itself would not claim it.
  bool _allowPointer(PointerDownEvent event) {
    if (!widget.enabled || _committing) return false;
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final HitTestEntry entry in result.path) {
      final HitTestTarget target = entry.target;
      if (target is RenderEditable) return false;
      // A code block or table that scrolls sideways keeps its own drag: the
      // pager accepts earlier than a scrollable would, so it must not even
      // enter the arena for a finger that lands on one.
      if (target is RenderViewportBase && target.axis == Axis.horizontal) {
        return false;
      }
    }
    return true;
  }

  double _rubber(double raw) {
    final double a = raw.abs();
    final double r = _kRubberMax * (1 - 1 / (1 + a / _kRubberMax * 0.5));
    return raw.isNegative ? -r : r;
  }

  double _displayFor(double raw) {
    if (raw < 0 && !_hasNext) return _rubber(raw);
    if (raw > 0 && !_hasPrev) return _rubber(raw);
    return raw.clamp(-1.0, 1.0);
  }

  void _onStart(DragStartDetails details) {
    if (_committing || _width <= 0) return;
    _anim.stop();
    _dragging = true;
    // Picking up a chat that is still springing back continues from where
    // it is, not from zero.
    _raw = _anim.value;
  }

  void _onUpdate(DragUpdateDetails details) {
    if (!_dragging || _width <= 0) return;
    _raw += details.delta.dx / _width;
    _anim.value = _displayFor(_raw);
  }

  void _onEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final double v = details.primaryVelocity ?? 0;
    final double r = _raw;
    _raw = 0;
    if (v <= -kSwipeChatFlingVelocity && _hasNext && r <= 0) {
      _commit(-1, velocity: v);
    } else if (v >= kSwipeChatFlingVelocity && _hasPrev && r >= 0) {
      _commit(1, velocity: v);
    } else if (r <= -kSwipeChatCommitFraction &&
        _hasNext &&
        v < kSwipeChatFlingVelocity) {
      _commit(-1, velocity: v);
    } else if (r >= kSwipeChatCommitFraction &&
        _hasPrev &&
        v > -kSwipeChatFlingVelocity) {
      _commit(1, velocity: v);
    } else {
      _springBack(v);
    }
  }

  void _onCancel() {
    if (!_dragging) return;
    _dragging = false;
    _raw = 0;
    _springBack(0);
  }

  void _springBack(double velocityPx) {
    if (_reducedMotion || _width <= 0) {
      _anim.value = 0;
      return;
    }
    final double from = _anim.value;
    if (from == 0) return;
    // Overshoot past zero would flash the neighbour's edge; a critically
    // damped copy of the spatial spring settles without it.
    final SpringDescription spring = SpringDescription.withDampingRatio(
      mass: kSpatialSpring.mass,
      stiffness: kSpatialSpring.stiffness,
    );
    _anim
        .animateWith(
          SpringSimulation(spring, from, 0, velocityPx / _width)
            ..tolerance = const Tolerance(distance: 0.001, velocity: 0.01),
        )
        .then((_) {
          // The spring stops within its tolerance; land exactly on zero so
          // the chat does not rest a fraction of a pixel off.
          if (mounted && !_dragging && !_committing) _anim.value = 0;
        });
  }

  /// [direction] -1 = next (content leaves to the left), +1 = previous.
  Future<void> _commit(int direction, {required double velocity}) async {
    if (_committing) return;
    final int index = _index;
    final int target = index - direction;
    if (index < 0 || target < 0 || target >= widget.entries.length) {
      _springBack(0);
      return;
    }
    final String id = widget.entries[target].id;
    _committing = true;
    _dragging = false;
    _expectedId = id;

    if (_reducedMotion) {
      _anim.value = 0;
      widget.onSelected(id);
      _committing = false;
      return;
    }

    final double end = direction.toDouble();
    final double remaining = (end - _anim.value).abs().clamp(0.0, 1.0);
    try {
      await _anim
          .animateTo(
            end,
            duration: kSwipeChatOutDuration * remaining,
            curve: _kEmphasizedAccelerate,
          )
          .orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || !_committing || _expectedId != id) return;
    widget.onSelected(id);
    if (!mounted) return;
    // The same child comes back in from the other side, now the new chat.
    _arriving = true;
    _anim.value = -end;
    try {
      await _anim
          .animateTo(
            0,
            duration: kSwipeChatInDuration,
            curve: kExpressiveDecelerate,
          )
          .orCancel;
    } on TickerCanceled {
      return;
    } finally {
      if (mounted && _expectedId == id) {
        _committing = false;
        _arriving = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The tree below is the same shape whatever [enabled] says, so the child
    // never moves to another place in the tree and keeps its State.
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        if (widget.enabled)
          _ChatSwipeRecognizer:
              GestureRecognizerFactoryWithHandlers<_ChatSwipeRecognizer>(
                () => _ChatSwipeRecognizer(
                  debugOwner: this,
                  allowPointer: _allowPointer,
                ),
                (_ChatSwipeRecognizer r) {
                  r
                    ..allowPointer = _allowPointer
                    ..onStart = _onStart
                    ..onUpdate = _onUpdate
                    ..onEnd = _onEnd
                    ..onCancel = _onCancel;
                },
              ),
      },
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          if (!widget.moveChild) return widget.child;
          return ClipRect(
            clipBehavior: widget.clipBehavior,
            child: AnimatedBuilder(
              animation: _anim,
              child: widget.child,
              builder: (BuildContext context, Widget? child) {
                return Transform.translate(
                  offset: Offset(_anim.value * _width, 0),
                  child: child,
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// A horizontal drag that stays out of the arena for pointers that land on
/// a text field, and that wins a clearly sideways move before the text
/// selection underneath does.
///
/// Why the lower slop: the transcript sits in a [SelectionArea]. On touch,
/// its [SelectableRegion] adds a `TapAndHorizontalDragGestureRecognizer`
/// that declares victory as soon as the finger passes the device's touch
/// slop (about 8 px on Android, from `MediaQuery.gestureSettings`). It is
/// deeper in the tree, so it sees the pointer first, and with the same or a
/// lower slop it took every swipe: on a phone the chat never moved, while
/// widget tests (default slop 18 for both) passed. This recognizer accepts a
/// little earlier, but only for a move that is mostly sideways, so a
/// vertical scroll with some jitter still belongs to the list.
class _ChatSwipeRecognizer extends HorizontalDragGestureRecognizer {
  _ChatSwipeRecognizer({super.debugOwner, required this.allowPointer});

  bool Function(PointerDownEvent event) allowPointer;

  /// The share of the device slop at which a sideways move is ours.
  static const double _slopFactor = 0.6;

  /// Never accept below this many logical pixels.
  static const double _minSlop = 4;

  /// How much more sideways than vertical a move must be.
  static const double _dominance = 1.5;

  Offset? _downPosition;
  Offset _lastPosition = Offset.zero;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (!super.isPointerAllowed(event)) return false;
    if (event is PointerDownEvent) return allowPointer(event);
    return true;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downPosition = event.position;
    _lastPosition = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _lastPosition = event.position;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final Offset? down = _downPosition;
    if (down == null) {
      return super.hasSufficientGlobalDistanceToAccept(
        pointerDeviceKind,
        deviceTouchSlop,
      );
    }
    final Offset moved = _lastPosition - down;
    final double slop = math.max(
      _minSlop,
      computeHitSlop(pointerDeviceKind, gestureSettings) * _slopFactor,
    );
    return moved.dx.abs() > slop &&
        moved.dx.abs() > moved.dy.abs() * _dominance;
  }
}
